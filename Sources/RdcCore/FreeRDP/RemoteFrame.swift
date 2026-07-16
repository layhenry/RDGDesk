import Foundation

public struct RemoteFrame: Equatable, Sendable {
    public let identity: UInt64
    public let width: Int
    public let height: Int
    public let stride: Int
    public let bgraBytes: [UInt8]

    public init(width: Int, height: Int, stride: Int, bgraBytes: [UInt8]) {
        precondition(width > 0 && height > 0 && stride >= width * 4)
        precondition(bgraBytes.count == stride * height)
        self.identity = RemoteFrameIdentitySource.shared.next()
        self.width = width
        self.height = height
        self.stride = stride
        self.bgraBytes = Array(bgraBytes)
    }

    public static func == (lhs: RemoteFrame, rhs: RemoteFrame) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.stride == rhs.stride
            && lhs.bgraBytes == rhs.bgraBytes
    }
}

private final class RemoteFrameIdentitySource: @unchecked Sendable {
    static let shared = RemoteFrameIdentitySource()

    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        precondition(value < UInt64.max, "Remote frame identity exhausted")
        value += 1
        return value
    }
}
