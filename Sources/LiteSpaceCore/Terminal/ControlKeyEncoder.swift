public enum ControlKeyEncoder {
    public static func encode(_ scalar: Unicode.Scalar) -> UInt8? {
        let value = scalar.value
        let uppercasedValue: UInt32

        if (0x61...0x7A).contains(value) {
            uppercasedValue = value - 0x20
        } else {
            uppercasedValue = value
        }

        guard (0x40...0x5F).contains(uppercasedValue) else {
            return nil
        }

        return UInt8(uppercasedValue & 0x1F)
    }
}
