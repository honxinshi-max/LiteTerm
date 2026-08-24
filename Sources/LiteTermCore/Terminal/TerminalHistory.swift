public struct TerminalHistory: Sendable {
    private let limit: Int
    private var buffer: [String?]
    private var startIndex = 0
    private var count = 0

    public init(limit: Int = 2_000) {
        self.limit = max(0, limit)
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

        if count < limit {
            buffer[(startIndex + count) % limit] = line
            count += 1
        } else {
            buffer[startIndex] = line
            startIndex = (startIndex + 1) % limit
        }
    }

    public mutating func clear() {
        buffer = Array(repeating: nil, count: limit)
        startIndex = 0
        count = 0
    }
}
