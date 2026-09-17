import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  
  
  
  private static let flutterBarHeight: CGFloat = 40

  private var lightFrameObservations: [NSKeyValueObservation] = []
  private var lightAlignmentInstalled = false

  private var debugLogging = false

  private func log(_ message: String) {
    guard debugLogging else { return }
    print("[WIN] \(message)")
    fflush(stdout)
  }

  private var suppressZoomUntil: Date?

  private var isSystemDoubleClick: Bool {
    if let until = suppressZoomUntil, Date() < until { return true }
    guard let event = NSApp.currentEvent else { return false }
    guard event.type == .leftMouseDown || event.type == .leftMouseUp else {
      return false
    }
    return event.clickCount >= 2
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The window keeps an invisible native title bar over the top of Flutter's
    // own 40pt bar. Single clicks pass through to Flutter, but AppKit also
    // claims press-and-drag inside that band as a window move, which steals
    // drags that start on a terminal tab's label and moves the whole window
    // instead of reordering the tab. Disable AppKit's automatic title-bar
    // drag; Flutter's blank-area drag region calls startDragging() explicitly.
    self.isMovable = false

    super.awakeFromNib()
    guard debugLogging else { return }
    let center = NotificationCenter.default
    center.addObserver(
      forName: NSWindow.didEnterFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.log("didEnterFullScreen frame=\(self?.frame ?? .zero)") }
    center.addObserver(
      forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main
    ) { [weak self] _ in self?.log("didExitFullScreen frame=\(self?.frame ?? .zero)") }
    center.addObserver(
      forName: NSWindow.didResizeNotification, object: self, queue: .main
    ) { [weak self] _ in self?.log("didResize frame=\(self?.frame ?? .zero)") }
  }

  override func zoom(_ sender: Any?) {
    if isSystemDoubleClick { return }
    super.zoom(sender)
  }

  override func performZoom(_ sender: Any?) {
    if isSystemDoubleClick { return }
    super.performZoom(sender)
  }

  override func toggleFullScreen(_ sender: Any?) {
    if isSystemDoubleClick { return }
    super.toggleFullScreen(sender)
  }

  // AppKit gates some drag machinery on `isMovable`. Flutter's drag region
  // calls this explicitly via window_manager.startDragging(), so re-enable
  // movability for the duration of the programmatic drag only.
  override func performDrag(with event: NSEvent) {
    let wasMovable = isMovable
    isMovable = true
    super.performDrag(with: event)
    isMovable = wasMovable
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown, event.clickCount >= 2 {
      suppressZoomUntil = Date().addingTimeInterval(0.4)
    }
    if debugLogging,
       event.type == .leftMouseDown || event.type == .leftMouseUp {
      let p = contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
      log("EV \(event.type == .leftMouseDown ? "DOWN" : "UP") clicks=\(event.clickCount) relY=\(String(format: "%.1f", p.y)) relX=\(String(format: "%.1f", p.x))")
    }
    super.sendEvent(event)
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
