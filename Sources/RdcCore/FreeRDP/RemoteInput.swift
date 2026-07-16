import Foundation

public struct RemotePoint: Equatable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct RemoteRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RemoteRenderGeometry: Equatable, Sendable {
    public let contentRect: RemoteRect
    public let cgImageNeedsVerticalFlip: Bool

    public init(contentRect: RemoteRect, cgImageNeedsVerticalFlip: Bool) {
        self.contentRect = contentRect
        self.cgImageNeedsVerticalFlip = cgImageNeedsVerticalFlip
    }
}

public enum RemoteInputPhase: Equatable, Sendable {
    case down
    case up
}

public enum RemotePointerButton: Equatable, Sendable {
    case left
    case right
    case middle
}

public enum RemotePointerAction: Equatable, Sendable {
    case move
    case button(RemotePointerButton, phase: RemoteInputPhase)
    case verticalWheel(delta: Int16)
}

public struct RemotePointerEvent: Equatable, Sendable {
    public let point: RemotePoint
    public let action: RemotePointerAction

    public init(point: RemotePoint, action: RemotePointerAction) {
        self.point = point
        self.action = action
    }

    public var flags: UInt16 {
        switch action {
        case .move:
            return 0x0800
        case let .button(button, phase):
            let buttonFlag: UInt16 = switch button {
            case .left: 0x1000
            case .right: 0x2000
            case .middle: 0x4000
            }
            return phase == .down ? buttonFlag | 0x8000 : buttonFlag
        case let .verticalWheel(delta):
            let magnitude = UInt16(min(abs(Int(delta)), 0x00FF))
            guard delta < 0 else { return 0x0200 | magnitude }
            return 0x0200 | 0x0100 | (0x0100 - magnitude)
        }
    }
}

public struct RemotePointerState: Equatable, Sendable {
    private var pressedButtons = Set<RemotePointerButton>()
    private var lastValidPoint: RemotePoint?

    public init() {}

    public mutating func observe(_ point: RemotePoint) {
        lastValidPoint = point
    }

    public mutating func buttonEvent(
        _ button: RemotePointerButton,
        phase: RemoteInputPhase,
        at point: RemotePoint?
    ) -> RemotePointerEvent? {
        if let point {
            observe(point)
        }

        switch phase {
        case .down:
            guard let point, pressedButtons.insert(button).inserted else { return nil }
            return RemotePointerEvent(point: point, action: .button(button, phase: .down))
        case .up:
            guard pressedButtons.remove(button) != nil, let lastValidPoint else { return nil }
            return RemotePointerEvent(
                point: lastValidPoint,
                action: .button(button, phase: .up)
            )
        }
    }

    public mutating func releaseAllButtons() -> [RemotePointerEvent] {
        guard let lastValidPoint else {
            pressedButtons.removeAll()
            return []
        }
        let events = pressedButtons.sorted { Self.order($0) < Self.order($1) }.map {
            RemotePointerEvent(
                point: lastValidPoint,
                action: .button($0, phase: .up)
            )
        }
        pressedButtons.removeAll()
        return events
    }

    private static func order(_ button: RemotePointerButton) -> Int {
        switch button {
        case .left: 0
        case .right: 1
        case .middle: 2
        }
    }
}

public struct RemoteSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct RemoteResizeRequest: Equatable, Sendable {
    public let token: UInt64
    public let size: RemoteSize

    public init(token: UInt64, size: RemoteSize) {
        self.token = token
        self.size = size
    }
}

public struct RemoteResizeDebounceState: Equatable, Sendable {
    private var isAttached = false
    private var nextToken: UInt64 = 0
    private var pending: RemoteResizeRequest?
    private var lastCompletedSize: RemoteSize?

    public init() {}

    public mutating func attach() {
        isAttached = true
    }

    public mutating func detach() {
        isAttached = false
        pending = nil
        lastCompletedSize = nil
    }

    public mutating func schedule(width: Int, height: Int) -> RemoteResizeRequest? {
        let size = RemoteSize(width: width, height: height)
        guard isAttached, width > 0, height > 0,
              pending?.size != size,
              pending != nil || lastCompletedSize != size else { return nil }
        precondition(nextToken < UInt64.max, "Remote resize token exhausted")
        nextToken += 1
        let request = RemoteResizeRequest(token: nextToken, size: size)
        pending = request
        return request
    }

