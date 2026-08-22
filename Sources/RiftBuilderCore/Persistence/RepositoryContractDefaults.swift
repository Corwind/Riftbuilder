public extension RiftBuilderRepository {
    func cardIdentities(nameSlugs: Set<String>) async throws -> [String: CardIdentity] { [:] }
    func catalogueIdentities(search: String?) async throws -> [CardIdentity] { [] }
    func catalogueCards(search: String?) async throws -> [CatalogueCardSummary] { [] }



    func catalogueChecksum() async throws -> String? { nil }
}
