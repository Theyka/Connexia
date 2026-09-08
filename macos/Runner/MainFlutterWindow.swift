import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Height of the Flutter title bar (WindowTitleBar in
  /// window_title_bar.dart). The traffic lights are aligned to this bar's
  /// vertical center; keep the two values in sync.
  private static let flutterBarHeight: CGFloat = 40

  private var lightFrameObservations: [NSKeyValueObservation] = []
  private var lightAlignmentInstalled = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  override func becomeKey() {
    super.becomeKey()
    // window_manager applies the hidden title bar style before the window
    // is shown, so the buttons exist by the time the window becomes key.
    // Re-running on every becomeKey also re-applies the offset if the
    // title bar ever recreates its buttons (e.g. after a fullscreen
    // transition).
    alignTrafficLights()
  }

  /// The app draws its own 40pt title bar (Home / SFTP / session tabs)
  /// under a hidden native title bar. macOS centers the traffic lights
  /// in its own 32pt bar, ~4pt above the custom buttons' center line.
  /// There is no public API to grow the native bar, so the standard
  /// window buttons are moved down to the Flutter bar's center instead.
  /// The private title bar container resets button frames on layout
  /// (resize, fullscreen, appearance changes), so the offset is
  /// re-applied whenever a button's frame changes.
  private func alignTrafficLights() {
    let buttons = [
      standardWindowButton(.closeButton),
      standardWindowButton(.miniaturizeButton),
      standardWindowButton(.zoomButton),
    ].compactMap { $0 }
    guard !buttons.isEmpty else { return }

    for button in buttons {
      applyLightOffset(button)
    }

    if lightAlignmentInstalled { return }
    lightAlignmentInstalled = true
    for button in buttons {
      lightFrameObservations.append(
        button
          .observe(\.frame, options: [.new]) { [weak self] button, _ in
            self?.applyLightOffset(button)
          }
      )
    }
  }

  private func applyLightOffset(_ button: NSButton) {
    guard let superview = button.superview else { return }
    // Vertical center of the custom bar, measured from the window top.
    let targetFromTop =
      Self.flutterBarHeight / 2 - button.bounds.height / 2
    let targetY = superview.isFlipped
        ? targetFromTop
        : superview.bounds.height - targetFromTop - button.bounds.height
    if abs(button.frame.origin.y - targetY) > 0.5 {
      button.frame.origin.y = targetY
    }
  }
}
