import Foundation

enum QuickFitPlan: Equatable {
    case fit(AutoEqEntry)
    case choose(query: String, note: String)

    @MainActor
    static func decide(name: String, entries: [AutoEqEntry]) -> QuickFitPlan {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = HeadphoneSuggestions.normalized(trimmed)
        guard needle.count >= HeadphoneSuggestions.minNeedleLength else {
            return .choose(query: trimmed,
                           note: "Search for your headphones to fit a correction \u{2014} "
                               + "the name isn't set or is too short to match.")
        }
        let ranked = HeadphoneSuggestions.matches(for: trimmed, in: entries)
        if let exact = ranked.first(where: { HeadphoneSuggestions.normalized($0.title) == needle }) {
            return .fit(exact)
        }
        let titles = Set(ranked.map { HeadphoneSuggestions.normalized($0.title) })
        if titles.count == 1, let only = ranked.first { return .fit(only) }
        if titles.count > 1 {
            return .choose(query: trimmed,
                           note: "More than one measurement matches \(SafeText.scrubbed(trimmed, limit: 48)) "
                               + "\u{2014} pick the right one.")
        }
        if let related = HeadphoneSuggestions.relatives(for: trimmed, in: entries) {
            return .choose(query: related.family,
                           note: "No measurement for \(SafeText.scrubbed(trimmed, limit: 48)) "
                               + "\u{2014} showing the \(SafeText.scrubbed(related.family, limit: 48)) family.")
        }
        return .choose(query: trimmed,
                       note: "No measurement found for \(SafeText.scrubbed(trimmed, limit: 48)) "
                           + "\u{2014} try another spelling.")
    }
}
