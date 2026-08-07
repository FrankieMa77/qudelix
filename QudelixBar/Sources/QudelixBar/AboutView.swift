import AppKit
import SwiftUI

/// What this app is, which build of it is running, and who it isn't.
///
/// The last of those is the reason this exists at all: the app carries the
/// device maker's name, so anyone finding it needs to be able to establish in
/// one glance that it is not the maker's own software and that nobody official
/// is answerable for it.
struct AboutView: View {
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
            row("Licence", "MIT · \(Self.copyrightHolder)")
            row("Source", Self.repoDisplay, url: Self.repoURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, url: URL? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            if let url {
                // A menu bar app is not the frontmost app, and openURL from an
                // inactive app has bitten this project before — the same reason
                // the import panel activates first.
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(verbatim: value).font(.system(size: 10))
                }
                .buttonStyle(.link)
            } else {
                Text(verbatim: value)
                    .font(.system(size: 10))
            }
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
    static var versionLine: String {
        let version = info("CFBundleShortVersionString") ?? "unreleased build"
        guard let rev = info("QBSourceRevision"), rev != "unknown" else { return version }
        return "\(version) (\(rev))"
    }

    static let repoDisplay = "github.com/FrankieMa77/qudelix"
    static let repoURL = URL(string: "https://github.com/FrankieMa77/qudelix")

    /// Matches the holder named in the LICENSE file at the repository root.
    static let copyrightHolder = "© 2026 FrankieMa77"
}
