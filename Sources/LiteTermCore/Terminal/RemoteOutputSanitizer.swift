public struct RemoteOutputSanitizer: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case dcs
        case dcsEscape
    }

    private var state: State = .ground

    public init() {}

    /// The sanitizer holds only a possible ESC introducer while deciding whether
    /// it begins a DCS. DCS payload bytes are discarded as they arrive.
    public var bufferedByteCount: Int {
        switch state {
        case .escape, .dcsEscape:
            return 1
        case .ground, .dcs:
            return 0
        }
    }

    public mutating func sanitize(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []

        for byte in bytes {
            switch state {
            case .ground:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x90:
                    state = .dcs
                default:
                    output.append(byte)
                }

            case .escape:
                switch byte {
                case 0x50:
                    state = .dcs
                case 0x1B:
                    output.append(0x1B)
                case 0x90:
                    state = .dcs
                default:
                    output.append(0x1B)
                    output.append(byte)
                    state = .ground
                }

            case .dcs:
                switch byte {
                case 0x1B:
                    state = .dcsEscape
                case 0x18, 0x1A:
                    state = .ground
                case 0x9C:
                    state = .ground
                default:
                    break
                }

            case .dcsEscape:
                switch byte {
                case 0x18, 0x1A, 0x5C, 0x9C:
                    state = .ground
                case 0x1B:
                    break
                case 0x50, 0x90:
                    state = .dcs
                default:
                    output.append(0x1B)
                    output.append(byte)
                    state = .ground
                }
            }
        }

        return output
    }
}
