import AVFoundation
import IOKit
import ScreenCaptureKit
import SwiftUI

/// Represents a synchronized session of ``Recordable`` objects
class RecorderViewModel: ObservableObject {
  static let shared = RecorderViewModel()

  @Published var apps: [SCRunningApplication: Bool] = [:]

  @Published var cameras: [Camera] = []
  @Published var screens: [Screen] = []

  @Published var state: RecordingState = .stopped
  @Published var hasScreenPermission: Bool = false
  @AppStorage("showCursor") var showCursor: Bool = false

  /// Timer which allows for asynchronous refreshing of enabled displays
  private var timer: DispatchSourceTimer?

  /// Timer which checks the recording schedule every minute
  private var scheduleTimer: DispatchSourceTimer?

  /// Checks screen recording permission using the lightweight preflight API
  @discardableResult
  func checkScreenPermission() -> Bool {
    let permitted = CGPreflightScreenCaptureAccess()
    DispatchQueue.main.async {
      self.hasScreenPermission = permitted
    }
    return permitted
  }

  /// Requests screen recording permission, opening System Settings if needed
  func requestScreenPermission() {
    CGRequestScreenCaptureAccess()
    hasScreenPermission = CGPreflightScreenCaptureAccess()
  }

  /// Makes an asynchronous call to `ScreenCaptureKit` to get valid `SCScreens` and `SCRunningApplication`s connected to the computer
  @MainActor
  func getDisplayInfo() async {
    guard checkScreenPermission() else { return }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)

