public struct RuntimeResourceBudget: Equatable, Sendable {
    public let idleResidentBytes: Int
    public let webResidentBytes: Int
    public let pythonResidentBytes: Int
    public let outputLineLimit: Int
    public let outputByteLimit: Int
    public let healthResponseByteLimit: Int
    public let healthSuccessCount: Int
    public let healthWindowSeconds: Int
    public let maximumBackgroundRuntimeCount: Int

    public init(
        idleResidentBytes: Int,
        webResidentBytes: Int,
        pythonResidentBytes: Int,
        outputLineLimit: Int,
        outputByteLimit: Int,
        healthResponseByteLimit: Int,
        healthSuccessCount: Int,
        healthWindowSeconds: Int,
        maximumBackgroundRuntimeCount: Int
    ) {
        self.idleResidentBytes = idleResidentBytes
        self.webResidentBytes = webResidentBytes
        self.pythonResidentBytes = pythonResidentBytes
        self.outputLineLimit = outputLineLimit
        self.outputByteLimit = outputByteLimit
        self.healthResponseByteLimit = healthResponseByteLimit
        self.healthSuccessCount = healthSuccessCount
        self.healthWindowSeconds = healthWindowSeconds
        self.maximumBackgroundRuntimeCount = maximumBackgroundRuntimeCount
    }

    public static let iPadCandidate = RuntimeResourceBudget(
        idleResidentBytes: 90 * 1_024 * 1_024,
        webResidentBytes: 160 * 1_024 * 1_024,
        pythonResidentBytes: 180 * 1_024 * 1_024,
        outputLineLimit: 2_000,
        outputByteLimit: 2 * 1_024 * 1_024,
        healthResponseByteLimit: 256 * 1_024,
        healthSuccessCount: 3,
        healthWindowSeconds: 5,
        maximumBackgroundRuntimeCount: 0
    )
}
