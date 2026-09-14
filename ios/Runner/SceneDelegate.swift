import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    DispatchQueue.main.async { [weak self] in
      self?.registerKeepAliveChannel()
    }
  }

  private func registerKeepAliveChannel() {
    guard let flutterVC = window?.rootViewController as? FlutterViewController else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "connexia/ios_keepalive",
      binaryMessenger: flutterVC.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "keepAliveStart":
        IOSKeepAlive.shared.begin()
        result(nil)
      case "keepAliveStop":
        IOSKeepAlive.shared.end()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
