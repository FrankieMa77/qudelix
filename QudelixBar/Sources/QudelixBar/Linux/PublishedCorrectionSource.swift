import Foundation

package enum CataloguePhase: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

@MainActor
protocol CatalogueSource: CorrectionSource {
    var phase: CataloguePhase { get }
    var loadHandle: Task<Void, Never>? { get }
    var catalogueSize: Int { get }
}

extension AutoEqService: CatalogueSource {
    var phase: CataloguePhase {
        switch state {
        case .idle: return .idle
        case .loading: return .loading
        case .ready: return .ready
        case .failed(let why): return .failed(why)
        }
    }

    var loadHandle: Task<Void, Never>? { loadTask }

    var catalogueSize: Int { models.count }
}

@MainActor
final class PublishedCorrectionSource: CatalogueSource {
    let index: AutoEqIndex
    private let preset: @Sendable (AutoEqEntry) async throws -> ParametricEQFile

    init(index: AutoEqIndex,
         preset: @escaping @Sendable (AutoEqEntry) async throws -> ParametricEQFile) {
        self.index = index
        self.preset = preset
    }

    convenience init(environment: LibraryEnvironment) {
        self.init(index: AutoEqIndex(fetcher: environment.publishedIndex),
                  preset: environment.publishedPreset)
    }

    var displayName: String { index.displayName }

    var phase: CataloguePhase {
        switch index.state {
        case .idle: return .idle
        case .loading: return .loading
        case .ready: return .ready
        case .failed(let why): return .failed(why)
        }
    }

    var loadHandle: Task<Void, Never>? { index.loadTask }

    var catalogueSize: Int { index.entries.count }

    func prepare() { index.prepare() }

    func search(_ query: String) -> [CorrectionCandidate] { index.search(query) }

    func correction(for candidate: CorrectionCandidate,
                    shapedFor limits: DeviceEQLimits,
                    options rawOptions: CorrectionOptions) async throws -> CorrectionResult {
        let options = rawOptions.quantized()
        let entry = AutoEqEntry(title: candidate.title, source: candidate.source,
                                path: candidate.token)
        let file: ParametricEQFile
        do {
            file = try await preset(entry)
        } catch {
            throw AutoEqService.mapped(error, host: AutoEqIndex.host)
        }
        var warnings: [String] = []
        if let unhonoured = AutoEqIndex.ceilingWarning(for: options, limits: limits) {
            warnings.append(unhonoured)
        }
        if let unhonoured = AutoEqService.unhonouredTargetWarning(for: options) {
            warnings.append(unhonoured)
        }
        if let unhonoured = AutoEqService.unhonouredPersonalizationWarning(for: options) {
            warnings.append(unhonoured)
        }
        let reshaped = file.bands.prefix(limits.bandCount).filter { !limits.admits($0) }.count
        if reshaped > 0 {
            warnings.append("\(reshaped) band(s) fall outside what the device accepts and will be clamped")
        }
        if abs(file.preamp) > limits.maxPreamp {
            warnings.append(String(format: "pre-gain %.1f dB exceeds the device's \u{00B1}%.0f dB",
                                   file.preamp, limits.maxPreamp))
        }
        return CorrectionResult(
            file: file,
            provenance: "\(candidate.title) \u{00B7} \(candidate.detail) \u{2192} published preset",
            warnings: warnings)
    }
}
