import Foundation
import SwiftUI

@MainActor
@Observable
final class SkillsViewModel {
    var skills: [SkillSummary] = []
    var treeRoots: [SkillFileNode] = []
    var graph: SkillGraph = .empty
    var selectedSkillID: String?
    var selectedFilePath: String?
    var selectedDocument: SkillDocument?
    var editorText = ""
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private var gatewayClient: GatewayClient?

    var hasUnsavedChanges: Bool {
        selectedDocument?.content != editorText
    }

    var selectedSkill: SkillSummary? {
        guard let selectedSkillID else { return nil }
        return skills.first { $0.id == selectedSkillID || $0.name == selectedSkillID }
    }

    func setGatewayClient(_ client: GatewayClient?) {
        gatewayClient = client
    }

    func refresh() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let skillsTask = client.listSkills()
            async let treeTask = client.skillTree()
            async let graphTask = client.skillGraph()
            skills = try await skillsTask
            treeRoots = try await treeTask
            graph = try await graphTask
            if selectedSkillID == nil, let first = skills.first {
                await selectSkill(id: first.id)
            }
        } catch {
            errorMessage = error.localizedDescription
            NSLog("[SkillsViewModel] Refresh failed: \(error)")
        }
        isLoading = false
    }

    func selectSkill(id: String, filePath: String? = nil) async {
        guard let client = gatewayClient else { return }
        selectedSkillID = id
        selectedFilePath = filePath ?? "SKILL.md"
        errorMessage = nil
        do {
            let document = try await client.getSkill(skillID: id, filePath: filePath)
            selectedDocument = document
            editorText = document.content
            selectedSkillID = document.skill.id
            selectedFilePath = document.filePath
        } catch {
            errorMessage = error.localizedDescription
            NSLog("[SkillsViewModel] Select failed: \(error)")
        }
    }

    func saveSelectedSkill() async {
        guard let client = gatewayClient,
              let document = selectedDocument else { return }
        guard !document.readOnly else {
            errorMessage = "This skill is read-only."
            return
        }
        isSaving = true
        errorMessage = nil
        do {
            let updated = try await client.updateSkill(skillID: document.skill.id, content: editorText)
            selectedDocument = SkillDocument(
                skill: updated,
                filePath: "SKILL.md",
                content: editorText,
                readOnly: updated.readOnly
            )
            selectedSkillID = updated.id
            selectedFilePath = "SKILL.md"
            await refreshKeepingSelection(skillID: updated.id)
        } catch {
            errorMessage = error.localizedDescription
            NSLog("[SkillsViewModel] Save failed: \(error)")
        }
        isSaving = false
    }

    private func refreshKeepingSelection(skillID: String) async {
        guard let client = gatewayClient else { return }
        do {
            async let skillsTask = client.listSkills()
            async let treeTask = client.skillTree()
            async let graphTask = client.skillGraph()
            skills = try await skillsTask
            treeRoots = try await treeTask
            graph = try await graphTask
            selectedSkillID = skillID
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
