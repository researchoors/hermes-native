import SwiftUI

struct SkillsView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var viewModel = SkillsViewModel()
    @State private var mode: SkillBrowserMode = .directory

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(SkillBrowserMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)

                Divider().background(Theme.border)

                Group {
                    switch mode {
                    case .directory:
                        SkillDirectoryView(viewModel: viewModel)
                    case .graph:
                        SkillGraph3DView(graph: viewModel.graph) { skillID in
                            Task { await viewModel.selectSkill(id: skillID) }
                        }
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Skills")
        } detail: {
            SkillEditorView(viewModel: viewModel)
        }
        .background(Theme.background)
        .task {
            viewModel.setGatewayClient(gatewayClientWrapper.client)
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
}

private enum SkillBrowserMode: String, CaseIterable, Identifiable {
    case directory
    case graph

    var id: String { rawValue }
    var title: String { self == .directory ? "Directory" : "Graph" }
    var icon: String { self == .directory ? "folder" : "network" }
}

struct SkillDirectoryView: View {
    @Bindable var viewModel: SkillsViewModel

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.treeRoots.isEmpty {
                ProgressView("Loading skills…")
                    .foregroundStyle(Theme.secondary)
            } else if viewModel.treeRoots.isEmpty {
                ContentUnavailableView("No Skills", systemImage: "books.vertical", description: Text("Skills stored on Hermes Agent will appear here."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.treeRoots) { node in
                    SkillTreeRow(node: node, viewModel: viewModel)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface)
            }
        }
    }
}

struct SkillTreeRow: View {
    let node: SkillFileNode
    @Bindable var viewModel: SkillsViewModel

    var body: some View {
        if node.children.isEmpty || node.kind == .file {
            Button {
                if let skillID = node.skillID {
                    Task { await viewModel.selectSkill(id: skillID, filePath: node.pathForRPC) }
                }
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
            .listRowBackground(rowBackground)
        } else {
            DisclosureGroup {
                ForEach(node.children) { child in
                    SkillTreeRow(node: child, viewModel: viewModel)
                }
            } label: {
                if node.kind == .skill, let skillID = node.skillID {
                    Button {
                        Task { await viewModel.selectSkill(id: skillID) }
                    } label: {
                        rowLabel
                    }
                    .buttonStyle(.plain)
                } else {
                    rowLabel
                }
            }
            .listRowBackground(rowBackground)
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            Text(node.name)
                .lineLimit(1)
                .foregroundStyle(Theme.primary)
            if node.readOnly {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch node.kind {
        case .directory: "folder"
        case .skill: "book.closed"
        case .file: node.name == "SKILL.md" ? "doc.text" : "doc"
        }
    }

    private var iconColor: Color {
        switch node.kind {
        case .directory: Theme.warning
        case .skill: Theme.accent
        case .file: Theme.secondary
        }
    }

    private var rowBackground: some View {
        Group {
            if node.skillID == viewModel.selectedSkillID && (node.pathForRPC ?? "SKILL.md") == (viewModel.selectedFilePath ?? "SKILL.md") {
                Theme.accent.opacity(0.18)
            } else {
                Color.clear
            }
        }
    }
}

private extension SkillFileNode {
    var pathForRPC: String? {
        guard kind == .file, let path, let skillID else { return nil }
        if path == "\(skillID)/SKILL.md" { return "SKILL.md" }
        if path.hasPrefix("\(skillID)/") {
            return String(path.dropFirst(skillID.count + 1))
        }
        return path
    }
}

struct SkillEditorView: View {
    @Bindable var viewModel: SkillsViewModel
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: 0) {
            if let document = viewModel.selectedDocument {
                header(document)
                Divider().background(Theme.border)
                if showPreview {
                    ScrollView {
                        MarkdownContentView(text: viewModel.editorText, isStreaming: false)
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Theme.background)
                } else {
                    editor(document)
                }
            } else {
                ContentUnavailableView("Select a Skill", systemImage: "books.vertical", description: Text("Choose a skill from the directory or graph."))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
        }
        .background(Theme.background)
    }

    private func header(_ document: SkillDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(document.skill.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                        if document.readOnly {
                            Label("Read-only", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    Text(document.skill.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.tertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                Toggle("Preview", isOn: $showPreview)
                    .toggleStyle(.switch)
                Button {
                    Task { await viewModel.saveSelectedSkill() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(document.readOnly || !viewModel.hasUnsavedChanges || viewModel.isSaving || document.filePath != "SKILL.md")
            }

            if !document.skill.description.isEmpty {
                Text(document.skill.description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                if let category = document.skill.category {
                    skillPill(category, color: Theme.accent)
                }
                ForEach(document.skill.tags.prefix(5), id: \.self) { tag in
                    skillPill(tag, color: Theme.secondary)
                }
                if viewModel.hasUnsavedChanges {
                    skillPill("Unsaved", color: Theme.warning)
                }
            }
        }
        .padding(16)
        .background(Theme.surface)
    }

    private func editor(_ document: SkillDocument) -> some View {
        TextEditor(text: $viewModel.editorText)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Theme.primary)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .disabled(document.readOnly || document.filePath != "SKILL.md")
            .overlay(alignment: .bottomLeading) {
                if document.filePath != "SKILL.md" {
                    Text("Slice 2 supports editing SKILL.md. Linked file editing comes in slice 4.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .padding(10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
    }

    private func skillPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

#Preview {
    SkillsView()
        .environmentObject(GatewayClientWrapper())
}
