import SwiftUI

struct DebugView: View {
    @Bindable var debugLog: DebugLogModel
    @State private var searchText = ""
    @State private var selectedMatchIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            logList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Debug")
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("Search request and response logs", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search debug logs")

            Button {
                moveMatch(by: -1)
            } label: {
                Label("Previous Match", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(matches.isEmpty)
            .keyboardShortcut(.upArrow, modifiers: [.command])

            Button {
                moveMatch(by: 1)
            } label: {
                Label("Next Match", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(matches.isEmpty)
            .keyboardShortcut(.downArrow, modifiers: [.command])

            Text(matchPositionText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)

            Button("Clear") {
                debugLog.clear()
                selectedMatchIndex = nil
            }
            .disabled(debugLog.entries.isEmpty)
        }
        .padding(12)
        .onChange(of: searchText) {
            selectedMatchIndex = matches.isEmpty ? nil : 0
        }
    }

    private var logList: some View {
        Group {
            if debugLog.entries.isEmpty {
                ContentUnavailableView(
                    "No HTTP logs",
                    systemImage: "network",
                    description: Text("CardNexus requests and responses made while debug mode is enabled will appear here.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(debugLog.entries) { entry in
                                DebugLogRow(
                                    entry: entry,
                                    query: normalizedSearch,
                                    selectedOccurrence: selectedOccurrence(in: entry)
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: selectedMatchIndex) {
                        scrollToSelectedMatch(using: proxy)
                    }
                    .onChange(of: debugLog.entries.last?.id) {
                        if normalizedSearch.isEmpty, let lastID = debugLog.entries.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        } else {
                            normalizeSelectedMatch()
                        }
                    }
                }
            }
        }
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [DebugSearchMatch] {
        guard !normalizedSearch.isEmpty else { return [] }
        return debugLog.entries.flatMap { entry in
            entry.searchableText.matchRanges(for: normalizedSearch).indices.map {
                DebugSearchMatch(entryID: entry.id, occurrence: $0)
            }
        }
    }

    private var matchPositionText: String {
        guard !normalizedSearch.isEmpty else { return "" }
        guard let selectedMatchIndex, !matches.isEmpty else { return "0 matches" }
        return "\(selectedMatchIndex + 1) of \(matches.count)"
    }

    private func selectedOccurrence(in entry: DebugLogEntry) -> Int? {
        guard let selectedMatchIndex, matches.indices.contains(selectedMatchIndex) else { return nil }
        let selected = matches[selectedMatchIndex]
        return selected.entryID == entry.id ? selected.occurrence : nil
    }

    private func moveMatch(by offset: Int) {
        guard !matches.isEmpty else {
            selectedMatchIndex = nil
            return
        }
        let current = selectedMatchIndex ?? (offset > 0 ? -1 : 0)
        selectedMatchIndex = (current + offset + matches.count) % matches.count
    }

    private func normalizeSelectedMatch() {
        guard !matches.isEmpty else {
            selectedMatchIndex = nil
            return
        }
        if let selectedMatchIndex {
            self.selectedMatchIndex = min(selectedMatchIndex, matches.count - 1)
        } else {
            selectedMatchIndex = 0
        }
    }

    private func scrollToSelectedMatch(using proxy: ScrollViewProxy) {
        guard let selectedMatchIndex, matches.indices.contains(selectedMatchIndex) else { return }
        withAnimation {
            proxy.scrollTo(matches[selectedMatchIndex].entryID, anchor: .center)
        }
    }
}

private struct DebugSearchMatch {
    let entryID: UUID
    let occurrence: Int
}

private struct DebugLogRow: View {
    let entry: DebugLogEntry
    let query: String
    let selectedOccurrence: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(headline)
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                if entry.attempt > 1 {
                    Text("attempt \(entry.attempt)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(highlighted(entry.searchableText, query: query, selectedOccurrence: selectedOccurrence))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            ThemedCardSurface(cornerRadius: 12, tintStrength: 0.045, shadowStrength: 0.05)
        }
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        switch entry.kind {
        case .request:
            "\(entry.method) \(entry.path)"
        case let .response(statusCode):
            "\(statusCode.map(String.init) ?? "ERROR") · \(entry.method) \(entry.path)"
        }
    }

    private var icon: String {
        switch entry.kind {
        case .request: "arrow.up.right"
        case .response: "arrow.down.left"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .request:
            return .blue
        case let .response(statusCode):
            guard let statusCode else { return .red }
            return (200 ..< 300).contains(statusCode) ? .green : .orange
        }
    }

    private func highlighted(_ text: String, query: String, selectedOccurrence: Int?) -> AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }

        let ranges = text.matchRanges(for: query)
        var result = AttributedString()
        var cursor = text.startIndex
        for (index, range) in ranges.enumerated() {
            result.append(AttributedString(String(text[cursor ..< range.lowerBound])))
            var match = AttributedString(String(text[range]))
            match.foregroundColor = .black
            match.backgroundColor = index == selectedOccurrence ? .orange : .yellow
            result.append(match)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(text[cursor...])))
        return result
    }
}

private extension String {
    func matchRanges(for query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var remaining = startIndex ..< endIndex
        while let range = range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
            result.append(range)
            guard range.upperBound < endIndex else { break }
            remaining = range.upperBound ..< endIndex
        }
        return result
    }
}
