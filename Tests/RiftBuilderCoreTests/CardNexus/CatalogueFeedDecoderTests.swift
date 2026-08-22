import Foundation
import XCTest
@testable import RiftBuilderCore

@MainActor
final class CatalogueFeedDecoderTests: XCTestCase {
    func testNDJSONMapsCardsPreservesAttributesAndSkipsSealedProducts() async throws {
        let data = Data("""
        {"id":501,"productType":"card","name":"Ahri, Charmer","nameSlug":"ahri-charmer","slug":"ogn-ahri-charmer-001","expansionId":9,"expansionSlug":"origins","printNumber":"001","variant":null,"rarity":"Epic","finishes":["Standard","Foil"],"languages":["en","fr"],"imageUrl":"https://images.example/front.jpg","imageBackUrl":null,"attributes":{"domains":["Calm","Chaos"],"energyCost":3,"customFutureField":{"enabled":true}}}
        {"id":502,"productType":"sealed","name":"Booster Box","nameSlug":"booster-box","slug":"ogn-booster-box","expansionId":9,"expansionSlug":"origins","printNumber":null,"variant":null,"rarity":null,"finishes":[],"languages":[],"imageUrl":null,"imageBackUrl":null,"attributes":{}}

        """.utf8)
        let cards = try await collect(NDJSONCatalogueParser.parse(data))
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].productID, 501)
        XCTAssertEqual(cards[0].nameSlug, "ahri-charmer")
        XCTAssertEqual(cards[0].printingSlug, "ogn-ahri-charmer-001")
        XCTAssertEqual(cards[0].finishes, ["Standard", "Foil"])
        XCTAssertEqual(cards[0].attributes["energyCost"], .number(3))
        XCTAssertEqual(cards[0].attributes["customFutureField"], .object(["enabled": .bool(true)]))
    }

    func testMalformedNDJSONReportsLineNumber() async {
        do {
            _ = try await collect(NDJSONCatalogueParser.parse(Data("{}\nnot-json\n".utf8)))
            XCTFail("Expected decoding failure")
        } catch let error as CardNexusClientError {
            guard case let .decoding(description, _) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(description.contains("catalogue line 1"))
        } catch { XCTFail("Unexpected \(error)") }
    }

    func testIdentityDecoderUsesSameNDJSONPipeline() async throws {
        let json = #"{"id":1,"productType":"card","name":"Test","nameSlug":"test","slug":"set-test","expansionId":null,"expansionSlug":null,"printNumber":null,"variant":null,"rarity":null,"finishes":[],"languages":[],"imageUrl":null,"imageBackUrl":null,"attributes":{}}"#
        let cards = try await collect(AppleGzipCatalogueDecoder().decode(Data(json.utf8), encoding: "identity"))
        XCTAssertEqual(cards.map(\.productID), [1])
    }
}

private func collect(_ stream: AsyncThrowingStream<CardPrinting, any Error>) async throws -> [CardPrinting] {
    var result: [CardPrinting] = []
    for try await element in stream { result.append(element) }
    return result
}
