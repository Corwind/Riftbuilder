public enum DeckDeletionFinalizationPolicy {
    /// A deck definition may only be removed after a non-empty physical
    /// disassembly completed without any rejected, ambiguous, or skipped moves
    /// and the resulting CardNexus inventory was reconciled successfully.
    public static func canDeleteDefinition(after report: AssemblyExecutionReport, inventoryWasReconciled: Bool) -> Bool {
        !report.results.isEmpty && report.isFullySuccessful && inventoryWasReconciled
    }
}