    public mutating func complete(_ request: RemoteResizeRequest) -> RemoteSize? {
        guard isAttached, pending == request else { return nil }
        pending = nil
        guard lastCompletedSize != request.size else { return nil }
        lastCompletedSize = request.size
        return request.size
    }
}

public struct RemoteKeyEvent: Equatable, Sendable {
    public let scanCode: UInt16
    public let phase: RemoteInputPhase
    public let isExtended: Bool

    public init(scanCode: UInt16, phase: RemoteInputPhase, isExtended: Bool = false) {
        self.scanCode = scanCode
        self.phase = phase
        self.isExtended = isExtended
    }

    public var flags: UInt16 {
        (isExtended ? 0x0100 : 0) | (phase == .up ? 0x8000 : 0)
    }
}

public struct RemoteUnicodeKeyEvent: Equatable, Sendable {
    public let codeUnit: UInt16
    public let phase: RemoteInputPhase

    public init(codeUnit: UInt16, phase: RemoteInputPhase) {
        self.codeUnit = codeUnit
        self.phase = phase
    }

    public var flags: UInt16 {
        phase == .up ? 0x8000 : 0
    }
}

public struct RemoteTextInputState: Equatable, Sendable {
    public private(set) var markedText = ""
    public private(set) var selectedRange = NSRange(location: 0, length: 0)
    public private(set) var replacementRange = NSRange(location: NSNotFound, length: 0)

    public init() {}

    public var hasMarkedText: Bool {
        !markedText.isEmpty
    }

    public var markedRange: NSRange {
        guard hasMarkedText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    public mutating func setMarkedText(
        _ text: String,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        markedText = text
        self.selectedRange = selectedRange
        self.replacementRange = replacementRange
    }

    public mutating func commit(
        _ text: String,
        replacementRange: NSRange
    ) -> [RemoteUnicodeKeyEvent] {
        discardMarkedText()
        return Self.unicodeEvents(for: text)
    }

    public mutating func commitMarkedText() -> [RemoteUnicodeKeyEvent] {
        let text = markedText
        discardMarkedText()
        return Self.unicodeEvents(for: text)
    }

    public mutating func discardMarkedText() {
        markedText = ""
        selectedRange = NSRange(location: 0, length: 0)
        replacementRange = NSRange(location: NSNotFound, length: 0)
    }

    public mutating func reset() {
        discardMarkedText()
    }

    private static func unicodeEvents(for text: String) -> [RemoteUnicodeKeyEvent] {
        text.utf16.flatMap { codeUnit in
            [
                RemoteUnicodeKeyEvent(codeUnit: codeUnit, phase: .down),
                RemoteUnicodeKeyEvent(codeUnit: codeUnit, phase: .up)
            ]
        }
    }
}

public struct RemoteTextKeyRoutingState: Equatable, Sendable {
    private var textHandledKeyCodes = Set<UInt16>()

    public init() {}

    public mutating func recordTextHandledKeyDown(_ keyCode: UInt16) {
        textHandledKeyCodes.insert(keyCode)
    }

    public mutating func consumeTextHandledKeyUp(_ keyCode: UInt16) -> Bool {
        textHandledKeyCodes.remove(keyCode) != nil
    }

    public mutating func reset() {
        textHandledKeyCodes.removeAll()
    }
}

public enum RemoteInputFocusPolicy {
    public static func shouldSynchronizeModifiers(
        didBecomeFirstResponder: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        didBecomeFirstResponder && isKeyWindow
    }
}

public struct RemoteModifierState: Equatable, Sendable {
    private var activeKeyCodes = Set<UInt16>()

    public init() {}

