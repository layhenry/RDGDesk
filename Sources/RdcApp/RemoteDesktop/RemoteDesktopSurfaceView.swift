import AppKit
import RdcCore

@MainActor
final class RemoteDesktopSurfaceView: NSView, @preconcurrency NSTextInputClient {
    var frameImage: CGImage? {
        didSet { needsDisplay = true }
    }

    var onResize: ((Int, Int) -> Void)?
    var onPointer: ((RemotePointerEvent) -> Void)?
    var onKey: ((RemoteKeyEvent) -> Void)?
    var onUnicode: ((RemoteUnicodeKeyEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    private var resizeWorkItem: DispatchWorkItem?
    private var resizeState = RemoteResizeDebounceState()
    private var trackingAreaReference: NSTrackingArea?
    private var pointerState = RemotePointerState()
    private var modifierState = RemoteModifierState()
    private var textInputState = RemoteTextInputState()
    private var textKeyRoutingState = RemoteTextKeyRoutingState()
    private let physicalModifierKeyStateProvider: @MainActor () -> Set<UInt16>

    init(
        physicalModifierKeyStateProvider: @escaping @MainActor () -> Set<UInt16> =
            RemoteDesktopSurfaceView.combinedSessionPhysicalModifiers
    ) {
        self.physicalModifierKeyStateProvider = physicalModifierKeyStateProvider
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        physicalModifierKeyStateProvider = Self.combinedSessionPhysicalModifiers
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(dirtyRect)

        guard let image = frameImage,
              let geometry = RemoteInputTranslator.renderGeometry(
                  viewWidth: bounds.width,
                  viewHeight: bounds.height,
                  remoteWidth: image.width,
                  remoteHeight: image.height
              ), !geometry.cgImageNeedsVerticalFlip else { return }

        let destination = CGRect(
            x: geometry.contentRect.x,
            y: geometry.contentRect.y,
            width: geometry.contentRect.width,
            height: geometry.contentRect.height
        )
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(image, in: destination, byTiling: false)
        context.restoreGState()
    }

    override func layout() {
        super.layout()
        scheduleResize()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            detachFromWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        resizeState.attach()
        window.acceptsMouseMovedEvents = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBackingPropertiesDidChange(_:)),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: window
        )
        if window.isKeyWindow, window.firstResponder === self {
            synchronizePhysicalModifiers()
        }
        scheduleResize()
    }

    func tearDown() {
        detachFromWindow()
        frameImage = nil
        onResize = nil
        onPointer = nil
        onKey = nil
        onUnicode = nil
    }

