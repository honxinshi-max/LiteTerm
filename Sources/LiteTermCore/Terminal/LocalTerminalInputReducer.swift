public enum LocalTerminalInputEvent: Equatable, Sendable {
    case echo([UInt8])
    case erase
    case interrupt
    case replaceLine([UInt8])
    case submit(String)
}

public enum LocalHistoryDirection: Sendable {
    case previous
    case next
}

public struct LocalTerminalInputReducer: Sendable {
    private let maximumInputBytes: Int
    private let maximumBatchBytes: Int
    private let maximumEventsPerReduction: Int
    private var input: [UInt8] = []
    private var partialScalar: [UInt8] = []
    private var expectedScalarByteCount = 0
    private var didReceiveCarriageReturn = false
    private var history = TerminalHistory()

    public init(
        maximumInputBytes: Int = 16 * 1024,
        maximumBatchBytes: Int = 16 * 1024,
        maximumEventsPerReduction: Int = 128
    ) {
        self.maximumInputBytes = max(0, maximumInputBytes)
        self.maximumBatchBytes = max(0, maximumBatchBytes)
        self.maximumEventsPerReduction = max(1, maximumEventsPerReduction)
    }

    public var bufferedPartialScalarByteCount: Int { partialScalar.count }

    public mutating func reset() {
        input.removeAll(keepingCapacity: false)
        partialScalar.removeAll(keepingCapacity: false)
        expectedScalarByteCount = 0
        didReceiveCarriageReturn = false
    }

    public mutating func navigateHistory(
        _ direction: LocalHistoryDirection
    ) -> [LocalTerminalInputEvent] {
        let line: String?
        switch direction {
        case .previous:
            line = history.previous()
        case .next:
            line = history.next()
        }
        guard let line else { return [] }
        input = Array(line.utf8.prefix(maximumInputBytes))
        partialScalar.removeAll(keepingCapacity: false)
        expectedScalarByteCount = 0
        didReceiveCarriageReturn = false
        return [.replaceLine(input)]
    }

    public mutating func reduce(_ bytes: [UInt8]) -> [LocalTerminalInputEvent] {
        var events: [LocalTerminalInputEvent] = []
        var echoRun: [UInt8] = []

        func flushEcho() {
            guard !echoRun.isEmpty else { return }
            guard events.count < maximumEventsPerReduction else { return }
            events.append(.echo(echoRun))
            echoRun.removeAll(keepingCapacity: true)
        }

        func submit() {
            guard events.count < maximumEventsPerReduction else { return }
            let command = String(bytes: input, encoding: .utf8) ?? ""
            events.append(.submit(command))
            if !command.isEmpty {
                history.append(command)
            }
            input.removeAll(keepingCapacity: true)
        }

        for byte in bytes.prefix(maximumBatchBytes) {
            guard events.count < maximumEventsPerReduction else { break }

            if !partialScalar.isEmpty {
                if byte & 0xC0 == 0x80 {
                    partialScalar.append(byte)
                    if partialScalar.count == expectedScalarByteCount {
                        let scalar = partialScalar
                        partialScalar.removeAll(keepingCapacity: true)
                        expectedScalarByteCount = 0
                        if String(bytes: scalar, encoding: .utf8) != nil,
                           input.count + scalar.count <= maximumInputBytes {
                            input.append(contentsOf: scalar)
                            echoRun.append(contentsOf: scalar)
                        }
                    }
                    continue
                }
                partialScalar.removeAll(keepingCapacity: true)
                expectedScalarByteCount = 0
            }

            if byte == 0x0A, didReceiveCarriageReturn {
                flushEcho()
                didReceiveCarriageReturn = false
                continue
            }
            if byte != 0x0A {
                didReceiveCarriageReturn = false
            }

            switch byte {
            case 0x03:
                flushEcho()
                input.removeAll(keepingCapacity: true)
                partialScalar.removeAll(keepingCapacity: true)
                expectedScalarByteCount = 0
                events.append(.interrupt)

            case 0x08, 0x7F:
                flushEcho()
                if !input.isEmpty {
                    if let current = String(bytes: input, encoding: .utf8) {
                        input = Array(current.dropLast().utf8)
                    } else {
                        input.removeLast()
                    }
                    events.append(.erase)
                }

            case 0x0D:
                let requiredEvents = (echoRun.isEmpty ? 0 : 1) + 1
                guard events.count + requiredEvents <= maximumEventsPerReduction else { break }
                flushEcho()
                submit()
                didReceiveCarriageReturn = true

            case 0x0A:
                let requiredEvents = (echoRun.isEmpty ? 0 : 1) + 1
                guard events.count + requiredEvents <= maximumEventsPerReduction else { break }
                flushEcho()
                submit()

            default:
                if byte < 0x80 {
                    guard input.count < maximumInputBytes else { continue }
                    input.append(byte)
                    echoRun.append(byte)
                } else if let scalarByteCount = Self.scalarByteCount(forLeadByte: byte) {
                    partialScalar = [byte]
                    expectedScalarByteCount = scalarByteCount
                }
            }
        }

        flushEcho()
        return events
    }

    private static func scalarByteCount(forLeadByte byte: UInt8) -> Int? {
        switch byte {
        case 0xC2...0xDF:
            return 2
        case 0xE0...0xEF:
            return 3
        case 0xF0...0xF4:
            return 4
        default:
            return nil
        }
    }
}