    public mutating func transition(
        forMacKeyCode keyCode: UInt16,
        isActive: Bool
    ) -> [RemoteKeyEvent] {
        if activeKeyCodes.contains(keyCode) {
            let siblingIsActive = activeKeyCodes.contains {
                $0 != keyCode && Self.family(for: $0) == Self.family(for: keyCode)
            }
            guard !isActive || siblingIsActive else { return [] }
            activeKeyCodes.remove(keyCode)
            return RemoteInputTranslator.keyEvent(
                forMacKeyCode: keyCode,
                phase: .up
            ).map { [$0] } ?? []
        }

        guard isActive, let event = RemoteInputTranslator.keyEvent(
            forMacKeyCode: keyCode,
            phase: .down
        ) else { return [] }
        activeKeyCodes.insert(keyCode)
        return [event]
    }

    public mutating func capsLockToggle(forMacKeyCode keyCode: UInt16) -> [RemoteKeyEvent] {
        guard let down = RemoteInputTranslator.keyEvent(
            forMacKeyCode: keyCode,
            phase: .down
        ), let up = RemoteInputTranslator.keyEvent(
            forMacKeyCode: keyCode,
            phase: .up
        ) else { return [] }
        return [down, up]
    }

    public mutating func synchronize(
        physicallyActive: Set<UInt16>
    ) -> [RemoteKeyEvent] {
        let physicalModifiers = Set(physicallyActive.filter(Self.isSynchronizableModifier))
        let stale = activeKeyCodes.subtracting(physicalModifiers).sorted()
        let missing = physicalModifiers.subtracting(activeKeyCodes).sorted()
        let releases = stale.compactMap {
            RemoteInputTranslator.keyEvent(forMacKeyCode: $0, phase: .up)
        }
        let presses = missing.compactMap {
            RemoteInputTranslator.keyEvent(forMacKeyCode: $0, phase: .down)
        }
        activeKeyCodes = physicalModifiers
        return releases + presses
    }

    public mutating func releaseAll() -> [RemoteKeyEvent] {
        let events = activeKeyCodes.sorted().compactMap {
            RemoteInputTranslator.keyEvent(forMacKeyCode: $0, phase: .up)
        }
        activeKeyCodes.removeAll()
        return events
    }

    private enum Family: Equatable {
        case command
        case shift
        case option
        case control
        case other(UInt16)
    }

    private static func family(for keyCode: UInt16) -> Family {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: .other(keyCode)
        }
    }

    private static func isSynchronizableModifier(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62: true
        default: false
        }
    }
}

public enum RemoteInputTranslator {
    private struct KeyMapping: Sendable {
        let scanCode: UInt16
        let isExtended: Bool

        init(_ scanCode: UInt16, extended: Bool = false) {
            self.scanCode = scanCode
            self.isExtended = extended
        }
    }

    // macOS virtual key codes are hardware-position based. This table deliberately
    // contains only positions with a well-defined RDP Set 1 scan-code equivalent.
    private static let keyMappings: [UInt16: KeyMapping] = [
        0: .init(0x1E), 1: .init(0x1F), 2: .init(0x20), 3: .init(0x21),
        4: .init(0x23), 5: .init(0x22), 6: .init(0x2C), 7: .init(0x2D),
        8: .init(0x2E), 9: .init(0x2F), 11: .init(0x30), 12: .init(0x10),
        13: .init(0x11), 14: .init(0x12), 15: .init(0x13), 16: .init(0x15),
        17: .init(0x14), 18: .init(0x02), 19: .init(0x03), 20: .init(0x04),
        21: .init(0x05), 22: .init(0x07), 23: .init(0x06), 24: .init(0x0D),
        25: .init(0x0A), 26: .init(0x08), 27: .init(0x0C), 28: .init(0x09),
        29: .init(0x0B), 30: .init(0x1B), 31: .init(0x18), 32: .init(0x16),
        33: .init(0x1A), 34: .init(0x17), 35: .init(0x19), 36: .init(0x1C),
        37: .init(0x26), 38: .init(0x24), 39: .init(0x28), 40: .init(0x25),
        41: .init(0x27), 42: .init(0x2B), 43: .init(0x33), 44: .init(0x35),
        45: .init(0x31), 46: .init(0x32), 47: .init(0x34), 48: .init(0x0F),
        49: .init(0x39), 50: .init(0x29), 51: .init(0x0E), 53: .init(0x01),
        54: .init(0x5C, extended: true), 55: .init(0x5B, extended: true),
        56: .init(0x2A), 57: .init(0x3A), 58: .init(0x38), 59: .init(0x1D),
        60: .init(0x36), 61: .init(0x38, extended: true),
        62: .init(0x1D, extended: true),
        65: .init(0x53), 67: .init(0x37), 69: .init(0x4E), 71: .init(0x45),
        75: .init(0x35, extended: true), 76: .init(0x1C, extended: true),
        78: .init(0x4A), 82: .init(0x52), 83: .init(0x4F),
        84: .init(0x50), 85: .init(0x51), 86: .init(0x4B), 87: .init(0x4C),
        88: .init(0x4D), 89: .init(0x47), 91: .init(0x48), 92: .init(0x49),
        96: .init(0x3F), 97: .init(0x40), 98: .init(0x41), 99: .init(0x3D),
        100: .init(0x42), 101: .init(0x43), 103: .init(0x57), 109: .init(0x44),
        111: .init(0x58), 114: .init(0x52, extended: true),
        115: .init(0x47, extended: true), 116: .init(0x49, extended: true),
        117: .init(0x53, extended: true), 118: .init(0x3E),
        119: .init(0x4F, extended: true), 120: .init(0x3C),
        121: .init(0x51, extended: true), 122: .init(0x3B),
        123: .init(0x4B, extended: true), 124: .init(0x4D, extended: true),
        125: .init(0x50, extended: true), 126: .init(0x48, extended: true)
    ]

