import RdcCore
import SwiftUI

struct NewServerSheet: View {
    let request: NewServerRequest
    @ObservedObject var model: RdcAppModel
    @StateObject private var editor = NewServerEditorModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加服务器")
                .font(.system(size: 20, weight: .semibold))
            Text("将添加到“\(request.destination.name)”，账号密码继承全局设置。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Form {
                TextField("名称", text: Binding(
                    get: { editor.name }, set: { editor.updateName($0) }
                ))
                TextField("IP 地址或域名", text: Binding(
                    get: { editor.host }, set: { editor.updateHost($0) }
                ))
                TextField("端口", text: $editor.portText)
            }
            .formStyle(.grouped)
            .frame(height: 170)
            if let error = editor.nameError ?? editor.hostError ?? editor.portError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let saveError = editor.saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("添加") {
                    Task {
                        let saved = await editor.save { draft in
                            _ = try await model.createServer(
                                destination: request.destination,
                                expectedSnapshot: request.expectedSnapshot,
                                draft: draft
                            )
                        }
                        if saved { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!editor.canSave)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
