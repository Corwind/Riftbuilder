public extension AssemblyExecutor {
    func execute(_ plan: DisassemblyPlan) async throws -> AssemblyExecutionReport {
        try await execute(plan.executablePlan)
    }
}
