import AVFoundation
import Flutter
import UIKit

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

final class IOSKeepAlive: NSObject {
  static let shared = IOSKeepAlive()

  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var player: AVAudioPlayer?

  var isHeld: Bool {
    backgroundTask != .invalid || player != nil
  }

  func begin() {
    if backgroundTask == .invalid {
      backgroundTask = UIApplication.shared.beginBackgroundTask(
        withName: "connexia-tunnel-keepalive"
      ) { [weak self] in
        self?.backgroundTask = .invalid
      }
    }
    startSilentAudio()
  }

  func end() {
    stopSilentAudio()
    if backgroundTask != .invalid {
      let task = backgroundTask
      backgroundTask = .invalid
      UIApplication.shared.endBackgroundTask(task)
    }
  }

  private func startSilentAudio() {
    guard player == nil else { return }
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("connexia-silence.wav")
      if !FileManager.default.fileExists(atPath: url.path) {
        try silenceWav().write(to: url)
      }
      let p = try AVAudioPlayer(contentsOf: url)
      p.numberOfLoops = -1
      p.volume = 0.0
      p.play()
      player = p
    } catch {
      player = nil
    }
  }

  private func stopSilentAudio() {
    player?.stop()
    player = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func silenceWav() -> Data {
    let sampleRate = 8000
    let seconds = 2
    let samples = sampleRate * seconds
    let dataBytes = samples * 2
    var data = Data()

    func append(_ value: UInt32) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    data.append("RIFF".data(using: .ascii)!)
    append(UInt32(36 + dataBytes))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    append(16)
    append16(1)
    append16(1)
    append(UInt32(sampleRate))
    append(UInt32(sampleRate * 2))
    append16(2)
    append16(16)
    data.append("data".data(using: .ascii)!)
    append(UInt32(dataBytes))
    data.append(contentsOf: Array(repeating: 0, count: dataBytes))
    return data
  }
}
