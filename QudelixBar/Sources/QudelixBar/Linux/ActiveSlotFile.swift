import Foundation

enum ActiveSlotFile {
    static var directoryOverride: URL?

    static var url: URL {
        (directoryOverride ?? StageStateFile.directory)
            .appendingPathComponent("active-slot.json")
    }

    private static let maxBytes = 100_000

    static func record(slot: Int, group: QxEqGroup, preset: QxUserEqPreset,
                       identity: String?, to fileURL: URL = url) {
        let snapshot = EqSnapshot(groupRaw: group.rawValue, bands: preset.bands,
                                  preGain: preset.preGain, enabled: true, name: nil,
                                  mutedBands: [:], deviceIdentity: identity,
                                  activePreset: slot)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        _ = SafeFile.writeAtomic(data, to: fileURL)
    }

    static func slot(matching preset: QxUserEqPreset, group: QxEqGroup,
                     identity: String?, from fileURL: URL = url) -> Int? {
        guard let data = SafeFile.read(fileURL, cap: maxBytes),
              let snapshot = try? JSONDecoder().decode(EqSnapshot.self, from: data),
              let slot = snapshot.activePreset,
              (0..<QudelixController.presetCount).contains(slot),
              snapshot.groupRaw == group.rawValue,
              snapshot.deviceIdentity == identity,
              snapshot.preGain == preset.preGain,
              snapshot.bands == preset.bands else { return nil }
        return slot
    }
}
