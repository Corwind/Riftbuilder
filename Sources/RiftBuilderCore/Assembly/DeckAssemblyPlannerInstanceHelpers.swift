import Foundation

extension DeckAssemblyPlanner {
    /// Instance-context counterpart used by the planner's candidate comparator.
    func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}
