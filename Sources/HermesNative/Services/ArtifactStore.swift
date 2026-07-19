import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ArtifactStore")

/// Store for living artifacts: named models the agent maintains across
/// turns, sessions, and devices. Three layers:
///
/// - In-memory published dictionary (views observe).
/// - Disk (Application Support JSON) — local/offline source of truth.
/// - Gateway sync through the generic config KV (same mechanism and
///   merge discipline as SessionMetaSyncService): last-writer-wins PER
///   ARTIFACT by updatedAt, so a Mac updating the BKK map and an iPhone
///   updating a comparison table both survive.
@MainActor
final class ArtifactStore: ObservableObject {

    static let shared = ArtifactStore()
    static let configKey = "hermesnative.artifacts"

    @Published private(set) var artifacts: [String: LivingArtifact] = [:]

    private weak var client: GatewayClient?
    private var syncAvailable: Bool?
    private var pushTask: Task<Void, Never>?
    private let pushDebounce: TimeInterval = 2
    private let fileURL: URL

    /// Artifacts sorted by recency for pickers.
    var sortedArtifacts: [LivingArtifact] {
        artifacts.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/tmp")
        let folder = dir.appendingPathComponent("hermes-native", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("artifacts.json")
        loadFromDisk()
    }

    // MARK: - Upsert (fence blocks with an id land here)

    /// Merge an incoming fence body into the named artifact. Returns the
    /// stored artifact after merge.
    @discardableResult
    func upsert(id: String, kind: String, title: String?, content: String) -> LivingArtifact {
        let merged: String
        if let existing = artifacts[id], existing.kind == kind {
            merged = ArtifactMerge.merge(kind: kind, existing: existing.content, incoming: content)
        } else {
            merged = content
        }
        var artifact = LivingArtifact(
            id: id,
            kind: kind,
            title: title ?? artifacts[id]?.title ?? "",
            content: merged,
            updatedAt: Date(),
            updatedBy: SessionMetaSyncService.deviceID
        )
        // Preserve a non-empty title over an incoming nil/empty one.
        if artifact.title.isEmpty, let existingTitle = artifacts[id]?.title {
            artifact.title = existingTitle
        }
        artifacts[id] = artifact
        persistToDisk()
        schedulePush()
        return artifact
    }

    func remove(id: String) {
        guard artifacts.removeValue(forKey: id) != nil else { return }
        persistToDisk()
        schedulePush()
    }

    // MARK: - Disk

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: LivingArtifact].self, from: data) else {
            return
        }
        artifacts = stored
    }

    private func persistToDisk() {
        let snapshot = artifacts
        let url = fileURL
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("artifact persist failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Gateway sync

    func setClient(_ client: GatewayClient) {
        guard self.client !== client else { return }
        self.client = client
        syncAvailable = nil
        Task { await pull() }
    }

    /// Merge the remote document: last-writer-wins per artifact by updatedAt.
    func pull() async {
        guard let client, syncAvailable != false else { return }
        do {
            guard let result = try await client.getConfig(key: Self.configKey),
                  let json = result["value"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let remote = try? JSONDecoder().decode([String: LivingArtifact].self, from: data)
            else {
                syncAvailable = syncAvailable ?? true
                return
            }
            syncAvailable = true
            var changed = false
            for (id, remoteArtifact) in remote {
                if let local = artifacts[id], local.updatedAt >= remoteArtifact.updatedAt { continue }
                artifacts[id] = remoteArtifact
                changed = true
            }
            if changed { persistToDisk() }
        } catch {
            // Old gateway without config KV: disable quietly, stay local.
            syncAvailable = false
            log.info("artifact sync unavailable: \(error.localizedDescription)")
        }
    }

    private func schedulePush() {
        guard syncAvailable != false else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.pushDebounce ?? 2))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    private func push() async {
        guard let client, syncAvailable != false else { return }
        do {
            // Pull-merge first so a stale device never clobbers newer remote
            // artifacts wholesale (the KV write is whole-document).
            await pull()
            let data = try JSONEncoder().encode(artifacts)
            guard let json = String(data: data, encoding: .utf8) else { return }
            try await client.setConfig(key: Self.configKey, value: json, sessionID: nil)
        } catch {
            log.info("artifact push failed: \(error.localizedDescription)")
        }
    }
}
