import SwiftUI

struct SkillEditorSheet: View {
    let content: SkillContent
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var isSaving = false

    init(content: SkillContent, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.content = content
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: content.content)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if content.readOnly {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(Theme.warning)
                        Text("Read-only skill")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                    }
                    .padding(10)
                    .background(Theme.warning.opacity(0.08))
                }

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Theme.background)
                    .scrollContentBackground(.hidden)
                    .disabled(content.readOnly || isSaving)
            }
            .background(Theme.surface)
            .navigationTitle(content.skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else if !content.readOnly {
                        Button("Save") {
                            isSaving = true
                            onSave(text)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
