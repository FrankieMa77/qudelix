import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Import EQ presets from a file or from the AutoEq online database — the same
/// source the official Qudelix app offers.
struct ImportView: View {
    @EnvironmentObject var controller: QudelixController
    @StateObject private var autoEq = AutoEqIndex()
    @State private var applying: String?

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

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search AutoEq — e.g. HD 650", text: $autoEq.query)
                    .textFieldStyle(.plain)
                    .onSubmit { autoEq.loadIfNeeded() }
                if case .loading = autoEq.state {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .onAppear {
                #if DEBUG
                if let seed = controller.previewAutoEq {
                    autoEq.seedForPreview(seed.entries, query: seed.query)
                    return
                }
                #endif
                autoEq.loadIfNeeded()
            }

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
                resultsSection(autoEq.results)
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

    /// Takes the filtered list as a parameter so the 6,000-entry scan runs once
    /// per keystroke rather than once per read of `autoEq.results`.
    @ViewBuilder
    private func resultsSection(_ results: [AutoEqEntry]) -> some View {
        if autoEq.query.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("\(autoEq.entries.count) headphones available. Start typing to search.")
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
                ForEach(results.prefix(AutoEqIndex.displayLimit)) { entry in
                    resultRow(entry)
                    Divider()
                }
            }
            if results.count > AutoEqIndex.displayLimit {
                Text("+\(results.count - AutoEqIndex.displayLimit) more — keep typing to narrow it down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func resultRow(_ entry: AutoEqEntry) -> some View {
        Button {
            apply(entry)
        } label: {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Text(entry.source)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if applying == entry.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private func apply(_ entry: AutoEqEntry) {
        applying = entry.id
        Task {
            defer { applying = nil }
            do {
                let file = try await AutoEqIndex.fetchPreset(entry)
                controller.apply(file)
                controller.lastImportSummary = "\(entry.title): "
                    + (controller.lastImportSummary ?? "applied")
            } catch {
                controller.lastImportSummary = "Download failed: \(error.localizedDescription)"
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
