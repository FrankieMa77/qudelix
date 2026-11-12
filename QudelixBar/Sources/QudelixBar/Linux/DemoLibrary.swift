import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DemoCatalogueTransport: HTTPTransport {
    static let entries = """
    {
      "Sennheiser HD 650": [
        {"form": "over-ear", "rig": "GRAS 43AG", "source": "oratory1990"},
        {"form": "over-ear", "rig": "711", "source": "crinacle"}
      ],
      "Sennheiser HD 600": [
        {"form": "over-ear", "rig": "GRAS 43AG", "source": "oratory1990"}
      ],
      "Sennheiser HD 660S2": [
        {"form": "over-ear", "rig": "GRAS 43AG", "source": "oratory1990"}
      ],
      "Sennheiser HD 6XX": [
        {"form": "over-ear", "rig": "GRAS 43AG", "source": "Rtings"}
      ],
      "Sony WH-1000XM4": [
        {"form": "over-ear", "rig": "GRAS 43AG", "source": "oratory1990"}
      ],
      "Moondrop Aria": [
        {"form": "in-ear", "rig": "711", "source": "crinacle"}
      ]
    }
    """

    static let targets = """
    [
      {"label": "Harman over-ear 2018",
       "recommended": [{"source": "oratory1990", "form": "over-ear"}],
       "compatible": [{"source": "crinacle", "form": "over-ear"}]},
      {"label": "Diffuse field over-ear",
       "recommended": [],
       "compatible": [{"source": "oratory1990", "form": "over-ear"}]},
      {"label": "Harman in-ear 2019",
       "recommended": [{"source": "crinacle", "form": "in-ear"}],
       "compatible": []}
    ]
    """

    static let equalize = """
    {
      "parametric_eq": {
        "preamp": -4.6,
        "filters": [
          {"type": "LOW_SHELF", "fc": 105, "q": 0.7, "gain": 5.2},
          {"type": "PEAKING", "fc": 62, "q": 1.1, "gain": 1.4},
          {"type": "PEAKING", "fc": 240, "q": 0.9, "gain": -2.1},
          {"type": "PEAKING", "fc": 1180, "q": 1.3, "gain": -1.6},
          {"type": "PEAKING", "fc": 2900, "q": 1.6, "gain": 3.1},
          {"type": "PEAKING", "fc": 4800, "q": 2.4, "gain": -3.4},
          {"type": "PEAKING", "fc": 7300, "q": 3.2, "gain": 2.2},
          {"type": "HIGH_SHELF", "fc": 10000, "q": 0.7, "gain": -2.4}
        ]
      }
    }
    """

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        switch request.url?.path {
        case "/entries": return Data(Self.entries.utf8)
        case "/targets": return Data(Self.targets.utf8)
        case "/equalize": return Data(Self.equalize.utf8)
        default: throw URLError(.badURL)
        }
    }
}

final class DemoAITransport: AITransport, @unchecked Sendable {
    private let bandCount: Int

    init(bandCount: Int = 20) { self.bandCount = bandCount }

    private func chat(_ text: String) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: ["choices": [["message": ["content": text]]]])) ?? Data()
    }

    private var dossier: String {
        "{\"signature\": \"Warm and slightly veiled, with a lifted upper midrange\", "
            + "\"bass\": \"Full and soft below 80 Hz\", "
            + "\"mids\": \"Smooth, a little recessed around 1 kHz\", "
            + "\"treble\": \"Rolled off above 8 kHz\", "
            + "\"soundstage\": \"Intimate\", "
            + "\"knownIssues\": [{\"where\": \"3-5 kHz\", \"issue\": \"forward presence peak\"}], "
            + "\"confidence\": \"medium\"}"
    }

    private var draft: String {
        let freqs = QxEqGroup.b20.defaultFreqs
        let count = max(1, bandCount)
        let rows = (0..<count).map { index -> String in
            let freq = count == 20 ? freqs[index] : QxEqGroup.user.defaultFreqs[min(index, 9)]
            let gain = [3.0, 2.4, 1.6, 0.8, 0.2, -0.6, -1.2, -1.0, -0.4, 0.2,
                        0.6, 1.0, 1.8, 1.4, -0.8, -1.8, -1.2, 0.8, 1.4, 0.4][index % 20]
            let kind = index == 0 ? "lowShelf" : (index == count - 1 ? "highShelf" : "peak")
            return "{\"freq\": \(freq), \"gainDb\": \(gain), \"q\": 1.0, \"kind\": \"\(kind)\"}"
        }.joined(separator: ", ")
        return "{\"name\": \"Open Air 650\", \"rationale\": \"Opens the veiled midrange and "
            + "trims the 4 kHz presence peak while keeping the warm low end.\", "
            + "\"bands\": [\(rows)]}"
    }

    func send(_ request: URLRequest, host: String, limit: Int) async throws -> Data {
        let body = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let messages = body?["messages"] as? [[String: Any]]
        let system = messages?.first?["content"] as? String
        if system == AIPresetService.researchSystemPrompt { return chat(dossier) }
        return chat(draft)
    }
}

extension LibraryEnvironment {
    static func demo() -> LibraryEnvironment {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("qudelix-demo-library-" + UUID().uuidString,
                                    isDirectory: true)
        let keys = root.appendingPathComponent("keys", isDirectory: true)
        let research = root.appendingPathComponent("research", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("presets.json")
        PresetLibraryFile.save(PresetLibraryDocument(presets: demoPresets()), to: file)
        var runtime = AIRuntime()
        runtime.keychain = AIKeychain(directory: keys, environment: [:])
        runtime.transport = DemoAITransport()
        runtime.researchDirectory = research
        runtime.measurement = { _ in nil }
        runtime.readKey = { nil }
        return LibraryEnvironment(libraryFile: file,
                                  autoEqTransport: DemoCatalogueTransport(),
                                  ai: runtime, searchDelay: 0.05)
    }

    private static func demoPresets() -> [LibraryPreset] {
        func twenty(_ scale: Double) -> [QxEqBandValue] {
            DemoLink.bands.map { band in
                var copy = band
                copy.gain = max(-12, min(12, (band.gain * scale * 10).rounded() / 10))
                return copy
            }
        }
        func ten(_ gains: [Double]) -> [QxEqBandValue] {
            zip(QxEqGroup.user.defaultFreqs, gains).map {
                QxEqBandValue(filter: .peak, freq: $0, gain: $1, q: 1.1)
            }
        }
        return [
            LibraryPreset(name: "Harman target",
                          scope: .output(uid: DemoAudioBackend.fiveK.name, name: DemoAudioBackend.fiveK.description),
                          group: .b20, bands: twenty(1.0),
                          preGain: -3.5, sourceName: "Sennheiser HD 650"),
            LibraryPreset(name: "Late night", group: .b20, bands: twenty(0.4), preGain: -1.5),
            LibraryPreset(name: "Bass boost", group: .b20, bands: twenty(1.4), preGain: -4.5),
            LibraryPreset(name: "Podcast voice",
                          scope: .output(uid: DemoAudioBackend.speakers.name,
                                         name: DemoAudioBackend.speakers.description),
                          group: .user,
                          bands: ten([-3, -2, 0, 1.5, 2.5, 3, 1, 0, -1, -2]), preGain: -2.5),
            LibraryPreset(name: "Studio flat", group: .b20, bands: twenty(0.7), preGain: -2),
        ]
    }
}
