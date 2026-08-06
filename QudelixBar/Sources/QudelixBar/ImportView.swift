import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Import EQ presets from a file, from AutoEq's published presets, or by asking
/// AutoEq's optimizer for a correction fitted to this device's own limits.
struct ImportView: View {
    @EnvironmentObject var controller: QudelixController

    /// The published-preset path (also the search box's text holder, so the
    /// DEBUG preview seeding keeps working unchanged).
    @StateObject private var autoEq = AutoEqIndex()
    /// The optimizer path.
    @StateObject private var optimizer = AutoEqService()

    @State private var mode: Mode = .optimized
    @State private var bassBoost: Double = 0
    @State private var tilt: Double = 0
    @State private var applying: String?

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
            slider("Bass", value: $bassBoost, in: -6...6,
                   display: String(format: "%+.1f dB", bassBoost),
                   help: "Low-shelf lift on top of the target. 0 dB is the target as published.")
            slider("Tilt", value: $tilt, in: -1...1,
                   display: String(format: "%+.2f", tilt) + " dB/oct",
                   help: "Overall slope. Negative is darker, positive brighter. 0 is the target as published.")

            HStack(spacing: 6) {
                Text("Fitted to the \(controller.bandCount)-band mode — nothing is clamped on the way to the device.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                if bassBoost != 0 || tilt != 0 {
                    Button("Reset") { bassBoost = 0; tilt = 0 }
                        .buttonStyle(.link).font(.system(size: 9))
                }
            }
        }
    }

    private func slider(_ label: String, value: Binding<Double>,
                        in range: ClosedRange<Double>, display: String,
                        help: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Slider(value: value, in: range)
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
            Text("Loading headphone catalogue…")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            HStack {
                Text("Couldn't load catalogue: \(msg)")
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
            Text("Loading headphone database…")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            HStack {
                Text("Couldn't load database: \(msg)")
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
        let options = mode == .optimized
            ? CorrectionOptions(bassBoostGain: bassBoost, tilt: tilt)
            : CorrectionOptions()
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
            } catch {
                controller.lastImportSummary = AutoEqService.describe(error)
            }
        }
    }

    /// A menu bar app is normally NOT the active application while its
    /// popover is open — clicking a status-item popover doesn't activate the
    /// app. A modal panel presented by an inactive app comes up without
    /// focus and its file list ignores the first round of clicks; dismissing
    /// it activates the app, which is why the second attempt always worked.
    /// Activate first, so the FIRST panel is usable.
    private func activateForPanel() {
        NSApp.activate()
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a parametric EQ file (AutoEq / Equalizer APO format)"
        activateForPanel()
        if panel.runModal() == .OK, let url = panel.url {
            controller.importFile(at: url)
        }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "QudelixEQ.txt"
        panel.message = "Save the current EQ"
        activateForPanel()
        if panel.runModal() == .OK, let url = panel.url {
            try? controller.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
