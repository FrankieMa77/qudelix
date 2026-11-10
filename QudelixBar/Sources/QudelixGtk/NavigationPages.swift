package struct NavigationEntry: Equatable {
    package let id: String
    package let title: String
    package let icon: String
    package let summary: String
}

package enum NavigationPages {
    package static let entries: [NavigationEntry] = [
        NavigationEntry(id: "device", title: "Device", icon: "audio-headphones-symbolic",
                        summary: "Connection, volume and output settings"),
        NavigationEntry(id: "eq", title: "EQ", icon: "media-playlist-shuffle-symbolic",
                        summary: "Equalizer curve and band controls"),
        NavigationEntry(id: "presets", title: "Presets", icon: "view-list-symbolic",
                        summary: "Presets stored on the device"),
        NavigationEntry(id: "library", title: "Library", icon: "folder-symbolic",
                        summary: "Local presets, AutoEq and AI suggestions"),
        NavigationEntry(id: "tune", title: "Tune", icon: "emblem-system-symbolic",
                        summary: "Tune the EQ by ear"),
        NavigationEntry(id: "stage", title: "Stage", icon: "audio-speakers-symbolic",
                        summary: "Balance, crossfeed, limiter and room for system audio"),
        NavigationEntry(id: "level", title: "Level", icon: "audio-volume-medium-symbolic",
                        summary: "Output meter, ear level and stream quality")
    ]

    package static func index(of id: String) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    package static func entry(at index: Int) -> NavigationEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    package static func entry(for id: String) -> NavigationEntry? {
        entries.first { $0.id == id }
    }

    package static func neighbour(of id: String, offset: Int) -> String? {
        guard let index = index(of: id) else { return nil }
        return entry(at: index + offset)?.id
    }

    package static func actionName(for id: String) -> String {
        "page-" + id
    }

    package static func accelerator(at index: Int) -> String? {
        entries.indices.contains(index) ? "<Alt>\(index + 1)" : nil
    }
}
