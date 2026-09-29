// Owner: shelf-clipboard. Settings › Shelf (SPEC §A.10): enable, AirDrop zone, retention, open folder, clear.
//
// Hosting note: this view brings its own grouped `Form`; put it directly in the Settings detail pane.
import AppKit
import SuperNotchCore
import SwiftUI

struct ShelfSettingsSection: View {
    @Environment(ShelfModel.self) private var shelf
    @Environment(SettingsStore.self) private var settingsStore
    @State private var confirmingClear = false

    init() {}

    var body: some View {
        @Bindable var store = settingsStore
        Form {
            Section {
                Toggle("Enable shelf", isOn: $store.settings.shelfEnabled)
                Toggle("Show the AirDrop drop zone", isOn: $store.settings.showAirDropZone)
                    .disabled(!store.settings.shelfEnabled || !shelf.isAirDropAvailable)
            } header: {
                Text("Shelf")
            } footer: {
                Text(
                    "Drag files onto the notch to keep a copy here, then drag them back out into any app. While "
                        + "you drag, the notch shows two targets: Shelf and AirDrop."
                        + (shelf.isAirDropAvailable ? "" : " AirDrop is not available on this Mac.")
                )
            }

            Section {
                Picker("Remove items", selection: $store.settings.retention) {
                    ForEach(RetentionPeriod.allCases, id: \.self) { period in
                        Text(period.displayName).tag(period)
                    }
                }
            } header: {
                Text("Auto-cleanup")
            } footer: {
                Text("Pinned items are never removed. This setting also applies to the clipboard history.")
            }

            Section {
                LabeledContent("Items") {
                    Text(itemSummary)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open Shelf Folder") { shelf.openShelfFolder() }
                    Spacer()
                    Button("Remove All Items…", role: .destructive) { confirmingClear = true }
                        .disabled(shelf.items.isEmpty)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Dropped files are copied to ~/Library/Application Support/SuperNotch/Shelf. The originals are "
                    + "never moved or changed.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove all shelf items?", isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { shelf.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the stored copies, including pinned items. The original files are not affected.")
        }
    }

    private var itemSummary: String {
        let items = shelf.items
        guard !items.isEmpty else { return "Empty" }
        let bytes = items.compactMap(\.byteSize).reduce(0, +)
        let pinned = items.filter(\.pinned).count
        var text = items.count == 1 ? "1 item" : "\(items.count) items"
        if bytes > 0 { text += ", " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        if pinned > 0 { text += ", \(pinned) pinned" }
        return text
    }
}
