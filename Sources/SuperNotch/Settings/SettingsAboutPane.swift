// Owner: notch-shell (SPEC §A.10 About).
//
// Version, links (GitHub, releases for updates, issues) and the third-party notices.
import AppKit
import SuperNotchCore
import SwiftUI

enum SettingsLinks {
    static let repository = URL(string: "https://github.com/snakez3101/supernotch")
    static let releases = URL(string: "https://github.com/snakez3101/supernotch/releases/latest")
    static let issues = URL(string: "https://github.com/snakez3101/supernotch/issues")
    static let notice = URL(string: "https://github.com/snakez3101/supernotch/blob/main/NOTICE")
}

struct SettingsAboutPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    @State private var noticeText: String?
    @State private var showsNotices = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SuperNotch")
                            .font(.title2.weight(.semibold))
                        Text("Version \(appModel.version) (\(appModel.build))")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Claude Code, Spotify, a file shelf and your clipboard, right in the notch.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Updates") {
                    Button("Check for Updates") {
                        open(SettingsLinks.releases)
                    }
                }
                LabeledContent("Source code") {
                    Button("Open on GitHub") {
                        open(SettingsLinks.repository)
                    }
                }
                LabeledContent("Feedback") {
                    Button("Report a Problem") {
                        open(SettingsLinks.issues)
                    }
                }
            } footer: {
                Text("Updates are published as GitHub releases. Install them with the one-line install script "
                    + "or by replacing the app in /Applications.")
            }

            Section {
                DisclosureGroup("Licences and third-party notices", isExpanded: $showsNotices) {
                    if let noticeText {
                        ScrollView {
                            Text(noticeText)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                    } else {
                        Text(Self.fallbackNotice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("View NOTICE on GitHub") {
                        open(SettingsLinks.notice)
                    }
                    .buttonStyle(.link)
                }
            } footer: {
                Text("SuperNotch is not affiliated with Apple, Spotify or Anthropic.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if noticeText == nil { noticeText = Self.loadBundledNotice() }
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        openURL(url)
    }

    private static let fallbackNotice =
        "SuperNotch is licensed under the Apache License 2.0. It contains code adapted from DynamicNotchKit "
        + "(MIT, Kai Azim), NotchDrop (MIT, Lakr Aream) and Claude Island (Apache-2.0). The full notices are "
        + "in the NOTICE file."

    /// NOTICE shipped in the app bundle, if the packaging script copied it.
    private static func loadBundledNotice() -> String? {
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
