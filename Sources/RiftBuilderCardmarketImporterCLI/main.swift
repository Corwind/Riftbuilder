import Foundation
import RiftBuilderCardmarketImport

@main
struct RiftBuilderCardmarketImporterCLI {
    static func main() throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        if options.help {
            print(Options.usage)
            return
        }

        let report = try CardmarketProductsImporter.run(
            inputURL: options.inputURL,
            databasePath: options.databasePath,
            dryRun: options.dryRun
        )
        print(report.dryRun ? "Dry run completed; no listings were written." : "Import completed.")
        print("Input records: \(report.totalRecords)")
        print("Matched Cardmarket links: \(report.importedLinks)")
        print("Matched EUR prices: \(report.importedPrices)")
        print("Matched links without an EUR price: \(report.linksWithoutEURPrice)")
        print("Non-EUR or currency-less prices discarded: \(report.discardedNonEURPrices)")
        print("Unmatched records: \(report.unmatched.count)")
        print("Ambiguous records: \(report.ambiguous.count)")
        print("Conflicting associations: \(report.conflicts.count)")

        printDiagnostics("Unmatched", report.unmatched)
        printDiagnostics("Ambiguous", report.ambiguous)
        printDiagnostics("Conflicting", report.conflicts)
    }

    private static func printDiagnostics(
        _ heading: String,
        _ diagnostics: [CardmarketImportDiagnostic]
    ) {
        guard !diagnostics.isEmpty else { return }
        print("\n\(heading):")
        for diagnostic in diagnostics {
            print("  line \(diagnostic.line): \(diagnostic.cardName) — \(diagnostic.detail)")
        }
    }
}

private struct Options {
    let inputURL: URL
    let databasePath: String
    let dryRun: Bool
    let help: Bool

    init(arguments: [String]) throws {
        if arguments.contains("--help") || arguments.contains("-h") {
            inputURL = URL(fileURLWithPath: "")
            databasePath = ""
            dryRun = false
            help = true
            return
        }

        var inputPath: String?
        var databasePath: String?
        var dryRun = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--input":
                index += 1
                guard index < arguments.count else { throw OptionsError.missingValue("--input") }
                inputPath = arguments[index]
            case "--database":
                index += 1
                guard index < arguments.count else { throw OptionsError.missingValue("--database") }
                databasePath = arguments[index]
            case "--dry-run":
                dryRun = true
            default:
                throw OptionsError.unknownArgument(arguments[index])
            }
            index += 1
        }

        guard let inputPath else { throw OptionsError.missingInput }
        self.inputURL = URL(fileURLWithPath: inputPath)
        self.databasePath = databasePath ?? Self.defaultDatabasePath
        self.dryRun = dryRun
        help = false
    }

    static let usage = """
        Usage:
          riftbuilder-cardmarket-import --input <products.jsonl> [--database <riftbuilder.sqlite>] [--dry-run]

        The database defaults to:
          ~/Library/Application Support/RiftBuilder/riftbuilder.sqlite

        --dry-run applies pending schema migrations but does not write Cardmarket listings.
        """

    private static var defaultDatabasePath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "RiftBuilder/riftbuilder.sqlite")
            .path
    }
}

private enum OptionsError: LocalizedError {
    case missingInput
    case missingValue(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingInput:
            "Missing --input.\n\n\(Options.usage)"
        case let .missingValue(argument):
            "Missing value after \(argument).\n\n\(Options.usage)"
        case let .unknownArgument(argument):
            "Unknown argument \(argument).\n\n\(Options.usage)"
        }
    }
}