      self.apps = convertApps(apps: content.applications)
      self.screens = convertDisplays(displays: content.displays)
    } catch {
      logger.error("\(error.localizedDescription)")
    }
  }

  init() {
    hasScreenPermission = CGPreflightScreenCaptureAccess()
    getCameras()
    startRefreshingDevices()
    startScheduler()
    setupCameraMonitoring()
    Task(priority: .userInitiated) {
      await getDisplayInfo()
    }
  }

  deinit {
    cleanUpMonitoring()
    scheduleTimer?.cancel()
  }

  // MARK: Monitoring Recording Changes

  /// Gets new cameras every time a new camera is added or removed
  private func setupCameraMonitoring() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(deviceConnected), name: .AVCaptureDeviceWasConnected, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(deviceDisconnected), name: .AVCaptureDeviceWasDisconnected,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParametersChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)

    // Required to get the event handler to actually work
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(newApplicationLaunched),
      name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(applicationClosed),
      name: NSWorkspace.didTerminateApplicationNotification, object: nil)
  }

  /// Tears down all of the ``NotificationCenter`` observers added
  private func cleanUpMonitoring() {
    NotificationCenter.default.removeObserver(self, name: .AVCaptureDeviceWasConnected, object: nil)
    NotificationCenter.default.removeObserver(
      self, name: .AVCaptureDeviceWasDisconnected, object: nil)
    NotificationCenter.default.removeObserver(
      self, name: NSApplication.didChangeScreenParametersNotification, object: nil)

    // Required to get the event handler to actually work
    NSWorkspace.shared.notificationCenter.removeObserver(
      self, name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    NSWorkspace.shared.notificationCenter.removeObserver(
      self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)
  }

  @objc private func deviceConnected(notification: Notification) {
    getCameras()
  }

  @objc private func deviceDisconnected(notification: Notification) {
    getCameras()
  }

  @objc private func screenParametersChanged(notification: Notification) {
    Task(priority: .background) {
      await getDisplayInfo()
    }
  }

  @objc private func newApplicationLaunched(notification: Notification) {
    Task(priority: .background) {
      await getDisplayInfo()
    }
  }

  @objc private func applicationClosed(notification: Notification) {
    Task(priority: .background) {
      await getDisplayInfo()
    }
  }

  /// Starts a timer which refreshes connected devices
  func startRefreshingDevices() {
    timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    guard let timer = timer else { return }

    timer.schedule(deadline: .now(), repeating: .seconds(30))
    timer.setEventHandler { [weak self] in
      self?.getCameras()

      if self != nil {
        Task(priority: .background) { [weak self] in
          await self?.getDisplayInfo()
        }
      }
    }
    timer.resume()
  }

  // MARK: Schedule

  /// Starts a timer that checks the recording schedule once per minute
  func startScheduler() {
    scheduleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    guard let scheduleTimer = scheduleTimer else { return }

    // Fire 60s after launch (not immediately), then every 60s
    scheduleTimer.schedule(deadline: .now() + 60, repeating: .seconds(60))
    scheduleTimer.setEventHandler { [weak self] in self?.checkSchedule() }
    scheduleTimer.resume()
  }

  /// Called every minute — starts or stops recording based on the configured schedule
  func checkSchedule() {
    guard UserDefaults.standard.bool(forKey: "scheduleEnabled") else { return }

    let now = Date()
    let calendar = Calendar.current

    // weekday: 1 = Sunday … 7 = Saturday  →  bit position = weekday - 1
    let weekday = calendar.component(.weekday, from: now)
    let dayBit = 1 << (weekday - 1)
    let daysMask = UserDefaults.standard.object(forKey: "scheduleDaysMask") as? Int ?? 62
    guard daysMask & dayBit != 0 else { return }

    let midnight = calendar.startOfDay(for: now)
    let currentSeconds = now.timeIntervalSince(midnight)

    let rawStart = UserDefaults.standard.double(forKey: "scheduleStartSeconds")
    let rawStop = UserDefaults.standard.double(forKey: "scheduleStopSeconds")
    let startSeconds = rawStart == 0 ? 36_000.0 : rawStart
    let stopSeconds = rawStop == 0 ? 64_800.0 : rawStop

    let inWindow = currentSeconds >= startSeconds && currentSeconds < stopSeconds

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if inWindow && self.state == .stopped {
        self.startRecording()
      } else if !inWindow && self.state != .stopped {
        self.saveRecordings()
      }
    }
  }

  /// Gets all cameras attached to the computer and creates ``MyRecordingCamera``s for them
  func getCameras() {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video,
      position: .unspecified)

    DispatchQueue.main.async {
      self.cameras = self.convertCameras(camera: discovery.devices)
    }
  }

  /// This functions inverts the ``self.apps`` list from include to exclude
  /// - Returns: The list of apps which should be disabled
  func getExcludedApps() -> [SCRunningApplication] {
    return self.apps.filter { elem in
      !elem.value
    }.map { elem in elem.key }
  }

  /// Breaks apart `apps` to what should be **included**
  var includedApps: [SCRunningApplication] {
    apps.keys.filter { apps[$0]! }.sorted(by: <)
  }

  /// Breaks apart `apps` to what should be **excluded**
  var excludedApps: [SCRunningApplication] {
    apps.keys.filter { !apps[$0]! }.sorted(by: <)
  }

  // MARK: Recording

  /// Starts recording ``cameras`` and ``screens``
  func startRecording() {
    self.state = .recording

    logger.log("Started recording at RecorderViewModel")

    let excludedApps = apps.filter { !$0.value }.map { $0.key }

    for camera in cameras {
      camera.startRecording()
    }

    for screen in screens {
      screen.startRecording(excluding: excludedApps, showCursor: showCursor)
    }
  }

  /// Pauses recording ``screens`` and ``cameras``
  func pauseRecording() {
    self.state = .paused

    for idx in cameras.indices {
      cameras[idx].pauseRecording()
    }

    for idx in screens.indices {
      screens[idx].pauseRecording()
    }
  }

  /// Resumes recording ``screens`` and ``cameras``
  func resumeRecording() {
    self.state = .recording

    for idx in cameras.indices {
      cameras[idx].resumeRecording()
    }

    for idx in screens.indices {
      screens[idx].resumeRecording()
    }
  }

  func stopRecording() {
    self.state = .stopped

    for idx in cameras.indices {
      cameras[idx].stopRecording()
    }

    for idx in screens.indices {
      screens[idx].stopRecording()
    }
  }

  /// Saves the ``cameras`` and ``screens``
  func saveRecordings() {
    self.state = .stopped

    for idx in cameras.indices {
      cameras[idx].saveRecording()
    }

    for idx in screens.indices {
      screens[idx].saveRecording()
    }

    // Logs a recording being saved
    ReviewManager.shared.logCompletedRecordings()
  }

  // MARK: Toggles

  /// Inverts the ``Screen`` and sends an update to the user interface
  func toggleScreen(screen: Screen) {
    screen.enabled.toggle()
    enabledScreens[String(screen.screen.displayID)] = screen.enabled
    objectWillChange.send()
  }

  /// Turns a `SCRunningApplication` on or off in the ``apps`` dictionary
  func toggleApp(app: SCRunningApplication) {
    if let row = apps.first(where: { $0.key.processID == app.processID }) {
      let enabled = !row.value

      apps[row.key] = enabled
      enabledBundleIdentifiers[app.bundleIdentifier] = enabled
    }
    objectWillChange.send()
  }

  /// Toggles a ``Camera``
  ///
  /// Rather than a dictionary like ``apps`` this was encapsulated in a custom struct
  func toggleCamera(camera: Camera) {
    camera.enabled.toggle()
    enabledCameras[camera.inputDevice.uniqueID] = camera.enabled
    objectWillChange.send()
  }

  /// Checks to make sure at least one ``Screen`` or ``Camera`` is enabled
  func recordersDisabled() -> Bool {
    !(cameras.contains { $0.enabled } || screens.contains { $0.enabled })
  }

  // MARK: Applications Menu

  /// Flips the enabled and disabled app in ``apps``
  func invertApplications() {
    var localBundleIDs = enabledBundleIdentifiers

    for appName in self.apps.keys {
      let enabled = !self.apps[appName]!

      self.apps[appName] = enabled
      localBundleIDs[appName.bundleIdentifier] = enabled
    }

    enabledBundleIdentifiers = localBundleIDs
  }

  /// Resets ``apps`` by setting each `value` to `true`
  func resetApps() {
    var localBundleIDs = enabledBundleIdentifiers

    for appName in self.apps.keys {
      // enabled by default
      self.apps[appName]! = true
      localBundleIDs[appName.bundleIdentifier] = true
    }

    enabledBundleIdentifiers = localBundleIDs

    /// Refreshing apps by default
    refreshApps()
  }

  /// Refreshes ``apps`` to get new information
  ///
  /// Ideally, finding new apps would be done in a periodic manner
  func refreshApps() {
    Task(priority: .userInitiated) {
      await getDisplayInfo()
    }
  }

  /// Generates an dictionary with `SCRunningApplication` keys and `Bool` value
  private func convertApps(apps input: [SCRunningApplication]) -> [SCRunningApplication: Bool] {
    let enabledBundleIdentifiers = enabledBundleIdentifiers

    let returnApps =
      input
      .filter { app in
        Bundle.main.bundleIdentifier != app.bundleIdentifier
          && !app.applicationName.isEmpty
      }
      .map { app in
        (app, self.apps[app] ?? enabledBundleIdentifiers[app.bundleIdentifier] ?? true)
      }

    return Dictionary(uniqueKeysWithValues: returnApps)
  }

  /// Turns an array of `SCDisplays` into new ``Screen``s
  private func convertDisplays(displays input: [SCDisplay]) -> [Screen] {
    var newScreens =
      input
      .filter { display in
        !self.screens.contains { recorder in
          recorder.screen == display
        }
      }
      .map(getScreenRecorder)

    // setting displays enabled based on stored app state
    let enabledDisplays = enabledScreens

    for display in newScreens {
      display.enabled = enabledDisplays[String(display.screen.displayID)] ?? display.enabled
    }

    for screen in self.screens {
      newScreens.append(screen)
    }

    newScreens =
      newScreens
      .sorted { (first, second) in
        first.screen.displayID < second.screen.displayID
      }

    // Enabling the first screen
    if self.screens.isEmpty, !newScreens.isEmpty {
      newScreens.first!.enabled = true
    }

    return newScreens
  }

  /// Converts a `AVCaptureDevice` array from from a Discovery session into custom ``Camera`` object
  private func convertCameras(camera input: [AVCaptureDevice]) -> [Camera] {
    var newCameras =
      input
      .filter { camera in
        !self.cameras.contains { recorder in
          recorder.inputDevice == camera
        }
      }.map(getCameraRecorder)

    // setting cameras enabled based on stored app state
    let enabledCameras = enabledCameras

    for camera in newCameras {
      camera.enabled = enabledCameras[camera.inputDevice.uniqueID] ?? camera.enabled
    }

    for camera in self.cameras {
      newCameras.append(camera)
    }

    // Applying some consistent sorting order
    newCameras =
      newCameras
      .sorted { (first, second) in
        first.inputDevice.uniqueID < second.inputDevice.uniqueID
      }

    return newCameras
  }

  // MARK: Persistence

  /// Enabled bundle identifiers work like a normal dictionary
  private var enabledBundleIdentifiers: [String: Bool] {
    get {
      return UserDefaults.standard.object(forKey: "enabledBundleIdentifiers") as? [String: Bool]
        ?? [:]
    }
    set {
      UserDefaults.standard.set(newValue, forKey: "enabledBundleIdentifiers")
    }
  }

  /// Cameras being enabled or disabled
  ///
  /// Uses the ``AVFoundation.AVCaptureDevice.uniqueID`` property to enable or disable cameras
  private var enabledCameras: [String: Bool] {
    get {
      return UserDefaults.standard.object(forKey: "enabledCameras") as? [String: Bool] ?? [:]
    }
    set {
      return UserDefaults.standard.set(newValue, forKey: "enabledCameras")
    }
  }

  /// Screens being recorded
  ///
  /// Uses the ``SCDisplay.displayID`` which is a
  private var enabledScreens: [String: Bool] {
    get {
      return UserDefaults.standard.object(forKey: "enabledScreens") as? [String: Bool] ?? [:]
    }
    set {
      UserDefaults.standard.set(newValue, forKey: "enabledScreens")
    }
  }

  // MARK: Timing

  /// Returns the slower-than real-time length of the recording
  ///
  /// All time multiples should be the same, so the function finds the first enabled time multiple
  var currentTime: CMTime {
    for screen in screens {
      if screen.enabled {
        return screen.time
      }
    }

    for camera in cameras {
      if camera.enabled {
        return camera.time
      }
    }

    return CMTime.zero
  }

  // MARK: Recorder Creation

  /// Converts a `SCDisplay` into a ``Screen``
  private func getScreenRecorder(_ screen: SCDisplay) -> Screen {
    Screen(screen: screen, showCursor: showCursor)
  }

  /// Converts a `AVCaptureDevice` into a ``Camera``
  private func getCameraRecorder(_ camera: AVCaptureDevice) -> Camera {
    Camera(camera: camera)
  }
}
