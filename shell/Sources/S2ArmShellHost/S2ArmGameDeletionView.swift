import ShellUI
import SwiftUI

struct S2ArmGameDeletionView: View {
    let gameID: String
    let title: String
    let root: URL
    let initialDeleteSaves: Bool
    let onDeleted: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSaves = false
    @State private var stopped = false
    @State private var accepted = false
    @State private var preview: S2ArmGameDeletion.Preview?
    @State private var scanning = false
    @State private var deleting = false
    @State private var finished = false
    @State private var message: String?
    @State private var confirm = false
    @State private var worker: Task<Void, Never>?
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    var body: some View {
        NavigationStack {
            List {
                Section(shellText("Selected Game")) {
                    Text(title).font(.headline)
                    Text(gameID).font(.caption).foregroundStyle(.secondary)
                }
                Section(shellText("Deletion Scope")) {
                    Text(shellText("Deletes this game's data pack, unfinished uploads, game settings, and other per-game files in this app, and removes it from the library. Does not uninstall the app or delete other games."))
                    Toggle(shellText("Also delete saves and runtime data"), isOn: $deleteSaves)
                        .disabled(scanning || deleting || finished)
                        .onChange(of: deleteSaves) { _, _ in refresh() }
                    Text(deleteSaves ? shellText("Permanently deletes saves, caches, save backups, and recovery records inside this game's S2A folder. Cannot be undone.") : shellText("Keeps this game's entire S2A runtime data folder (including saves, save backups, and caches) so you can continue using them after reinstalling the game."))
                        .foregroundStyle(deleteSaves ? Color.red : Color.secondary)
                    Text(shellText("Does not touch old copies in Trash, external folders, or legacy shared directories; built-in game modules cannot be uninstalled separately."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if scanning { ProgressView(shellText("Verifying deletion scope…")) }
                if let preview {
                    Section(shellText("Confirmation")) {
                        LabeledContent(shellText("Files to delete"), value: bytes(preview.bytes))
                        LabeledContent(shellText("Preserved runtime data"), value: bytes(preview.preservedBytes))
                        Text(shellText("File size does not equal actual space reclaimed by the system. Links or unreadable files block deletion, and changes after confirmation stop the process; completed deletions cannot be undone."))
                            .font(.footnote)
                    }
                }
                if let message { Section(shellText("Result")) { Text(message) } }
                if !finished {
                    Section {
                        Text(shellText("Please stop the computer transfer first and unplug the cable or disconnect wireless transfer. The app cannot force-stop legacy uploaders."))
                        Toggle(shellText("Transfer stopped and disconnected"), isOn: $stopped).disabled(deleting)
                        Toggle(deleteSaves ? shellText("Confirm permanent deletion of game and saves") : shellText("Confirm deleting game and keeping saves"), isOn: $accepted).disabled(deleting)
                        Button(deleteSaves ? shellText("Delete Game and Saves…") : shellText("Delete Game, Keep Saves…"), role: .destructive) { confirm = true }
                            .disabled(preview == nil || scanning || deleting || !stopped || !accepted)
                    }
                }
                if deleting { ProgressView(shellText("Deleting confirmed game data…")) }
            }
            .navigationTitle(shellText("Delete Game"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(finished ? shellText("Done") : shellText("Cancel")) { dismiss() }.disabled(deleting) }
                ToolbarItem(placement: .primaryAction) { Button(shellText("Check again")) { refresh() }.disabled(scanning || deleting || finished) }
            }
        }
        .interactiveDismissDisabled(deleting)
        .confirmationDialog(shellText("Delete “\(title)”?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(deleteSaves ? shellText("Permanently Delete Game and Saves") : shellText("Delete Game and Keep Saves"), role: .destructive) { remove() }
            Button(shellText("Cancel"), role: .cancel) {}
        } message: {
            Text(deleteSaves ? shellText("Saves will also be permanently deleted and cannot be undone.") : shellText("Game data and staged uploads will be deleted; S2A saves and runtime data will be kept."))
        }
        .task { deleteSaves = initialDeleteSaves; refresh() }
        .onDisappear { if !deleting { worker?.cancel() } }
    }
    @MainActor private func refresh() {
        worker?.cancel(); preview = nil; accepted = false; stopped = false; scanning = true; message = nil
        let root = root, id = gameID, saves = deleteSaves
        worker = Task {
            let scan = Task.detached(priority: .utility) { try S2ArmGameDeletion.preview(root: root, gameID: id, deleteSaves: saves) }
            do {
                let value = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                guard !Task.isCancelled else { return }
                preview = value
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            scanning = false
        }
    }
    @MainActor private func remove() {
        guard let preview, stopped, accepted, !scanning, !deleting else { return }
        deleting = true
        let root = root
        worker = Task {
            let task = Task.detached(priority: .utility) {
                try S2ArmGameDeletion.delete(root: root, preview: preview, transportStopped: true)
            }
            do {
                let result = try await task.value
                message = shellText("Deleted \(String(result.removedFiles)) files (\(bytes(result.removedBytes))).")
                if result.complete {
                    finished = true; onDeleted(gameID)
                    message! += " " + (preview.deleteSaves ? shellText("The game and its S2A save data have been deleted.") : shellText("Saves and S2A runtime data have been kept."))
                } else { message! += " " + shellText("Content changed or some items failed to delete, so deletion stopped; the game entry remains, please check again.") }
            } catch { message = error.localizedDescription }
            self.preview = nil; deleting = false; accepted = false; stopped = false
        }
    }
}
