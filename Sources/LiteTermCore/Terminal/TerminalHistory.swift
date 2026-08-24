public struct TerminalHistory: Sendable {
    private static let maximumLineCount = 2_000
    private static let maximumLineBytes = 64 * 1024

    private let limit: Int
    private var buffer: [String?]
    private var startIndex = 0
    private var count = 0

    public init(limit: Int = 2_000) {
        self.limit = min(max(0, limit), Self.maximumLineCount)
        buffer = Array(repeating: nil, count: self.limit)
    }

    public var lines: [String] {
        guard count > 0 else {
            return []
        }

        return (0..<count).map { offset in
            buffer[(startIndex + offset) % limit]!
        }
    }

    public mutating func append(_ line: String) {
        guard limit > 0 else {
            return
        }

        let boundedLine = Self.bounded(line)

        if count < limit {
            buffer[(startIndex + count) % limit] = boundedLine
            count += 1
        } else {
            buffer[startIndex] = boundedLine
            startIndex = (startIndex + 1) % limit
        }
    }

    public mutating func clear() {
        buffer = Array(repeating: nil, count: limit)
        startIndex = 0
        count = 0
    }

    private static func bounded(_ line: String) -> String {
        guard line.utf8.count > maximumLineBytes else { return line }
        var bytes = Array(line.utf8.prefix(maximumLineBytes))
        while !bytes.isEmpty {
            if let bounded = String(bytes: bytes, encoding: .utf8) {
                return bounded
            }
            bytes.removeLast()
        }
        return ""
    }
}
