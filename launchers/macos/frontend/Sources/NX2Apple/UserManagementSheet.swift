import SwiftUI
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

struct UserManagementSheet: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: String?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(loc.t("s2arm.users.manage")).font(.title2.bold())
            Text(loc.t("s2arm.users.hint")).foregroundStyle(.secondary)
            List(model.userRegistry?.users ?? []) { user in
                HStack {
                    Text(user.id).monospacedDigit()
                    Text(user.name)
                    Spacer()
                    if model.selectedUserID == user.id { Image(systemName: "checkmark") }
                    Button(loc.t("s2arm.users.select")) { model.selectedUserID = user.id }
                    Button(loc.t("s2arm.users.rename")) { editingID = user.id; name = user.name }
                }
            }
            .disabled(model.usersBusy)
            HStack {
                TextField(loc.t("s2arm.users.name"), text: $name)
                    .textFieldStyle(.roundedBorder).disabled(model.usersBusy)
                Button(loc.t(editingID == nil ? "s2arm.users.create" : "s2arm.users.rename")) {
                    let id = editingID, captured = name
                    Task {
                        await model.updateUser(id: id, name: captured)
                        if model.usersError == nil { editingID = nil; name = "" }
                    }
                }
                .disabled(model.usersBusy || model.userRegistry == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editingID != nil {
                    Button(loc.t("s2arm.users.new")) { editingID = nil; name = "" }.disabled(model.usersBusy)
                }
            }
            if let error = model.usersError { Text(loc.backend(error)).foregroundStyle(.red) }
            HStack {
                Button(loc.t("s2arm.users.refresh")) { Task { await model.loadUsers() } }.disabled(model.usersBusy)
                if model.usersBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(loc.t("s2arm.users.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 600, height: 430)
        .task { await model.loadUsers() }
    }
}
