import Foundation

package struct CurvePreview: Equatable {
    package var title: String
    package var subtitle: String
    package var bands: [EqBand]
    package var preGain: Double
    package var requested: [EqBand]?

    package init(title: String, subtitle: String, bands: [EqBand], preGain: Double,
                 requested: [EqBand]? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.bands = bands
        self.preGain = preGain
        self.requested = requested
    }

    package var response: [Double] { EqCurveGeometry.response(bands: bands) }

    package var requestedResponse: [Double]? {
        requested.map { EqCurveGeometry.response(bands: $0) }
    }
}

package struct LibraryChoice: Equatable {
    package var id: String
    package var label: String

    package init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

struct LibraryEnvironment {
    var libraryFile: URL
    var autoEqTransport: HTTPTransport
    var ai: AIRuntime
    var searchDelay: TimeInterval = 0.4
    var publishedIndex: @Sendable (URL, Int) async throws -> Data = { url, limit in
        try await AutoEqIndex.fetch(url, limit: limit)
    }
    var publishedPreset: @Sendable (AutoEqEntry) async throws -> ParametricEQFile = { entry in
        try await AutoEqIndex.fetchPreset(entry)
    }

    static func system() -> LibraryEnvironment {
        LibraryEnvironment(libraryFile: PresetLibraryFile.url,
                           autoEqTransport: PinnedTransport(),
                           ai: AIRuntime())
    }
}

enum LibraryFormat {
    static func subtitle(group: QxEqGroup, preGain: Double, source: String? = nil) -> String {
        var parts = ["\(group.bandCount)-band", "pre-gain " + DisplayFormat.decibels(preGain)]
        if let source, !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func preview(title: String, group: QxEqGroup, bands: [QxEqBandValue],
                        preGain: Double, source: String? = nil,
                        requested: [QxEqBandValue]? = nil) -> CurvePreview {
        CurvePreview(title: title,
                     subtitle: subtitle(group: group, preGain: preGain, source: source),
                     bands: bands.map(EqBand.init),
                     preGain: preGain,
                     requested: requested.map { $0.map(EqBand.init) })
    }
}
