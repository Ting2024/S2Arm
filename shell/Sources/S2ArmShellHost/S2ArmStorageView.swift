import ShellUI
import SwiftUI

/// Kept in the S2Arm-owned host layer rather than modifying upstream ShellUI.
struct S2ArmStorageView: View {
    let names: [String: String]
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var report: S2ArmStorage.Report?
    @State private var discoveryIssues: [String] = []
    @State private var scanning = false
    @State private var failure = false
    @State private var candidates: [S2ArmUploadCleanup.Preview] = []
    @State private var selected: S2ArmUploadCleanup.Preview?
    @State private var cleaning = false
    @State private var cleanupMessage: String?
    @State private var stoppedTransfer = false
    @State private var acceptLoss = false
    @State private var confirmation = false
    @State private var worker: Task<Void, Never>?
    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }
    private func title(_ id: String) -> String {
        switch id {
        case "trashReview": return shellText("Trash · Needs review")
        case "systemTemporary": return shellText("System temporary directory · Needs review")
        case "cache": return shellText("App cache")
        case "application": return shellText("App settings and data")
        case "documentsOther": return shellText("Other documents · Kept")
        case "other": return shellText("Other app data · Kept")
        default:
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            let gid = parts.last ?? id
            let name = names[gid] ?? (gid == "legacy" ? shellText("Legacy single-game directory") : gid)
            let kind = parts.first == "save" ? shellText("Saves") : parts.first == "upload" ? shellText("Staged upload · Unconfirmed") : shellText("Game data")
            return "\(name) · \(kind)"
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(shellText("No files are deleted automatically. Formal games and saves are always kept."))
                    Text(shellText("A legacy uploader may still be writing, or an uploaded archive may not be imported yet. A complete archive trailer or an applied marker alone does not prove it is a disposable copy."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let cleanupMessage { Section(shellText("Cleanup Result")) { Text(cleanupMessage) } }
                if cleaning { Section { ProgressView(shellText("Deleting confirmed staged uploads…")) } }
                if scanning { Section { ProgressView(shellText("Calculating app data…")) } }
                if failure { Text(shellText("Could not finish reading the data directory. Please try again later. No files were deleted.")).foregroundStyle(.red) }
                if let report {
                    Section(shellText("App Data Total")) {
                        LabeledContent(shellText("Total file size"), value: bytes(report.logicalBytes))
                        LabeledContent(shellText("Allocated space (estimated)"), value: bytes(report.allocatedBytes))
                        Text(shellText("Excludes the app bundle itself. APFS shared blocks, system purgeable space, and directory metadata affect the system's reported value; uploads or writes during scanning also change the result."))
                            .font(.footnote).foregroundStyle(.secondary)
                        if report.incomplete || report.linksSkipped > 0 {
                            Text(shellText("Some directories could not be counted or contained links: the total may be incomplete. Upload batches below are verified independently and do not rely on this summary."))
                                .foregroundStyle(.orange)
                        }
                    }
                    Section(shellText("Category Breakdown (Non-overlapping)")) {
                        ForEach(report.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title(item.id))
                                Text(shellText("\(bytes(item.logicalBytes)) · \(String(item.files)) files · Allocated \(bytes(item.allocatedBytes))"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section(shellText("Abandon Upload and Delete Staged Batches")) {
                        ForEach(discoveryIssues, id: \.self) { Text($0).foregroundStyle(.orange) }

                        Text(shellText("You do not need to keep the original game on your computer. This only deletes the explicitly selected upload batches, never unpacked games, saves, or the entire Trash. Batches may be the only uploaded copy; deleting them is not deduplication and may require uploading again."))
                            .font(.footnote)
                        Text(shellText("Legacy transfers cannot be force-stopped by this app: stop the transfer on your computer first and unplug the cable, or disconnect wireless transfer if used. Merely seeing file sizes stop growing does not prove writing has stopped."))
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(candidates) { item in
                            let isSelected = selected?.id == item.id
                            let loc = item.archived ? shellText("Trash") : shellText("Game directory")
                            Button {
                                selected = isSelected ? nil : item
                                stoppedTransfer = false; acceptLoss = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(names[item.gameID] ?? item.gameID).font(.headline)
                                        Text(shellText("\(loc) · \(String(item.files.count)) batches · \(bytes(item.bytes))"))
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(isSelected ? shellText("Selected") : shellText("Select")).font(.subheadline.weight(.semibold))
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(isSelected ? shellText("Selected") : shellText("Not selected"))
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                            .disabled(cleaning || scanning)
                        }
                        if candidates.isEmpty { Text(shellText("No staged uploads matching the explicit batch rules were found; unknown files, links, and other temporary files are kept.")) }
                        if let selected {
                            let loc = selected.archived ? shellText("Trash") : shellText("Game directory")
                            Text(shellText("Selected: \(names[selected.gameID] ?? selected.gameID) · \(loc) · \(bytes(selected.bytes))")).bold()
                            Toggle(shellText("Transfer stopped and computer or wireless connection disconnected"), isOn: $stoppedTransfer)
                            Toggle(shellText("Confirm abandoning these upload batches and accept re-uploading if needed"), isOn: $acceptLoss)
                            Button(shellText("Delete Selected Staged Uploads…"), role: .destructive) { confirmation = true }
                                .disabled(!stoppedTransfer || !acceptLoss || cleaning || scanning)
                        }
                    }
                }
            }
            .navigationTitle(shellText("Storage"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(shellText("Close")) { dismiss() }.disabled(cleaning) }
                ToolbarItem(placement: .primaryAction) { Button(shellText("Refresh")) { refresh() }.disabled(scanning || cleaning) }
            }
        }
        .interactiveDismissDisabled(cleaning)
        .confirmationDialog(shellText("Permanently delete the selected upload batches?"), isPresented: $confirmation, titleVisibility: .visible) {
            Button(shellText("Confirm Abandon and Delete"), role: .destructive) { discard() }
            Button(shellText("Cancel"), role: .cancel) {}
        } message: {
            let summary = selected.map { (names[$0.gameID] ?? $0.gameID) + " · " + ($0.archived ? shellText("Trash") : shellText("Game directory")) + " · " + bytes($0.bytes) } ?? shellText("Not selected")
            Text(shellText("\(summary). Cannot be undone; unpacked games and saves are not deleted. Cancel if the transfer has not stopped."))
        }
        .task { refresh() }
        .onDisappear { worker?.cancel(); worker = nil }
    }
    @MainActor private func refresh() {
        worker?.cancel(); scanning = true; failure = false
        selected = nil; candidates = []; stoppedTransfer = false; acceptLoss = false
        let directory = root
        worker = Task {
            let scan = Task.detached(priority: .utility) {
                let report = try S2ArmStorage.scan(root: directory, cancelled: { Task.isCancelled })
                let discovery = S2ArmUploadCleanup.discover(root: directory)
                return (report, discovery)
            }
            do {
                let result = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                guard !Task.isCancelled else { return }
                report = result.0; candidates = result.1.candidates; discoveryIssues = result.1.issues
                selected = nil
            } catch {
                guard !Task.isCancelled else { return }
                failure = true
            }
            scanning = false
        }
    }
    @MainActor private func discard() {
        guard let target = selected, stoppedTransfer, acceptLoss, !cleaning, !scanning else { return }
        cleaning = true; cleanupMessage = nil
        let directory = root
        worker = Task {
            let task = Task.detached(priority: .utility) {
                try S2ArmUploadCleanup.discard(root: directory, preview: target, transportStopped: true)
            }
            do {
                let result = try await task.value
                cleanupMessage = shellText("Deleted \(String(result.removedFiles)) upload batches (\(bytes(result.removedLogicalBytes))). Formal games and saves were not deleted.")
                if result.interrupted { cleanupMessage! += " " + shellText("Some files changed or could not be deleted, so cleanup stopped; please check again.") }

            } catch { cleanupMessage = error.localizedDescription }
            cleaning = false; selected = nil; refresh()
        }
    }

}
