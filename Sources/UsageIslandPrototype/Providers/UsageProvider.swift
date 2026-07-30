public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetchUsage() async throws -> UsageSnapshot
}
