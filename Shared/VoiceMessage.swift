import Foundation

// No authentication material belongs in the outbox. A job stays bound to the
// account and Dot selected when the user recorded it, including after relaunch.
struct VoiceMessage: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, transcribing, sending, sent, failed, uncertain }
    let id: UUID
    let accountID: String
    let dotID: String
    let createdAt: Date
    let duration: TimeInterval
    var roomID: String?
    var transcript: String?
    var state: State = .queued
    var detail: String?
    var serverMessageID: String?
    var needsAttention: Bool { state == .failed || state == .uncertain }
    var pending: Bool { [.queued, .transcribing, .sending].contains(state) }
    func belongs(to account: DotAccount?) -> Bool {
        account?.accountID == accountID && account?.dotID == dotID
    }
}

enum VoiceRecordingLimits {
    static let maximumAudioBytes = 10_000_000
    // Stop ahead of the app's file-size guard so the encoder can flush a final AAC block
    // and container metadata. This is a storage limit, not a recording timer.
    static let stoppingAudioBytes = maximumAudioBytes - 65_536
    static func validate(duration: TimeInterval, audioBytes: Int) throws {
        guard duration.isFinite, duration >= 1, (duration * 1000).isFinite else {
            throw RelayFailure(message: "Record at least one second of audio first.")
        }
        guard audioBytes > 0, audioBytes <= maximumAudioBytes else {
            throw RelayFailure(message: "Recording is empty or exceeds the app's 10 MB recording size limit.")
        }
    }
    static func shouldStop(audioBytes: Int) -> Bool { audioBytes >= stoppingAudioBytes }
}

enum VoiceMessageWire {
    static func pathComponent(_ value: String) throws -> String {
        guard value != ".", value != "..",
              value.range(of: "^[a-zA-Z0-9_~.-]{1,200}$", options: .regularExpression) != nil else {
            throw RelayFailure(message: "Dot returned an invalid message destination.")
        }
        return value
    }
    static func request(path: String, account: DotAccount) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api" + path)!)
        request.timeoutInterval = 60
        request.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization")
        request.setValue(account.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceID = account.deviceID { request.setValue(deviceID, forHTTPHeaderField: "OAI-Device-Id") }
        // No browser impersonation, integrity bypass, or app-attestation override.
        return request
    }
    static func messageBody(_ job: VoiceMessage) throws -> Data {
        guard let text = job.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw RelayFailure(message: "No speech was detected. Record another message.")
        }
        return try JSONSerialization.data(withJSONObject: [
            "content": ["text": text],
            "request_id": job.id.uuidString.lowercased(),
            "idempotency_token": job.id.uuidString.lowercased()
        ])
    }
    static func multipart(audio: Data, boundary: String, id: UUID, duration: TimeInterval) throws -> Data {
        try VoiceRecordingLimits.validate(duration: duration, audioBytes: audio.count)
        var result = Data()
        func append(_ string: String) { result.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"message.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        result.append(audio); append("\r\n")
        for (key, value) in [("dictation_session_id", id.uuidString.lowercased()), ("attempt_id", UUID().uuidString.lowercased()), ("duration_ms", String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), floor(duration * 1000)))] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)--\r\n")
        return result
    }
    static func transcript(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = object?["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayFailure(message: "No speech was detected. Record another message.")
        }
        return text
    }
    static func receipt(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = object?["id"] as? String, !id.isEmpty else {
            throw RelayFailure(message: "Delivery is unconfirmed. Check Dot before retrying.")
        }
        return id
    }
    static func failure(status: Int?, sending: Bool) -> (VoiceMessage.State, String) {
        if status == 401 { return (.failed, "Sign in again on iPhone, sync the Watch, then retry.") }
        if status == 403 { return (.failed, "ChatGPT denied this request. Open the web app; this client may not support its verification requirements.") }
        if status == 429 { return (.failed, "ChatGPT is busy or rate-limited. Wait before retrying.") }
        if status == 413 { return (.failed, "Recording is too large. Record a shorter message.") }
        if sending && (status == nil || status == 408 || status! >= 500 || (200..<300).contains(status!)) {
            return (.uncertain, "Delivery is unconfirmed. Check Dot first. Retry keeps the same message ID.")
        }
        return (.failed, "Could not \(sending ? "send" : "transcribe") the message\(status.map { " (HTTP \($0))" } ?? ""). Recording saved; retry when connected.")
    }
}

final class VoiceOutboxStore {
    let directory: URL
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    func file(_ id: UUID, _ suffix: String) -> URL { directory.appendingPathComponent(id.uuidString + "." + suffix) }
    func load() throws -> [VoiceMessage] {
        let url = directory.appendingPathComponent("outbox.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VoiceMessage].self, from: Data(contentsOf: url))
    }
    func save(_ messages: [VoiceMessage]) throws {
        try write(try JSONEncoder().encode(messages), to: directory.appendingPathComponent("outbox.json"))
    }
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func removeMedia(_ id: UUID) {
        for suffix in ["m4a", "body", "response"] { try? FileManager.default.removeItem(at: file(id, suffix)) }
    }
}
