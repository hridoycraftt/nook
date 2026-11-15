import SwiftUI

/// One search result: a setting (or a page) and the page it is on.
struct SettingsHit: Identifiable, Hashable {
    let title: String
    let tab: SettingsTab
    /// The page itself, not a setting on it.
    let isPage: Bool
    var id: String { tab.rawValue + "|" + title }
}

/// Searches every label in Settings (in English and in Bangla), like System Settings.
enum SettingsSearch {
    /// Every label with its page: the generated index, plus names that live in code
    /// (wallpapers, Home widgets, pop-up kinds, island tabs).
    static let entries: [(String, SettingsTab)] = {
        var list: [(String, SettingsTab)] = SettingsIndex.labels.compactMap { pair in
            SettingsTab(rawValue: pair.1).map { (pair.0, $0) }
        }
        list += LiveStyle.allCases.map { ($0.title, .wallpaper) }
        list += HomeWidget.allCases.map { ($0.title, .home) }
        list += PeekType.allCases.map { ($0.title, .alerts) }
        list += IslandTab.allCases.map { ($0.title, .island) }
        return list
    }()

    static func results(_ raw: String) -> [SettingsHit] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        func score(_ text: String) -> Int? {
            let shown = L(text)
            for candidate in [shown, text] {
                if candidate.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
                if candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil { return 1 }
                // A word that starts with what was typed ("dim" finds "Night Dimming").
                if candidate.range(of: "\\b" + NSRegularExpression.escapedPattern(for: query),
                                   options: [.regularExpression, .caseInsensitive]) != nil { return 2 }
                if candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return 3 }
            }
            return nil
        }
        var hits: [(SettingsHit, Int)] = []
        var seen = Set<String>()
        for tab in SettingsTab.allCases {
            if let s = score(tab.title) {
                let hit = SettingsHit(title: tab.title, tab: tab, isPage: true)
                hits.append((hit, s - 1))
                seen.insert(hit.id)
            }
        }
        for (title, tab) in entries {
            guard let s = score(title) else { continue }
            let hit = SettingsHit(title: title, tab: tab, isPage: false)
            guard !seen.contains(hit.id) else { continue }
            seen.insert(hit.id)
            hits.append((hit, s))
        }
        return hits.sorted { a, b in
            a.1 != b.1 ? a.1 < b.1 : L(a.0.title).count < L(b.0.title).count
        }.prefix(60).map(\.0)
    }
}

/// A search result row: the setting, and the page it is on with its coloured icon.
struct SettingsHitRow: View {
    let hit: SettingsHit

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: hit.tab.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hit.tab.color.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(L(hit.title)).font(.system(size: 12, weight: hit.isPage ? .semibold : .regular)).lineLimit(2)
                if !hit.isPage {
                    Text(L(hit.tab.title)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

/// After jumping to a setting, its name shows at the top of the page for a few seconds,
/// so it is easy to spot.
struct SettingsFoundBanner: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        if let title = router.highlight {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text(L(title)).lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
            .padding(.vertical, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(router.highlightID)
        }
    }
}
