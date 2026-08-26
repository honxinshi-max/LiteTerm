public enum TerminalShortcutKey: String, CaseIterable, Equatable, Hashable, Sendable {
    case escape
    case control
    case tab
    case up
    case down
    case left
    case right
    case slash
}

public struct ShortcutInputReducer: Equatable, Sendable {
    public private(set) var isControlLatched = false

    public init() {}

    public mutating func handleShortcut(_ key: TerminalShortcutKey) -> [UInt8] {
        switch key {
        case .escape:
            return [0x1B]
        case .control:
            isControlLatched = true
            return []
        case .tab:
            return [0x09]
        case .up:
            return [0x1B, 0x5B, 0x41]
        case .down:
            return [0x1B, 0x5B, 0x42]
        case .right:
            return [0x1B, 0x5B, 0x43]
        case .left:
            return [0x1B, 0x5B, 0x44]
        case .slash:
            return reduceBytes([0x2F])
        }
    }

    public mutating func reduceText(_ text: String) -> [UInt8] {
        reduceBytes(Array(text.utf8))
    }

    public mutating func reduceBytes(_ bytes: [UInt8]) -> [UInt8] {
        guard isControlLatched,
              let printableIndex = bytes.firstIndex(where: { (0x20...0x7E).contains($0) }) else {
            return bytes
        }

        isControlLatched = false
        let scalar = Unicode.Scalar(UInt32(bytes[printableIndex]))!
        guard let controlByte = ControlKeyEncoder.encode(scalar) else {
            return bytes
        }

        var reduced = bytes
        reduced[printableIndex] = controlByte
        return reduced
    }
}
