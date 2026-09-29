// Owner: notch-shell (SPEC §A.10, §D.10).
//
// Root of the Settings window (hosted by AppDelegate in a titled NSWindow with all models injected).
// A sidebar with one pane per section. Stream sections bring their own grouped `Form` and are hosted directly
// as the pane content (never nested in another Form or ScrollView); the shell's own panes use the same
// `Form { }.formStyle(.grouped)` style.
import SuperNotchCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case notch
    case shortcuts
    case claude
    case music
    case shelf
    case clipboard
    case about

    var id: SettingsPane { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .notch: return "Notch"
        case .shortcuts: return "Shortcuts"
        case .claude: return "Claude"
        case .music: return "Music"
        case .shelf: return "Shelf"
        case .clipboard: return "Clipboard"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "rectangle.topthird.inset.filled"
        case .shortcuts: return "command"
        case .claude: return "sparkles"
        case .music: return "music.note"
        case .shelf: return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsPane? = .general

    init() {}

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            let pane = selection ?? .general
            SettingsPaneContent(pane: pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(pane.title)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// The content of one pane. Stream sections are hosted as-is (they bring their own Form).
private struct SettingsPaneContent: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general:
            SettingsGeneralPane()
        case .notch:
            SettingsNotchPane()
        case .shortcuts:
            SettingsShortcutsPane()
        case .claude:
            ClaudeSettingsSection()
        case .music:
            MediaSettingsSection()
        case .shelf:
            ShelfSettingsSection()
        case .clipboard:
            ClipboardSettingsSection()
        case .about:
            SettingsAboutPane()
        }
    }
}
