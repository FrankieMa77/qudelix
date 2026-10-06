import AppKit
import SwiftUI

struct AboutView: View {
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

            licenceRow
            row("Source", Self.repoDisplay, url: Self.repoURL)
            updateRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static var appName: String {
        info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Qudelix"
    }

    static var rawVersion: String { info("CFBundleShortVersionString") ?? "0.0.0" }

    static var versionLine: String {
        let version = info("CFBundleShortVersionString") ?? "unreleased build"
        guard let rev = info("QBSourceRevision"), rev != "unknown" else { return version }
        return "\(version) (\(rev))"
    }

    static let repoDisplay = "GitHub"
    static let repoURL = URL(string: "https://github.com/FrankieMa77/qudelix")

    static let copyrightYear = "© 2026"
    static let siteDisplay = "wpmagic.pro"
    static let siteURL = URL(string: "https://wpmagic.pro")
}
