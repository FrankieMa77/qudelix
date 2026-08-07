import AppKit
import SwiftUI

/// What this app is, which build of it is running, and who it isn't.
///
/// The last of those is the reason this exists at all: the app carries the
/// device maker's name, so anyone finding it needs to be able to establish in
/// one glance that it is not the maker's own software and that nobody official
/// is answerable for it.
struct AboutView: View {
    /// nil until asked. There is no check on launch and no timer: the privacy
    /// note promises no host is contacted at startup, and quietly phoning home
    /// for a version would make that false.
    @State private var updateResult: UpdateCheck.Result?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.appName)
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: Self.versionLine)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }

            Text("An unofficial menu bar companion for the Qudelix 5K. Not "
                 + "affiliated with, endorsed by, or supported by Qudelix, Inc.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // The disclaimer is stated once, above. Repeating the bundle's
            // copyright string here said the same thing twice in two voices.
            licenceRow
            row("Source", Self.repoDisplay, url: Self.repoURL)
            updateRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The update check, and whatever it last said.
    ///
    /// A button rather than anything automatic. The answer is worth having, but
    /// not at the cost of the app reaching the network on its own — and an
    /// update people check when they think of it is the honest trade.
    private var updateRow: some View {
        HStack(spacing: 6) {
            Text("Updates")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            if checking {
                ProgressView().controlSize(.small)
            } else if let result = updateResult {
                Text(verbatim: UpdateCheck.summary(result))
                    .font(.system(size: 10))
                    .foregroundStyle(isNewer(result) ? AnyShapeStyle(Color.accentColor)
                                                     : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isNewer(result), let url = UpdateCheck.releasesURL {
                    linkButton("Get it", url: url)
                }
            }
            Button(updateResult == nil ? "Check" : "Again") {
                Task {
                    checking = true
                    defer { checking = false }
                    updateResult = await UpdateCheck.run(current: Self.rawVersion)
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 10))
            .disabled(checking)
        }
        .help("Asks the release list once, when you press it. Nothing is sent "
              + "but the request itself, and nothing is downloaded or installed.")
    }

    private func isNewer(_ result: UpdateCheck.Result) -> Bool {
        if case .available = result { return true }
        return false
    }

    /// Licence and holder on one line, with only the holder clickable — the
    /// licence name is not a destination and underlining it would invite a
    /// click that goes nowhere.
    private var licenceRow: some View {
        HStack(spacing: 0) {
            Text("Licence")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: "MIT · \(Self.copyrightYear) ")
                .font(.system(size: 10))
            linkButton(Self.siteDisplay, url: Self.siteURL)
        }
    }

    private func linkButton(_ label: String, url: URL?) -> some View {
        Group {
            if let url {
                // A menu bar app is not the frontmost app, and openURL from an
                // inactive app has bitten this project before — the same reason
                // the import panel activates first.
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(verbatim: label).font(.system(size: 10))
                }
                .buttonStyle(.link)
            } else {
                Text(verbatim: label).font(.system(size: 10))
            }
        }
    }

    private func row(_ label: String, _ value: String, url: URL? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            linkButton(value, url: url)
        }
    }

    // MARK: - Facts about this build

    /// Read from the bundle rather than written here, so the panel cannot drift
    /// from what was actually built. Running unbundled — the render harness and
    /// the tests do — there is no Info.plist, hence the fallbacks.
    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static var appName: String {
        info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Qudelix"
    }

    /// "1.3.0 (a1b2c3d)", or just the version when the revision is unknown.
    ///
    /// The revision is shown because the version alone is a poor answer to
    /// "which build is this": most builds sit somewhere between two releases,
    /// and a "+" on the revision means this binary corresponds to no commit at
    /// all because the tree was dirty when it was built.
    /// The bare version, for comparison rather than display.
    static var rawVersion: String { info("CFBundleShortVersionString") ?? "0.0.0" }

    static var versionLine: String {
        let version = info("CFBundleShortVersionString") ?? "unreleased build"
        guard let rev = info("QBSourceRevision"), rev != "unknown" else { return version }
        return "\(version) (\(rev))"
    }

    /// The link reads "GitHub" rather than the bare URL: the row is one line
    /// in a narrow panel, and the destination is unsurprising enough that
    /// spelling it out costs more width than it buys anyone.
    static let repoDisplay = "GitHub"
    static let repoURL = URL(string: "https://github.com/FrankieMa77/qudelix")

    static let copyrightYear = "© 2026"
    static let siteDisplay = "wpmagic.pro"
    static let siteURL = URL(string: "https://wpmagic.pro")
}
