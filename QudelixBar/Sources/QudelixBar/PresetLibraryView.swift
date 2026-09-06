import AppKit
import SwiftUI

struct PresetLibraryView: View {
    @EnvironmentObject var controller: QudelixController
    @EnvironmentObject var library: PresetLibrary
    @EnvironmentObject var profileRules: ProfileRules
    @EnvironmentObject var suggestions: HeadphoneSuggestions

    @State private var saving = false
    @State private var draftName = ""
    @State private var draftBound = false
    @State private var renaming: UUID?
    @State private var renameDraft = ""
    @State private var showOthers = false
    @State private var deleting: LibraryPreset?
    @FocusState private var nameFocused: Bool
    @AppStorage(PresetSectionStorage.libraryOpen) private var expanded = true

    private var outputUID: String? { profileRules.currentOutputUID }
    private var outputName: String { profileRules.currentOutputName ?? "" }
    private var mine: [LibraryPreset] { library.visible(for: outputUID) }
    private var others: [LibraryPreset] { library.otherOutputs(for: outputUID) }

    static let saveButtonLabel = "Save to library\u{2026}"
    static let applyLinkLabel = "Apply"
    static let deleteMessage = "This preset is only on this Mac. It can\u{2019}t be "
        + "recovered."

    static func deleteTitle(_ name: String) -> String {
        "Delete \u{201C}" + name + "\u{201D}?"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                headphoneRow
                suggestionRow

                Text("Used to find measurements and corrections for the pair you "
                    + "actually wear.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if saving { saveRow }

                if controller.activePreset == nil {
                    Text("Your current EQ is a custom setting that isn't saved to a "
                        + "slot — applying a preset will replace it.")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = library.lastMessage { messageRow(message) }

                if mine.isEmpty {
                    Text("Nothing saved on this Mac yet.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mine) { row($0, dimmed: false) }
                }

                if !others.isEmpty {
                    DisclosureGroup(isExpanded: $showOthers) {
                        VStack(spacing: 2) {
                            ForEach(others) { row($0, dimmed: true) }
                        }
                        .padding(.top, 3)
                    } label: {
                        Text("Other outputs (\(others.count))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 2)
            .padding(.top, 6)
        } label: {
            header
        }
        .confirmationDialog(Text(verbatim: Self.deleteTitle(deleting?.name ?? "")),
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible,
                            presenting: deleting) { preset in
            Button("Delete", role: .destructive) {
                library.delete(preset)
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text(verbatim: Self.deleteMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Library").font(.system(size: 11, weight: .medium))
            Spacer()
            Button {
                library.clearMessage()
                draftName = controller.currentSourceName ?? ""
                draftBound = outputUID != nil
                saving = true
                expanded = true
                nameFocused = true
            } label: {
                Text(verbatim: Self.saveButtonLabel).font(.system(size: 10))
            }
            .controlSize(.small)
            .disabled(!controller.canWriteNow || saving)
            .help(controller.canWriteNow
                  ? "Keep the curve the 5K is running now as a preset on this Mac"
                  : "Connect the 5K first — there is no live curve to keep.")
            Button {
                addFromFile()
            } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 9))
                    .accessibilityLabel("Add an EQ file to the library")
            }
            .controlSize(.small)
            .disabled(library.currentGroup == nil)
            .help("Add a parametric EQ file to the library without applying it")
        }
    }

    private func messageRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: message)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { library.clearMessage() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Dismiss this message")
            }
            .buttonStyle(.plain)
            .help("Dismiss this message")
        }
    }

    private var headphoneRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "headphones")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            TextField("", text: Binding(get: { library.headphoneName },
                                        set: { library.setHeadphoneName($0) }),
                      prompt: Text("Headphones"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 10))
                .help("The headphones plugged into the 5K — the output device can't "
                      + "say what is on the end of it.")
        }
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if suggestions.banner == nil, let offered = suggestions.match {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(verbatim: HeadphoneSuggestions.measuredBy(offered.entry.source))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if suggestions.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(Self.applyLinkLabel) {
                        suggestions.accept(offered.entry)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 9))
                    .disabled(!controller.canEditEqNow)
                }
                Spacer(minLength: 0)
            }
            .help("AutoEq has a measured correction for these headphones \u{2014} it is "
                  + "fitted to this device before anything is written.")
        }
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("", text: $draftName, prompt: Text("Preset name"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .controlSize(.small)
                    .focused($nameFocused)
                    .onSubmit { commitSave() }
                Picker("", selection: $draftBound) {
                    Text("Every output").tag(false)
                    Text(verbatim: outputName.isEmpty ? "This output" : outputName).tag(true)
                }
                .labelsHidden()
                .controlSize(.small)
                .font(.system(size: 10))
                .frame(width: 118)
                .disabled(outputUID == nil)
                Button("Save") { commitSave() }
                    .controlSize(.mini)
                    .font(.system(size: 10))
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { saving = false }
                    .controlSize(.mini)
                    .font(.system(size: 10))
            }
            if outputUID == nil {
                Text("No default output is available, so this can only be saved for "
                    + "every output.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ preset: LibraryPreset, dimmed: Bool) -> some View {
        HStack(spacing: 6) {
            if renaming == preset.id {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .controlSize(.small)
                    .onSubmit { commitRename(preset) }
                Button("Save") { commitRename(preset) }
                    .controlSize(.mini)
                    .font(.system(size: 10))
                Button("Cancel") { renaming = nil }
                    .controlSize(.mini)
                    .font(.system(size: 10))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: preset.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: preset.scopeLabel + " · " + preset.groupLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Button("Apply") { library.apply(preset) }
                    .controlSize(.mini)
                    .font(.system(size: 10))
                    .disabled(!controller.canEditEqNow)
                    .accessibilityLabel(Text(verbatim: "Apply " + preset.name))
                    .help(controller.canEditEqNow
                          ? Text(verbatim: "Write " + preset.name + " to the 5K")
                          : Text("The 5K isn\u{2019}t taking EQ writes right now."))
                Menu {
                    Button("Rename…") {
                        renameDraft = preset.name
                        renaming = preset.id
                    }
                    Button("Export…") { exportPreset(preset) }
                    Divider()
                    scopeButtons(preset)
                    Divider()
                    Button("Delete", role: .destructive) { deleting = preset }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 10))
                        .accessibilityLabel(Text(verbatim: "More actions for "
                                                 + preset.name))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(dimmed ? 0 : 0.2),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func scopeButtons(_ preset: LibraryPreset) -> some View {
        if preset.scope != .global {
            Button("Use with every output") { library.setScope(preset, to: .global) }
        }
        if let uid = outputUID, preset.scope.outputUID != uid {
            Button {
                library.setScope(preset, to: .output(uid: uid, name: outputName))
            } label: {
                Text(verbatim: "Use only with " + (outputName.isEmpty
                                                   ? "this output" : outputName))
            }
        }
    }

    private func commitSave() {
        let scope: LibraryScope = draftBound && outputUID != nil
            ? .output(uid: outputUID ?? "", name: outputName)
            : .global
        library.saveCurrent(name: draftName, scope: scope)
        saving = false
        draftName = ""
    }

    private func commitRename(_ preset: LibraryPreset) {
        library.rename(preset, to: renameDraft)
        renaming = nil
    }

    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a parametric EQ file to keep in the library"
        AppDelegate.runFilePanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            let scope: LibraryScope = outputUID.map { .output(uid: $0, name: outputName) }
                ?? .global
            library.importFile(at: url, scope: scope)
        }
    }

    private func exportPreset(_ preset: LibraryPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue =
            preset.name.replacingOccurrences(of: "/", with: "-") + ".txt"
        panel.message = "Save this preset as a parametric EQ file"
        AppDelegate.runFilePanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            try? library.exportText(preset).write(to: url, atomically: true,
                                                  encoding: .utf8)
        }
    }
}
