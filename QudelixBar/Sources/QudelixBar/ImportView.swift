import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImportView: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var stageState: StageState

    @ObservedObject private var autoEq = AutoEqIndex.shared
    @ObservedObject private var optimizer = AutoEqService.shared

    @State private var mode: Mode = .optimized
    @State private var bassBoost: Double = 0
    @State private var tilt: Double = 0
    @State private var selectedTarget: String?
    @State private var targetPickedByUser = false
    @State private var applyGate = ImportApplyGate()
    @State private var optimizedResults: [CorrectionCandidate] = []
    @State private var publishedResults: [CorrectionCandidate] = []
    @State private var limitToSourceCutoff = false
    @State private var lastPreference: PreferenceScore.Reading?

    private enum Mode { case optimized, published }

    private var limits: DeviceEQLimits { .qudelix(bandCount: controller.bandCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    openFile()
                } label: {
                    Label("Import file…", systemImage: "square.and.arrow.down")
                }
                Button {
                    pasteText()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(!controller.canWriteNow)
                .help("Import a correction from text on the clipboard — the "
                      + "filter list as published sites print it. Nothing on "
                      + "the clipboard that looks like one, nothing happens.")
                Button {
                    saveFile()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider()

            Picker("", selection: $mode) {
                Text("Fit to my device").tag(Mode.optimized)
                Text("Published preset").tag(Mode.published)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("Correction source")
            .help(mode == .optimized
                  ? "Ask AutoEq's optimizer for a correction that already fits this device"
                  : "Download AutoEq's published preset as-is")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search AutoEq — e.g. HD 650", text: $autoEq.query)
                    .textFieldStyle(.plain)
                    .onSubmit { prepareActive() }
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .onAppear {
                #if DEBUG
                if let seed = controller.previewAutoEq {
                    autoEq.seedForPreview(seed.entries, query: seed.query)
                    optimizer.seedForPreview(seed.entries.map {
                        AutoEqModel(name: $0.title,
                                    measurements: [AutoEqMeasurement(source: $0.source,
                                                                     form: "over-ear",
                                                                     rig: nil)])
                    })
                    refreshResults()
                    return
                }
                #endif
                prepareActive()
                refreshResults()
            }
            .onChange(of: mode) { _, _ in prepareActive() }
            .onChange(of: autoEq.query) { _, _ in refreshResults() }
            .onChange(of: optimizer.models) { _, _ in refreshResults() }
            .onChange(of: autoEq.entries) { _, _ in refreshResults() }

            if mode == .optimized { personalization }

            sourceCutoffOffer

            switch mode {
            case .optimized: optimizedSection
            case .published: publishedSection
            }

            if let summary = controller.lastImportSummary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let p = lastPreference, controller.curveMatchesSource { preferenceRow(p) }
        }
        .padding(.top, 6)
    }

    private var isLoading: Bool {
        mode == .optimized ? optimizer.state == .loading : autoEq.state == .loading
    }

    private func prepareActive() {
        activeSource.prepare()
    }

    private var activeSource: any CorrectionSource {
        mode == .optimized ? optimizer : autoEq
    }

    private func refreshResults() {
        let optimized = optimizer.search(autoEq.query)
        if optimized != optimizedResults { optimizedResults = optimized }
        let published = autoEq.search(autoEq.query)
        if published != publishedResults { publishedResults = published }
    }

    @ViewBuilder
    private var personalization: some View {
        VStack(alignment: .leading, spacing: 2) {
            targetRow
            slider("Bass", value: $bassBoost, in: CorrectionOptions.bassRange,
                   step: CorrectionOptions.bassStep,
                   display: String(format: "%+.1f dB", bassBoost),
                   help: "Low-shelf lift on top of the target. 0 dB is the target as published.")
            slider("Tilt", value: $tilt, in: CorrectionOptions.tiltRange,
                   step: CorrectionOptions.tiltStep,
                   display: String(format: "%+.2f", tilt) + " dB/oct",
                   help: "Overall slope. Negative is darker, positive brighter. 0 is the target as published.")

            HStack(spacing: 6) {
                Text("Fitted to the \(controller.bandCount)-band mode — asked for a curve this device can hold as-is.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                if bassBoost != 0 || tilt != 0 || selectedTarget != nil {
                    Button("Reset") {
                        bassBoost = 0
                        tilt = 0
                        selectedTarget = nil
                        targetPickedByUser = false
                    }
                    .buttonStyle(.link).font(.system(size: 9))
                }
            }
        }
    }

    private static let paramLabelWidth: CGFloat = 40

    @ViewBuilder
    private var targetRow: some View {
        HStack(spacing: 8) {
            Text("Target")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: Self.paramLabelWidth, alignment: .leading)
            Picker("", selection: Binding(get: { selectedTarget },
                                          set: { pick in
                                              selectedTarget = pick
                                              targetPickedByUser = pick != nil
                                          })) {
                Text("Recommended for this measurement").tag(String?.none)
                ForEach(AutoEqService.groupedTargets(optimizer.targets)) { group in
                    Section(group.form?.capitalized ?? "Other targets") {
                        ForEach(group.targets, id: \.label) { target in
                            Text(verbatim: target.label).tag(String?(target.label))
                        }
                    }
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Target curve")
            .onChange(of: optimizer.targets) { _, loaded in
                selectedTarget = AutoEqService.targetSelection(
                    selectedTarget, pickedByUser: targetPickedByUser, in: loaded)
            }
        }
        .help("""
            Which published target curve the correction is fitted to, before \
            bass and tilt are layered on top. Over-ear and in-ear curves are \
            fitted for different acoustics and aren't interchangeable, which \
            is why they're grouped apart here.
            """)
    }

    private var detectedCutoffHz: Double? {
        let kHz: Double
        switch stageState.qualityVerdict {
        case .lossy(let k), .lossyHigh(let k): kHz = k
        default: return nil
        }
        guard kHz.isFinite else { return nil }
        let hz = kHz * 1000
        guard hz >= CorrectionOptions.minCorrectionHz, hz < 20000 else { return nil }
        return hz
    }

    private var requestedCeilingHz: Double? {
        limitToSourceCutoff ? detectedCutoffHz : nil
    }

    @ViewBuilder
    private var sourceCutoffOffer: some View {
        if let hz = detectedCutoffHz {
            Toggle(isOn: $limitToSourceCutoff) {
                Text("Limit correction to \(CorrectionOptions.describeCeiling(hz)) — what's playing now stops there")
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("""
                Boosting above where the source stops amplifies the codec's own \
                artefacts, and the pre-gain it costs is taken off the whole band. \
                This measures what is playing right now, while the correction you \
                write is permanent — worth ticking only if most of what you listen \
                to is limited like this.
                """)
        }
    }

    private func slider(_ label: String, value: Binding<Double>,
                        in range: ClosedRange<Double>, step: Double,
                        display: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: Self.paramLabelWidth, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .accessibilityLabel(label)
            Text(display)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
                .lineLimit(1)
        }
        .help(help)
    }

    @ViewBuilder
    private var optimizedSection: some View {
        switch optimizer.state {
        case .idle, .loading:
            Text(verbatim: "Loading \(optimizer.displayName)…")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            HStack {
                Text(verbatim: "Couldn't load \(optimizer.displayName): \(msg)")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry") { optimizer.prepare() }
                    .buttonStyle(.link).font(.caption)
            }
        case .ready:
            candidateList(optimizedResults,
                          total: optimizer.models.count,
                          noun: "headphones")
        }
    }

    @ViewBuilder
    private var publishedSection: some View {
        switch autoEq.state {
        case .idle, .loading:
            Text(verbatim: "Loading \(autoEq.displayName)…")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            HStack {
                Text(verbatim: "Couldn't load \(autoEq.displayName): \(msg)")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry") { autoEq.loadIfNeeded() }
                    .buttonStyle(.link).font(.caption)
            }
        case .ready:
            candidateList(publishedResults,
                          total: autoEq.entries.count,
                          noun: "presets")
        }
    }

    @ViewBuilder
    private func candidateList(_ results: [CorrectionCandidate],
                               total: Int, noun: String) -> some View {
        if autoEq.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("\(total) \(noun) available. Start typing to search.")
                .font(.caption).foregroundStyle(.secondary)
        } else if results.isEmpty {
            Text("No match for “\(autoEq.query)”.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(results.prefix(AutoEqIndex.displayLimit)) { candidate in
                    resultRow(candidate)
                    Divider()
                }
            }
            if results.count > AutoEqIndex.displayLimit {
                Text("+\(results.count - AutoEqIndex.displayLimit) more — keep typing to narrow it down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func resultRow(_ candidate: CorrectionCandidate) -> some View {
        Button {
            apply(candidate)
        } label: {
            HStack(spacing: 6) {
                Text(candidate.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Text(candidate.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if applyGate.isApplying(candidate.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: mode == .optimized ? "wand.and.stars" : "arrow.down.circle")
                        .accessibilityHidden(true)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(applyGate.isBusy && !applyGate.isApplying(candidate.id))
    }

    private func apply(_ candidate: CorrectionCandidate) {
        guard applyGate.begin(candidate.id) else { return }
        let source = activeSource
        let options = CorrectionOptions(bassBoostGain: bassBoost, tilt: tilt,
                                        target: selectedTarget,
                                        maxCorrectionHz: requestedCeilingHz).quantized()
        Task {
            defer { applyGate.finish(candidate.id) }
            do {
                let result = try await source.correction(for: candidate, shapedFor: limits,
                                                         options: options)
                controller.apply(result.file, named: candidate.title)
                var parts = [result.provenance]
                if let applied = controller.lastImportSummary { parts.append(applied) }
                parts.append(contentsOf: result.warnings)
                controller.lastImportSummary = parts.joined(separator: " · ")
                lastPreference = result.preference
            } catch {
                controller.lastImportSummary = AutoEqService.describe(error)
            }
        }
    }

    private func preferenceRow(_ reading: PreferenceScore.Reading) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Predicted \(Int(reading.score.rounded())) — how a listening panel "
                 + "rated headphones this close to the target, on average.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("From a study of 31 over-ear models and 130 listeners. It predicts "
                 + "the group average to within about ±7, and roughly a third of "
                 + "listeners prefer more or less bass than the target — so it is "
                 + "not a measure of how this will sound to you.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(String(format: "Deviation from the target after this device's filters, "
                     + "over 50 Hz to 10 kHz: %.2f dB spread, %.2f dB per octave of tilt.",
                     reading.standardDeviation,
                     reading.absoluteSlope * log(2.0)))
    }

    private func pasteText() {
        lastPreference = nil
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            controller.lastImportSummary = "There is no text on the clipboard."
            return
        }
        controller.importText(text)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a parametric EQ file (AutoEq / Equalizer APO format)"
        AppDelegate.runFilePanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            lastPreference = nil
            controller.importFile(at: url)
        }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "QudelixEQ.txt"
        panel.message = "Save the current EQ"
        AppDelegate.runFilePanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            controller.exportFile(to: url)
        }
    }
}

struct ImportApplyGate: Equatable {
    private(set) var applying: String?

    var isBusy: Bool { applying != nil }

    func isApplying(_ id: String) -> Bool { applying == id }

    mutating func begin(_ id: String) -> Bool {
        guard applying == nil else { return false }
        applying = id
        return true
    }

    mutating func finish(_ id: String) {
        guard applying == id else { return }
        applying = nil
    }
}
