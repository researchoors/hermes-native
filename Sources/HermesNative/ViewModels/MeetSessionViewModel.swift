import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "MeetSession")

// MARK: - Types

struct MeetTranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let speaker: String
    let text: String
    let timestamp: String
    let isBot: Bool

    static func == (lhs: MeetTranscriptEntry, rhs: MeetTranscriptEntry) -> Bool {
        lhs.id == rhs.id
    }
}

struct MeetDiagram: Identifiable, Equatable {
    let id = UUID()
    let mermaid: String
    let caption: String

    static func == (lhs: MeetDiagram, rhs: MeetDiagram) -> Bool {
        lhs.id == rhs.id
    }
}

struct MeetBotStatus: Equatable {
    let botID: String
    let status: String
    let pipelineState: String
    let responseMode: String
    let participants: [String]

    var displayStatus: String {
        switch status {
        case "joining": return "Joining..."
        case "in_waiting_room": return "In Waiting Room"
        case "in_meeting", "in_call_recording", "in_call_not_recording": return "In Call"
        case "leaving", "leaving_call": return "Leaving..."
        case "ended", "call_ended", "done": return "Call Ended"
        case "fatal": return "Error"
        default: return status
        }
    }

    var isActive: Bool {
        ["in_meeting", "in_call_recording", "in_call_not_recording"].contains(status)
    }
}

enum MeetConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// MARK: - ViewModel

@MainActor
final class MeetSessionViewModel: ObservableObject {
    @Published var connectionState: MeetConnectionState = .disconnected
    @Published var meetURL: String = ""
    @Published var pipelineURL: String = "localhost:9120"
    @Published var transcript: [MeetTranscriptEntry] = []
    @Published var diagrams: [MeetDiagram] = []
    @Published var botStatus: MeetBotStatus?
    @Published var systemMessages: [String] = []
    @Published var isJoined = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private let session = URLSession(configuration: .default)
    private var pipelineAuthToken: String = ""

    func setAuthToken(_ token: String) {
        pipelineAuthToken = token
    }

    // MARK: - Connection

