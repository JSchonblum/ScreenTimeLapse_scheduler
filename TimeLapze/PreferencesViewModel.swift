import AVFoundation
import SwiftUI

/// Manages data for the ``PreferencesView``
class PreferencesViewModel: ObservableObject {
  @AppStorage("showNotifications") var showNotifications = false
  @AppStorage("showAfterSave") var showAfterSave = false

  @AppStorage("framesPerSecond") var framesPerSecond = 30
  // Valid frames per second
  let validFPS = [10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60]

  @AppStorage("FPS") var fps: Double = 30.0
  @AppStorage("timeMultiple") var timeMultiple: Double = 5.0

  @AppStorage("quality") var quality: QualitySettings = .medium

  @AppStorage("format") var format: AVFileType = baseConfig.validFormats.first!

  @AppStorage("saveLocation") var saveLocation: URL = FileManager.default
    .homeDirectoryForCurrentUser
  @Published var showPicker = false
  @Published var fpsDropdown = 4
  @Published var fpsInput = ""

  // MARK: Schedule
  @AppStorage("scheduleEnabled") var scheduleEnabled: Bool = false
  @AppStorage("scheduleStartSeconds") var scheduleStartSeconds: Double = 36_000  // 10:00 AM
  @AppStorage("scheduleStopSeconds") var scheduleStopSeconds: Double = 64_800   // 6:00 PM
  @AppStorage("scheduleDaysMask") var scheduleDaysMask: Int = 62                // Mon–Fri (bits 1–5)

  /// Date representation of start time, for use with DatePicker
  var scheduleStartTime: Date {
    get { Calendar.current.startOfDay(for: Date()).addingTimeInterval(scheduleStartSeconds) }
    set { scheduleStartSeconds = newValue.timeIntervalSince(Calendar.current.startOfDay(for: newValue)) }
  }

  /// Date representation of stop time, for use with DatePicker
  var scheduleStopTime: Date {
    get { Calendar.current.startOfDay(for: Date()).addingTimeInterval(scheduleStopSeconds) }
    set { scheduleStopSeconds = newValue.timeIntervalSince(Calendar.current.startOfDay(for: newValue)) }
  }

  @Environment(\.openURL) var openURL

  // MARK: Intents

  /// Gets the user to specify where they want to save output videos
  func getDirectory(newVal: Bool) {
    guard showPicker else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.begin { [self] res in
      showPicker = false
      guard res == .OK, let pickedURL = panel.url else { return }

      saveLocation = pickedURL
    }
  }
}
