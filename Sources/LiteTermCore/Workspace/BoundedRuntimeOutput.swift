public struct BoundedRuntimeOutput: Equatable, Sendable {
    public static let maximumLineLimit = 2_000
    public static let maximumByteLimit = 2 * 1_024 * 1_024
    public static let truncationMarker = "[output truncated]"

    private let lineLimit: Int
    private let byteLimit: Int
    private var storage: [String] = []
    public private(set) var didTruncate = false

    public init(
        lineLimit: Int = Self.maximumLineLimit,
        byteLimit: Int = Self.maximumByteLimit
    ) {
        self.lineLimit = min(max(0, lineLimit), Self.maximumLineLimit)
        self.byteLimit = min(max(0, byteLimit), Self.maximumByteLimit)
    }

    public var lines: [String] {
        didTruncate ? [Self.truncationMarker] + storage : storage
    }

    public var totalByteCount: Int {
        storage.reduce(didTruncate ? Self.truncationMarker.utf8.count : 0) {
            $0 + $1.utf8.count
        }
    }

    public mutating func append(_ line: String) {
        guard lineLimit > 0, byteLimit > 0 else {
            didTruncate = true
            storage.removeAll(keepingCapacity: false)
            return
        }

        let initialByteBudget = didTruncate ? contentByteLimit : byteLimit
        let boundedLine = Self.bounded(line, byteLimit: initialByteBudget)
        let lineWasTruncated = boundedLine.utf8.count < line.utf8.count
        storage.append(boundedLine)
        if lineWasTruncated || didTruncate || storage.count > lineLimit || contentBytes > byteLimit {
            didTruncate = true
            rebalanceAfterTruncation()
        }
    }

    public mutating func clear() {
        storage.removeAll(keepingCapacity: false)
        didTruncate = false
    }

    private var markerByteCount: Int {
        Self.truncationMarker.utf8.count
    }

    private var contentLineLimit: Int {
        max(0, lineLimit - 1)
    }

    private var contentByteLimit: Int {
        max(0, byteLimit - markerByteCount)
    }

    private var contentBytes: Int {
        storage.reduce(0) { $0 + $1.utf8.count }
    }

    private mutating func rebalanceAfterTruncation() {
        guard contentLineLimit > 0, contentByteLimit > 0 else {
            storage.removeAll(keepingCapacity: false)
            return
        }

        if let last = storage.last, last.utf8.count > contentByteLimit {
            storage[storage.count - 1] = Self.bounded(last, byteLimit: contentByteLimit)
        }
        while storage.count > contentLineLimit || contentBytes > contentByteLimit {
            storage.removeFirst()
        }
    }

    private static func bounded(_ value: String, byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }
        guard value.utf8.count > byteLimit else { return value }
        var bytes = Array(value.utf8.prefix(byteLimit))
        while !bytes.isEmpty {
            if let result = String(bytes: bytes, encoding: .utf8) {
                return result
            }
            bytes.removeLast()
        }
        return ""
    }
}
