import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Import EQ presets from a file, from AutoEq's published presets, or by asking
/// AutoEq's optimizer for a correction fitted to this device's own limits.
struct ImportView: View {
    @EnvironmentObject var controller: QudelixController
    /// Read for one thing only: the live quality verdict, which is what the
    /// frequency-ceiling offer below is pre-filled from.
    @EnvironmentObject var stageState: StageState

    /// The published-preset path (also the search box's text holder, so the
    /// DEBUG preview seeding keeps working unchanged).
    @StateObject private var autoEq = AutoEqIndex()
    /// The optimizer path.
    @StateObject private var optimizer = AutoEqService()

    @State private var mode: Mode = .optimized
    @State private var bassBoost: Double = 0
    @State private var tilt: Double = 0
    /// nil is "recommended for this measurement" — resolved per candidate at
    /// apply time, the same as it always has been.
    @State private var selectedTarget: String?
    @State private var targetPickedByUser = false
    @State private var applying: String?
    /// Deliberately plain `@State`, never `@AppStorage`: it describes what is
    /// playing at this moment, not a preference. Remembering it across launches
    /// would silently apply one evening's stream to next month's corrections.
    @State private var limitToSourceCutoff = false
    /// The predicted rating for the correction just applied, if the model
    /// applies to it at all. Cleared whenever the correction is replaced, so
    /// it can never sit under a curve it was not computed from.
    @State private var lastPreference: PreferenceScore.Reading?

    /// Which correction source the results list is showing.
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
                    return
                }
                #endif
                prepareActive()
            }
            // Each catalogue is a few hundred kilobytes; fetch the one the user
            // is actually looking at, when they look at it.
            .onChange(of: mode) { _, _ in prepareActive() }

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
            // Gated on the curve still being the one that was scored, rather
            // than on enumerating the ways it can change. A drag, a Tune
            // session, a flatten, a slot load, a profile rule and a disconnect
            // all make this false; an undo back to the scored curve makes it
            // true again and the number returns with it, correctly.
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

    // MARK: - Personalization

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
                // "Asked for", not "got": the optimizer is sent this device's
                // limits, but the response can still come back outside them,
                // and the warnings printed a few lines below say so when it
                // does. Claiming nothing was clamped would contradict them on
                // the same screen.
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

    /// Shared by the target, bass and tilt rows so their controls line up.
    /// Sized for the longest label rather than the shortest: at 28pt, which
    /// fits "Bass" and "Tilt", "Target" wrapped and rendered as "Targe / t".
    private static let paramLabelWidth: CGFloat = 40

    /// The target picker. Only meaningful on the optimizer path — a published
    /// preset is already fitted to whichever target its author chose, and
    /// `apply` names that as unhonoured rather than pretending to redirect it.
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

    // MARK: - Frequency ceiling

    /// The cutoff the live verdict is reporting, in Hz, or nil when it isn't
    /// reporting one that could inform a correction.
    ///
    /// Only the two lossy verdicts carry a cutoff worth acting on. Everything
    /// else — lossless, hi-res, a natural roll-off, too quiet to judge, or no
    /// verdict at all because detection is off or the engine isn't running —
    /// has nothing to say about where a correction should stop.
    private var detectedCutoffHz: Double? {
        let kHz: Double
        switch stageState.qualityVerdict {
        case .lossy(let k), .lossyHigh(let k): kHz = k
        default: return nil
        }
        guard kHz.isFinite else { return nil }
        let hz = kHz * 1000
        // A cliff at the top of the audible band constrains nothing; offering
        // to "limit" a correction to 20 kHz would be offering a no-op.
        guard hz >= CorrectionOptions.minCorrectionHz, hz < 20000 else { return nil }
        return hz
    }

    /// What the apply below actually sends: nil unless the user ticked the box
    /// *and* the verdict still carries a cutoff.
    private var requestedCeilingHz: Double? {
        limitToSourceCutoff ? detectedCutoffHz : nil
    }

    /// Shown only when there is a real cutoff to offer, and unticked when it
    /// appears. There is no disabled or "unknown" version of this control: a
    /// greyed-out box invites the user to wonder what it would have said, and
    /// the answer is nothing.
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
            Text(display)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                // Wide enough for the longest reading ("+0.00 dB/oct") on one
                // line — it wrapped and pushed the row to double height.
                .frame(width: 78, alignment: .trailing)
                .lineLimit(1)
        }
        .help(help)
    }

    // MARK: - Results

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
            candidateList(optimizer.search(autoEq.query),
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
            candidateList(autoEq.search(autoEq.query),
                          total: autoEq.entries.count,
                          noun: "presets")
        }
    }

    /// Takes the filtered list as a parameter so the several-thousand-entry
    /// scan runs once per keystroke rather than once per read.
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
            // A plain VStack, not a ScrollView: a scroll view nested in this
            // self-sizing popover has no intrinsic height to propose and
            // collapses to a single row. The list is capped instead, and the
            // remainder surfaced as a hint.
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
                if applying == candidate.id {
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
    }

    // MARK: - Apply

    private func apply(_ candidate: CorrectionCandidate) {
        let source = activeSource
        // Everything the user asked for goes to both sources, including the
        // two personalization sliders. The published path can honour none of
        // it — that fit happened at publication time — and says so. Omitting
        // the sliders here, as this used to, replaced an explicit warning with
        // a silent difference between the two modes: bass set to +4 in one
        // mode was simply dropped in the other with nothing said.
        let options = CorrectionOptions(bassBoostGain: bassBoost, tilt: tilt,
                                        target: selectedTarget,
                                        maxCorrectionHz: requestedCeilingHz).quantized()
        applying = candidate.id
        Task {
            defer { applying = nil }
            do {
                let result = try await source.correction(for: candidate, shapedFor: limits,
                                                         options: options)
                controller.apply(result.file, named: candidate.title)
                // The controller reports what it did with the bands; this adds
                // what was asked for and what the device would not take.
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

    /// The predicted rating, framed as what it is.
    ///
    /// Three things this must not do, all of which would be easy: call it a
    /// percentage, print a precision the model's ±7-point residual cannot
    /// support, or let a small gap between two corrections read as a verdict.
    /// It is the average of a listening panel, and the same research found
    /// about a third of listeners want measurably more or less bass than the
    /// target — so for any one person it is a starting point, not a score.
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
        // The model's slope is dB per natural-log unit of frequency. Printing
        // that number as dB/octave would be wrong by a factor of ln 2, so it is
        // converted rather than relabelled: over one octave the curve rises by
        // slope × ln 2.
        .help(String(format: "Deviation from the target after this device's filters, "
                     + "over 50 Hz to 10 kHz: %.2f dB spread, %.2f dB per octave of tilt.",
                     reading.standardDeviation,
                     reading.absoluteSlope * log(2.0)))
    }

    private func pasteText() {
        // A correction arriving by any other route replaces the curve, so a
        // score computed for the previous one must not linger beneath it.
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
            try? controller.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