    private func detachFromWindow() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: window
        )
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        resizeState.detach()
        releaseActiveInput()
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            releaseActiveInput()
        }
        return didResign
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if RemoteInputFocusPolicy.shouldSynchronizeModifiers(
            didBecomeFirstResponder: didBecome,
            isKeyWindow: window?.isKeyWindow == true
        ) {
            synchronizePhysicalModifiers()
        }
        return didBecome
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(.move, for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(.move, for: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(.move, for: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(.move, for: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(.left, phase: .down, for: event)
    }

    override func mouseUp(with event: NSEvent) {
        sendButton(.left, phase: .up, for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(.right, phase: .down, for: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendButton(.right, phase: .up, for: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        window?.makeFirstResponder(self)
        sendButton(.middle, phase: .down, for: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        sendButton(.middle, phase: .up, for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0, let point = remotePoint(for: event) else { return }
        let delta: Int16 = event.scrollingDeltaY > 0 ? 120 : -120
        onPointer?(RemotePointerEvent(point: point, action: .verticalWheel(delta: delta)))
    }

    override func keyDown(with event: NSEvent) {
        if shouldRouteThroughTextInput(event), inputContext?.handleEvent(event) == true {
            textKeyRoutingState.recordTextHandledKeyDown(event.keyCode)
            return
        }
        sendKey(keyCode: event.keyCode, phase: .down)
    }

    override func keyUp(with event: NSEvent) {
        if textKeyRoutingState.consumeTextHandledKeyUp(event.keyCode) {
            return
        }
        sendKey(keyCode: event.keyCode, phase: .up)
    }

    override func flagsChanged(with event: NSEvent) {
        let events: [RemoteKeyEvent]
        if event.keyCode == 57 {
            events = modifierState.capsLockToggle(forMacKeyCode: event.keyCode)
        } else if let flag = modifierFlag(for: event.keyCode) {
            events = modifierState.transition(
                forMacKeyCode: event.keyCode,
                isActive: event.modifierFlags.contains(flag)
            )
        } else {
            events = []
        }
        for event in events {
            onKey?(event)
        }
    }

    private func scheduleResize() {
        let backingSize = convertToBacking(bounds).size
        let width = Int(backingSize.width.rounded())
        let height = Int(backingSize.height.rounded())
        guard let request = resizeState.schedule(width: width, height: height) else { return }

        resizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let size = self.resizeState.complete(request) else { return }
            self.resizeWorkItem = nil
            self.onResize?(size.width, size.height)
        }
        resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: workItem)
    }

    private func sendButton(
        _ button: RemotePointerButton,
        phase: RemoteInputPhase,
        for event: NSEvent
    ) {
        guard let translated = pointerState.buttonEvent(
            button,
            phase: phase,
            at: remotePoint(for: event)
        ) else { return }
        onPointer?(translated)
    }

    private func sendPointer(_ action: RemotePointerAction, for event: NSEvent) {
        guard let point = remotePoint(for: event) else { return }
        onPointer?(RemotePointerEvent(point: point, action: action))
    }

    private func remotePoint(for event: NSEvent) -> RemotePoint? {
        guard let image = frameImage else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let point = RemoteInputTranslator.remotePoint(
            localX: local.x,
            localY: local.y,
            viewWidth: bounds.width,
            viewHeight: bounds.height,
            remoteWidth: image.width,
            remoteHeight: image.height
        )
        if let point {
            pointerState.observe(point)
        }
        return point
    }

    private func sendKey(keyCode: UInt16, phase: RemoteInputPhase) {
        guard let event = RemoteInputTranslator.keyEvent(
            forMacKeyCode: keyCode,
            phase: phase
        ) else { return }
        onKey?(event)
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }

    private func releaseActiveInput() {
        inputContext?.discardMarkedText()
        textInputState.discardMarkedText()
        textKeyRoutingState.reset()
        for event in pointerState.releaseAllButtons() {
            onPointer?(event)
        }
        for event in modifierState.releaseAll() {
            onKey?(event)
        }
    }

    private func shouldRouteThroughTextInput(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else {
            return false
        }
        let rawKeyCodes: Set<UInt16> = [
            36, 48, 51, 53, 71, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126
        ]
        guard !rawKeyCodes.contains(event.keyCode),
              let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else { return false }
        return !characters.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = Self.plainText(from: string) else { return }
        for event in textInputState.commit(text, replacementRange: replacementRange) {
            onUnicode?(event)
        }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard let text = Self.plainText(from: string) else { return }
        textInputState.setMarkedText(
            text,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    func unmarkText() {
        for event in textInputState.commitMarkedText() {
            onUnicode?(event)
        }
    }

    func hasMarkedText() -> Bool {
        textInputState.hasMarkedText
    }

    func markedRange() -> NSRange {
        textInputState.markedRange
    }

    func selectedRange() -> NSRange {
        textInputState.selectedRange
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard textInputState.hasMarkedText else { return nil }
        let marked = textInputState.markedText as NSString
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: marked.length))
        guard bounded.length > 0 else { return nil }
        actualRange?.pointee = bounded
        return NSAttributedString(string: marked.substring(with: bounded))
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        let local = NSRect(x: bounds.minX, y: bounds.maxY, width: 1, height: 1)
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    override func doCommand(by selector: Selector) {
        // Command/navigation keys bypass the text input context and keep scan-code routing.
    }

    private static func plainText(from value: Any) -> String? {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }

    private func synchronizePhysicalModifiers() {
        for event in modifierState.synchronize(
            physicallyActive: physicalModifierKeyStateProvider()
        ) {
            onKey?(event)
        }
    }

    private static func combinedSessionPhysicalModifiers() -> Set<UInt16> {
        let keyCodes: [UInt16] = [54, 55, 56, 58, 59, 60, 61, 62]
        return Set(keyCodes.filter {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        })
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        releaseActiveInput()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard window?.firstResponder === self else { return }
        synchronizePhysicalModifiers()
    }

    @objc private func windowBackingPropertiesDidChange(_ notification: Notification) {
        scheduleResize()
    }
}
