import Foundation

public struct ConstructedRuleset: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let effectiveDate: String
    public let sourceURL: URL
    public let mainDeckCount: Int
    public let runeCount: Int
    public let battlefieldCount: Int
    public let maximumCopiesByName: Int
    public let maximumSideboardCount: Int
    public let maximumSignatureCards: Int
    public let bannedCards: [String]
    public let bannedBattlefields: [String]
    public let legalExpansionSlugs: [String]?

    public init(
        id: String,
        name: String,
        effectiveDate: String,
        sourceURL: URL,
        mainDeckCount: Int,
        runeCount: Int,
        battlefieldCount: Int,
        maximumCopiesByName: Int,
        maximumSideboardCount: Int,
        maximumSignatureCards: Int,
        bannedCards: [String] = [],
        bannedBattlefields: [String] = [],
        legalExpansionSlugs: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.effectiveDate = effectiveDate
        self.sourceURL = sourceURL
        self.mainDeckCount = mainDeckCount
        self.runeCount = runeCount
        self.battlefieldCount = battlefieldCount
        self.maximumCopiesByName = maximumCopiesByName
        self.maximumSideboardCount = maximumSideboardCount
        self.maximumSignatureCards = maximumSignatureCards
        self.bannedCards = bannedCards
        self.bannedBattlefields = bannedBattlefields
        self.legalExpansionSlugs = legalExpansionSlugs
    }
}

public enum ConstructedRulesetLoader {
    public static func bundled(id: String = "constructed-2026-07-16") throws -> ConstructedRuleset {
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("RiftBuilder_RiftBuilderCore.bundle", isDirectory: true) }
            .flatMap(Bundle.init(url:))
        let resourceBundle = packagedBundle ?? Bundle.module
        guard let url = resourceBundle.url(forResource: id, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(id).json"])
        }
        return try JSONDecoder().decode(ConstructedRuleset.self, from: Data(contentsOf: url))
    }
}
