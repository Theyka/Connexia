import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  
  
  
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
    alignTrafficLights()
  }

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