    func connect() {
        guard !pipelineURL.isEmpty else { return }
        disconnect()

        connectionState = .connecting

        let wsURL: URL
        if pipelineURL.contains("://") {
            wsURL = URL(string: pipelineURL
                .replacingOccurrences(of: "http://", with: "ws://")
                .replacingOccurrences(of: "https://", with: "wss://")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/ws/meet-session")!
        } else {
            wsURL = URL(string: "ws://\(pipelineURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/ws/meet-session")!
        }

        log.info("Connecting to meet-session WS: \(wsURL.absoluteString)")

        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 10
        // If we have an auth token, pass it as Bearer
        if !pipelineAuthToken.isEmpty {
            request.setValue("Bearer \(pipelineAuthToken)", forHTTPHeaderField: "Authorization")
        }

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        startPingTimer()
        receiveNextMessage()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionState = .disconnected
        isJoined = false
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendPing()
            }
        }
    }

    private func sendPing() {
        webSocketTask?.send(.string("ping")) { _ in }
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveNextMessage()
                case .failure(let error):
                    log.error("WS receive error: \(error.localizedDescription)")
                    if self.connectionState == .connected {
                        self.connectionState = .error("Connection lost: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "snapshot":
            connectionState = .connected
            handleSnapshot(json)

        case "transcript":
            let speaker = json["speaker"] as? String ?? "Unknown"
            let text = json["text"] as? String ?? ""
            let timestamp = json["timestamp"] as? String ?? ""
            let isBot = json["is_bot"] as? Bool ?? false
            let entry = MeetTranscriptEntry(
                speaker: speaker, text: text,
                timestamp: timestamp, isBot: isBot
            )
            transcript.append(entry)

        case "diagram":
            let mermaid = json["mermaid"] as? String ?? ""
            let caption = json["caption"] as? String ?? ""
            if !mermaid.isEmpty {
                diagrams.append(MeetDiagram(mermaid: mermaid, caption: caption))
            }

        case "status":
            let botID = json["bot_id"] as? String ?? ""
            let status = json["status"] as? String ?? ""
            let pipelineState = json["pipeline_state"] as? String ?? ""
            let responseMode = json["response_mode"] as? String ?? ""
            let participants = json["participants"] as? [String] ?? []
            botStatus = MeetBotStatus(
                botID: botID, status: status,
                pipelineState: pipelineState,
                responseMode: responseMode,
                participants: participants
            )
            if botStatus?.isActive == true {
                isJoined = true
            }

        case "system":
            let msg = json["message"] as? String ?? ""
            systemMessages.append(msg)

        case "pong":
            break  // keepalive

        default:
            log.debug("Unknown WS event type: \(type)")
        }
    }

    private func handleSnapshot(_ json: [String: Any]) {
        if let bots = json["bots"] as? [[String: Any]], let first = bots.first {
            botStatus = MeetBotStatus(
                botID: first["bot_id"] as? String ?? "",
                status: first["status"] as? String ?? "",
                pipelineState: first["pipeline_state"] as? String ?? "",
                responseMode: first["response_mode"] as? String ?? "",
                participants: first["participants"] as? [String] ?? []
            )
            isJoined = botStatus?.isActive ?? false
        }
    }

    // MARK: - API Calls

    func joinCall() async {
        guard !meetURL.isEmpty else { return }
        let baseURL = normalizedBaseURL

        do {
            // Health check first
            let healthURL = URL(string: "\(baseURL)/health")!
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 5
            if !pipelineAuthToken.isEmpty {
                req.setValue("Bearer \(pipelineAuthToken)", forHTTPHeaderField: "Authorization")
            }
            let (healthData, _) = try await session.data(for: req)
            log.info("Health check: \(String(data: healthData, encoding: .utf8) ?? "unknown")")

            // Join
            let joinURL = URL(string: "\(baseURL)/api/bot/join")!
            var joinReq = URLRequest(url: joinURL)
            joinReq.httpMethod = "POST"
            joinReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !pipelineAuthToken.isEmpty {
                joinReq.setValue("Bearer \(pipelineAuthToken)", forHTTPHeaderField: "Authorization")
            }
            let body = ["meeting_url": meetURL, "bot_name": "Hank Bob"]
            joinReq.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (joinData, joinResp) = try await session.data(for: joinReq)
            log.info("Join response: \(String(data: joinData, encoding: .utf8) ?? "unknown")")

            if let httpResp = joinResp as? HTTPURLResponse, httpResp.statusCode == 200 {
                // Connect WebSocket
                connect()
                systemMessages.append("Bot joining \(meetURL)...")
            } else {
                systemMessages.append("Join failed: \(String(data: joinData, encoding: .utf8) ?? "unknown")")
            }
        } catch {
            log.error("Join error: \(error.localizedDescription)")
            systemMessages.append("Error: \(error.localizedDescription)")
        }
    }

    func leaveCall() async {
        guard let botID = botStatus?.botID else { return }
        let baseURL = normalizedBaseURL

        do {
            let leaveURL = URL(string: "\(baseURL)/api/bot/\(botID)/leave")!
            var req = URLRequest(url: leaveURL)
            req.httpMethod = "POST"
            if !pipelineAuthToken.isEmpty {
                req.setValue("Bearer \(pipelineAuthToken)", forHTTPHeaderField: "Authorization")
            }
            let (_, _) = try await session.data(for: req)
            systemMessages.append("Leaving call...")
            disconnect()
        } catch {
            log.error("Leave error: \(error.localizedDescription)")
        }
    }

    private var normalizedBaseURL: String {
        if pipelineURL.contains("://") {
            return pipelineURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return "http://\(pipelineURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
    }
}
