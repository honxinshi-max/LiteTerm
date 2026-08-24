public enum LocalTerminalInputEvent: Equatable, Sendable {
    case echo([UInt8])
    case erase
    case interrupt
    case submit(String)
}

public struct LocalTerminalInputReducer: Sendable {
    private var input: [UInt8] = []
    private var didReceiveCarriageReturn = false

    public init() {}

    public mutating func reset() {
        input.removeAll(keepingCapacity: false)
        didReceiveCarriageReturn = false
    }

    public mutating func reduce(_ bytes: [UInt8]) -> [LocalTerminalInputEvent] {
        var events: [LocalTerminalInputEvent] = []
        var echoRun: [UInt8] = []

        func flushEcho() {
            guard !echoRun.isEmpty else { return }
            events.append(.echo(echoRun))
            echoRun.removeAll(keepingCapacity: true)
        }

        func submit() {
            events.append(.submit(String(decoding: input, as: UTF8.self)))
            input.removeAll(keepingCapacity: true)
        }

        for byte in bytes {
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
                flushEcho()
                submit()
                didReceiveCarriageReturn = true

            case 0x0A:
                flushEcho()
                submit()

            default:
                input.append(byte)
                echoRun.append(byte)
            }
        }

        flushEcho()
        return events
    }
}
