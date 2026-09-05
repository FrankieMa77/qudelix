import AppKit
import SwiftUI

struct AppsSection: View {
    @EnvironmentObject var apps: AppAssignments
    @EnvironmentObject var library: PresetLibrary
    @EnvironmentObject var stageState: StageState

    @State private var expanded = false

    static let bodyHeight: CGFloat = 168

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if let problem = unavailable {
                        Text(verbatim: problem)
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if rows.isEmpty {
                        Text("Nothing is playing that can be given a curve.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(rows) { row($0) }
                        }
                    }
                    Text("Applied on this Mac before the 5K\u{2019}s own EQ, so an "
                        + "app\u{2019}s curve stacks on top of whatever the device "
                        + "is running.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
                .padding(.top, 6)
            }
            .frame(maxHeight: Self.bodyHeight)
        } label: {
            header
        }
        .onAppear {
            #if DEBUG
            if apps.previewExpanded { expanded = true }
            #endif
        }
    }

    private var rows: [AppAssignments.AppRow] { apps.rows() }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Per-app EQ").font(.system(size: 11, weight: .medium))
            if apps.activeCount > 0 {
                Text("\(apps.activeCount) assigned")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { apps.enabled },
                                     set: { apps.setEnabled($0) }))
                .labelsHidden()
                .controlSize(.mini)
                .toggleStyle(.switch)
                .accessibilityLabel("Per-app EQ")
                .help("Give one app a curve of its own on the Mac. It is only "
                      + "audible with the engine inserted, so switching this on "
                      + "with an app assigned starts the engine.")
        }
    }

    private var unavailable: String? {
        if #unavailable(macOS 14.2) {
            return "Per-app EQ needs macOS 14.2 or newer \u{2014} that is where "
                + "process taps arrived."
        }
        guard let failure = stageState.engineFailure else { return nil }
        return failure.message
    }

    private func row(_ entry: AppAssignments.AppRow) -> some View {
        HStack(spacing: 6) {
            icon(for: entry.bundleID)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: entry.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if entry.playing {
                        Image(systemName: "waveform")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("playing now")
                    }
                }
                if entry.missingPreset {
                    Text("That preset is gone \u{2014} this app is on Default.")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Default") { assign(nil, to: entry) }
                if !library.presets.isEmpty {
                    Divider()
                    ForEach(sortedPresets) { preset in
                        Button {
                            assign(preset.id, to: entry)
                        } label: {
                            Text(verbatim: preset.name + " \u{00B7} " + preset.groupLabel)
                        }
                    }
                }
                if entry.assigned {
                    Divider()
                    Button("Forget this app", role: .destructive) {
                        apps.forget(entry.bundleID)
                    }
                }
            } label: {
                Text(verbatim: entry.preset?.name ?? "Default")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .frame(width: 116)
            .disabled(!entry.assigned && apps.isFull)
            .help("This curve runs on the Mac and has its own band count, so a "
                  + "preset saved for either of the device\u{2019}s EQ banks can be "
                  + "used here.")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(entry.assigned ? 0.2 : 0),
                    in: RoundedRectangle(cornerRadius: 5))
        .help(Text(verbatim: entry.bundleID))
    }

    private var sortedPresets: [LibraryPreset] {
        library.presets.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func assign(_ presetID: UUID?, to entry: AppAssignments.AppRow) {
        apps.assign(presetID, to: entry.bundleID, named: entry.displayName)
    }

    @ViewBuilder
    private func icon(for bundleID: String) -> some View {
        if let image = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first?.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
        }
    }
}