    public static func remotePoint(
        localX: Double,
        localY: Double,
        viewWidth: Double,
        viewHeight: Double,
        remoteWidth: Int,
        remoteHeight: Int
    ) -> RemotePoint? {
        guard let rect = aspectFitRect(
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            remoteWidth: remoteWidth,
            remoteHeight: remoteHeight
        ) else {
            return nil
        }

        let scale = rect.width / Double(remoteWidth)
        let maxX = rect.x + rect.width
        let maxY = rect.y + rect.height

        guard localX >= rect.x, localX <= maxX, localY >= rect.y, localY <= maxY else {
            return nil
        }

        // AppKit view coordinates originate at bottom-left. Remote desktop pixels
        // originate at top-left, so Y is measured down from the drawn image's top.
        let remoteX = Int((localX - rect.x) / scale)
        let remoteY = Int((maxY - localY) / scale)
        return RemotePoint(
            x: min(max(remoteX, 0), remoteWidth - 1),
            y: min(max(remoteY, 0), remoteHeight - 1)
        )
    }

    public static func aspectFitRect(
        viewWidth: Double,
        viewHeight: Double,
        remoteWidth: Int,
        remoteHeight: Int
    ) -> RemoteRect? {
        guard viewWidth > 0, viewHeight > 0, remoteWidth > 0, remoteHeight > 0 else {
            return nil
        }
        let scale = min(viewWidth / Double(remoteWidth), viewHeight / Double(remoteHeight))
        let width = Double(remoteWidth) * scale
        let height = Double(remoteHeight) * scale
        return RemoteRect(
            x: (viewWidth - width) / 2,
            y: (viewHeight - height) / 2,
            width: width,
            height: height
        )
    }

    public static func renderGeometry(
        viewWidth: Double,
        viewHeight: Double,
        remoteWidth: Int,
        remoteHeight: Int
    ) -> RemoteRenderGeometry? {
        guard let contentRect = aspectFitRect(
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            remoteWidth: remoteWidth,
            remoteHeight: remoteHeight
        ) else { return nil }
        return RemoteRenderGeometry(
            contentRect: contentRect,
            cgImageNeedsVerticalFlip: false
        )
    }

    public static func scanCode(forMacKeyCode keyCode: UInt16) -> UInt16? {
        keyMappings[keyCode]?.scanCode
    }

    public static func keyEvent(
        forMacKeyCode keyCode: UInt16,
        phase: RemoteInputPhase
    ) -> RemoteKeyEvent? {
        guard let mapping = keyMappings[keyCode] else { return nil }
        return RemoteKeyEvent(
            scanCode: mapping.scanCode,
            phase: phase,
            isExtended: mapping.isExtended
        )
    }
}
