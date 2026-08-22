public enum DeckZoneCapacity {
    public static func maximumTotalQuantity(for zone: DeckZone) -> Int? {
        switch zone {
        case .legend, .chosenChampion:
            1
        case .battlefield:
            3
        case .rune:
            12
        case .sideboard:
            10
        case .main:
            nil
        }
    }

    public static func totalQuantity(in zone: DeckZone, entries: [DeckEntry]) -> Int {
        entries.lazy.filter { $0.zone == zone }.reduce(0) { $0 + max(0, $1.quantity) }
    }

    public static func remainingQuantity(in zone: DeckZone, entries: [DeckEntry]) -> Int? {
        maximumTotalQuantity(for: zone).map { maximum in
            max(0, maximum - totalQuantity(in: zone, entries: entries))
        }
    }

    public static func canAdd(nameSlug: String, to zone: DeckZone, entries: [DeckEntry]) -> Bool {
        if let remaining = remainingQuantity(in: zone, entries: entries), remaining == 0 {
            return false
        }
        if requiresUniqueCards(zone), entries.contains(where: { $0.zone == zone && $0.nameSlug == nameSlug && $0.quantity > 0 }) {
            return false
        }
        return true
    }
}

private extension DeckZoneCapacity {
    static func requiresUniqueCards(_ zone: DeckZone) -> Bool {
        switch zone {
        case .legend, .chosenChampion, .battlefield:
            true
        case .main, .rune, .sideboard:
            false
        }
    }
}
