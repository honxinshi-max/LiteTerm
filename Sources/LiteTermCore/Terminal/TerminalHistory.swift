public struct TerminalHistory: Sendable {
    private static let maximumLineCount = 200
    private static let maximumLineBytes = 16 * 1024
    private static let maximumTotalBytes = 128 * 1024

    private let limit: Int
    private let totalByteLimit: Int
    private var storage: [String] = []
    private var navigationIndex: Int?
    public private(set) var totalByteCount = 0

    public init(limit: Int = 200, totalByteLimit: Int = 128 * 1024) {
        self.limit = min(max(0, limit), Self.maximumLineCount)
        self.totalByteLimit = min(max(0, totalByteLimit), Self.maximumTotalBytes)
    }

    public var lines: [String] {
        storage
    }

    public mutating func append(_ line: String) {
        guard limit > 0, totalByteLimit > 0 else {
            return
        }

        let boundedLine = Self.bounded(line, byteLimit: min(Self.maximumLineBytes, totalByteLimit))
        storage.append(boundedLine)
        totalByteCount += boundedLine.utf8.count
        while storage.count > limit || totalByteCount > totalByteLimit {
            totalByteCount -= storage.removeFirst().utf8.count
        }
        navigationIndex = nil
    }

    public mutating func clear() {
        storage.removeAll(keepingCapacity: false)
        totalByteCount = 0
        navigationIndex = nil
    }

    public mutating func previous() -> String? {
        guard !storage.isEmpty else { return nil }
        let nextIndex = navigationIndex.map { max(0, $0 - 1) } ?? (storage.count - 1)
        navigationIndex = nextIndex
        return storage[nextIndex]
    }

    public mutating func next() -> String? {
        guard let currentIndex = navigationIndex else { return nil }
        let nextIndex = currentIndex + 1
        guard nextIndex < storage.count else {
            navigationIndex = nil
            return ""
        }
        navigationIndex = nextIndex
        return storage[nextIndex]
    }

    private static func bounded(_ line: String, byteLimit: Int) -> String {
        guard line.utf8.count > byteLimit else { return line }
        var bytes = Array(line.utf8.prefix(byteLimit))
        while !bytes.isEmpty {
            if let bounded = String(bytes: bytes, encoding: .utf8) {
                return bounded
            }
            bytes.removeLast()
        }
        return ""
    }
}
