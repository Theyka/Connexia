import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// Extends the app's background runtime while SSH tunnels are supposed to
/// run. Backgrounded, an iOS app is suspended within seconds — every socket
/// stops being served and forwarded connections fail until the app is
/// reopened. `beginBackgroundTask` buys ~30 s of guaranteed execution, which
/// covers the "switch to Chrome and load the URL" flow.
///
/// When that window expires the expiration handler ends the task and posts
/// a local notification so the user knows why the tunnel stopped responding.
final class IOSKeepAlive: NSObject {
  static let shared = IOSKeepAlive()

  private var currentTask: UIBackgroundTaskIdentifier = .invalid

  var isHeld: Bool { currentTask != .invalid }

  /// No-op if already held. Must be called while the app is active or
  /// immediately after backgrounding (that is when tunnels start).
  func begin() {
    guard currentTask == .invalid else { return }
    currentTask = UIApplication.shared.beginBackgroundTask(
      withName: "connexia-tunnel-keepalive"
    ) { [weak self] in
      // The system is about to suspend us.
      self?.end()
      self?.notifySuspended()
    }
    requestNotificationPermission()
  }

  func end() {
    guard currentTask != .invalid else { return }
    let task = currentTask
    currentTask = .invalid
    UIApplication.shared.endBackgroundTask(task)
  }

  private func requestNotificationPermission() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert]) { _, _ in }
  }

  private func notifySuspended() {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .authorized ||
            settings.authorizationStatus == .provisional else { return }
      let content = UNMutableNotificationContent()
      content.title = "Connexia tunnels paused"
      content.body = "iOS suspended the app. Reopen Connexia to resume your tunnels."
      let request = UNNotificationRequest(
        identifier: "connexia-tunnel-suspended",
        content: content,
        trigger: nil // deliver immediately
      )
      center.add(request)
    }
  }
}
