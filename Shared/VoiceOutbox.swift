import Foundation
import Combine
#if os(watchOS)
import WatchKit
#endif

// Receipt history is durable; the success notice belongs only to this visit.
// Loading saved sent jobs never recreates a notice.
struct VoiceSentNotice {
    private(set) var messageID: UUID?
    mutating func received(_ message: VoiceMessage, account: DotAccount?) {
        guard message.state == .sent, let receipt = message.serverMessageID, !receipt.isEmpty,
              message.belongs(to: account) else { return }
        messageID = message.id
    }
    func isVisible(in messages: [VoiceMessage], account: DotAccount?) -> Bool {
        guard let messageID, let message = messages.first(where: { $0.id == messageID }) else { return false }
        return message.state == .sent && message.serverMessageID?.isEmpty == false && message.belongs(to: account)
    }
    mutating func accountChanged(messages: [VoiceMessage], account: DotAccount?) {
        if !isVisible(in: messages, account: account) { dismiss() }
    }
    mutating func dismiss() { messageID = nil }
}

@MainActor final class VoiceOutbox: NSObject, ObservableObject, @preconcurrency URLSessionDataDelegate {
    static let shared = VoiceOutbox()
    static var sessionID: String { (Bundle.main.bundleIdentifier ?? "com.example.dotwatch.watchkitapp") + ".voice-outbox" }
    @Published private(set) var messages: [VoiceMessage] = []
    @Published var error: String?
    @Published private var sentNotice = VoiceSentNotice()
    // A short-lived preview survives receipt cleanup, but never writes delivered
    // transcript text back to disk. Reopening or finishing a call dismisses it.
    @Published private var previewMessage: VoiceMessage?
    private var previewTargetID: UUID?
    private var store: VoiceOutboxStore?
    private var preparing = false
    private var activeTasks: [Int: UUID?] = [:]
    private var completedDuringRestore: Set<Int> = []
    private var restored = false
    private var restoring = false
    private var processing = 0
    private var scheduledPumps = 0
    private var eventsFinished = false
    #if os(watchOS)
    private var wakes: [WKURLSessionRefreshBackgroundTask] = []
    #elseif os(iOS)
    private var backgroundCompletions: [() -> Void] = []
    #endif
    private var hasBackgroundWake: Bool {
        #if os(watchOS)
        !wakes.isEmpty
        #elseif os(iOS)
        !backgroundCompletions.isEmpty
        #else
        false
        #endif
    }
    private var responseData: [Int: Data] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 3600
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    var hasMessages: Bool { !messages.isEmpty }
    var transcriptPreview: String? {
        guard let previewMessage, previewMessage.belongs(to: AccountVault.load()),
              messages.contains(where: { $0.id == previewMessage.id }) else { return nil }
        return previewMessage.transcript
    }
    func transcript(for message: VoiceMessage) -> String? {
        if let transcript = message.transcript { return transcript }
        return previewMessage?.id == message.id ? transcriptPreview : nil
    }
    var pendingCount: Int { messages.filter(\.pending).count }
    var failedCount: Int { messages.filter(\.needsAttention).count }
    var canRecord: Bool { store != nil && messages.filter { $0.state != .sent }.count < 5 }
    var status: String? {
        if failedCount > 0 { return "\(failedCount) message\(failedCount == 1 ? "" : "s") need attention" }
        if pendingCount > 0 { return "Sending \(pendingCount) message\(pendingCount == 1 ? "" : "s")…" }
        if sentNotice.messageID != nil, sentNotice.isVisible(in: messages, account: AccountVault.load()) { return "Message sent" }
        return nil
    }
    func dismissMessageFeedback() {
        if sentNotice.messageID != nil { sentNotice.dismiss() }
        previewMessage = nil
        previewTargetID = nil
    }
    override init() {
        super.init()
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let store = try VoiceOutboxStore(directory: root.appendingPathComponent("VoiceOutbox"))
            messages = try store.load(); self.store = store
        } catch { self.error = "The message outbox could not be opened. Restart the app before recording." }
    }
    func resume() {
        guard !VoiceSimulatorUI.enabled else { return }
        guard store != nil else { return }
        guard !restoring else { return }
        guard !restored else { schedulePump(); return }
        restoring = true
        _ = session
        session.getAllTasks { tasks in
            Task { @MainActor in
                // Delegate completions can precede this snapshot's MainActor turn.
                // Do not put already-completed tasks back into the active set.
                let live = tasks.filter { !self.completedDuringRestore.contains($0.taskIdentifier) }
                self.activeTasks = Dictionary(uniqueKeysWithValues: live.map {
                    ($0.taskIdentifier, $0.taskDescription.flatMap(UUID.init(uuidString:)))
                })
                let active = Set(live.compactMap { $0.taskDescription })
                for message in self.messages where [.transcribing, .sending].contains(message.state) && !active.contains(message.id.uuidString) {
                    self.update(message.id) {
                        if $0.state == .sending {
                            $0.state = .uncertain; $0.detail = "Delivery is unconfirmed after restart. Check Dot before retrying."
                        } else { $0.state = .queued }
                    }
                }
                self.completedDuringRestore.removeAll()
                self.restoring = false; self.restored = true
                self.cancelMismatchedTasks(live)
                await self.pump()
                self.finishWakesIfReady()
            }
        }
    }
    func enqueue(file: URL, duration: TimeInterval, account: DotAccount) throws {
        guard canRecord, let store else { throw RelayFailure(message: "Outbox is full. Resolve or remove old messages first.") }
        guard let current = AccountVault.load(), current.accountID == account.accountID, current.dotID == account.dotID else {
            throw RelayFailure(message: "The connected Dot changed. This recording was not sent.")
        }
        let id = UUID(), audio = try Data(contentsOf: file)
        try VoiceRecordingLimits.validate(duration: duration, audioBytes: audio.count)
        try store.write(audio, to: store.file(id, "m4a"))
        var next = messages.filter { $0.state != .sent || Date().timeIntervalSince($0.createdAt) < 86400 }
        next.append(VoiceMessage(id: id, accountID: account.accountID, dotID: account.dotID, createdAt: Date(), duration: duration))
        do { try store.save(next); messages = next; previewMessage = nil; previewTargetID = id }
        catch { store.removeMedia(id); throw RelayFailure(message: "Could not save the message. Recording is still here; try Send again.") }
        resume()
    }
    func retry(_ id: UUID) {
        guard restored, !restoring else {
            error = "Checking saved deliveries. Try again in a moment."; resume(); return
        }
        guard !activeTasks.values.contains(where: { $0 == id }),
              let job = messages.first(where: { $0.id == id }), job.needsAttention else { return }
        guard job.belongs(to: AccountVault.load()) else { error = "Reconnect the original Dot before retrying this message."; return }
        guard update(id, { $0.state = .queued; $0.detail = nil }) else { return }
        error = nil
        resume()
    }
    func remove(_ id: UUID) {
        guard restored, !restoring, !activeTasks.values.contains(where: { $0 == id }),
              let store, let job = messages.first(where: { $0.id == id }), !job.pending else { return }
        let next = messages.filter { $0.id != id }
        do {
            try store.save(next); messages = next; store.removeMedia(id)
            if sentNotice.messageID == id { sentNotice.dismiss() }
            if previewMessage?.id == id { previewMessage = nil }
            if previewTargetID == id { previewTargetID = nil }
        }
        catch { self.error = "Could not remove this recording. Try again." }
    }
    @discardableResult private func update(_ id: UUID, _ change: (inout VoiceMessage) -> Void) -> Bool {
        guard let store, let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        var next = messages; change(&next[index])
        do { try store.save(next); messages = next; return true }
        catch { self.error = "Could not save message status. Reopen the app and check Dot before retrying."; return false }
    }
    private func schedulePump() {
        // Schedule the next upload before releasing either platform's
        // background wake, including the transcription -> send step.
        scheduledPumps += 1
        Task {
            await pump()
            scheduledPumps -= 1
            finishWakesIfReady()
        }
    }
    private func pump() async {
        guard restored, !restoring, !preparing, activeTasks.isEmpty, processing == 0,
              let store, let job = messages.first(where: { $0.state == .queued }) else { return }
        preparing = true
        defer { preparing = false; finishWakesIfReady() }
        do {
            guard job.belongs(to: AccountVault.load()), let original = AccountVault.load() else {
                throw RelayFailure(message: "Reconnect the original Dot to send this saved recording.")
            }
            let account = try await DotSession.valid(original)
            guard job.belongs(to: account), job.belongs(to: AccountVault.load()) else {
                throw RelayFailure(message: "The connected Dot changed. Message not sent.")
            }
            var room = job.roomID
            if room == nil {
                let request = VoiceMessageWire.request(path: "/tbo/" + (try VoiceMessageWire.pathComponent(account.dotID)), account: account)
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                let lookup = URLSession(configuration: config, delegate: self, delegateQueue: .main)
                defer { lookup.finishTasksAndInvalidate() }
                let (data, response) = try await lookup.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                guard status == 200 else { throw RelayFailure(message: VoiceMessageWire.failure(status: status, sending: false).1) }
                let profile = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard profile?["id"] as? String == account.dotID, let value = profile?["messaging_room_id"] as? String else {
                    throw RelayFailure(message: "Open your Dot on the web and send a message once to initialize messaging.")
                }
                room = try VoiceMessageWire.pathComponent(value)
                guard update(job.id, { $0.roomID = room }) else { return }
            }
            guard job.belongs(to: AccountVault.load()), var latest = messages.first(where: { $0.id == job.id }), latest.state == .queued else {
                throw RelayFailure(message: "The connected Dot changed. Message not sent.")
            }
            let sending = latest.transcript != nil
            var request: URLRequest
            let body: Data
            if sending {
                request = VoiceMessageWire.request(path: "/messaging/rooms/" + (try VoiceMessageWire.pathComponent(room!)) + "/messages", account: account)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                body = try VoiceMessageWire.messageBody(latest)
            } else {
                let boundary = "DotVoice-" + UUID().uuidString
                request = VoiceMessageWire.request(path: "/transcribe", account: account)
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                body = try VoiceMessageWire.multipart(audio: try Data(contentsOf: store.file(job.id, "m4a")), boundary: boundary, id: job.id, duration: job.duration)
            }
            request.httpMethod = "POST"
            try store.write(body, to: store.file(job.id, "body"))
            latest.state = sending ? .sending : .transcribing
            guard update(job.id, { $0 = latest }) else { return }
            let task = session.uploadTask(with: request, fromFile: store.file(job.id, "body"))
            task.taskDescription = job.id.uuidString
            activeTasks[task.taskIdentifier] = .some(job.id)
            if !hasBackgroundWake { eventsFinished = false }
            task.resume()
        } catch {
            let saved = update(job.id) { $0.state = .failed; $0.detail = (error as? RelayFailure)?.message ?? "Could not prepare the message. Recording saved; retry when connected." }
            // Schedule after the preparation lock is released by defer. A failed
            // store write must stop, rather than loop forever on the same job.
            if saved { schedulePump() }
        }
    }
    private func cancelMismatchedTasks(_ tasks: [URLSessionTask]) {
        for task in tasks {
            guard let value = task.taskDescription, let id = UUID(uuidString: value), let job = messages.first(where: { $0.id == id }) else { task.cancel(); continue }
            guard job.belongs(to: AccountVault.load()), [.transcribing, .sending].contains(job.state) else {
                task.cancel(); continue
            }
            // A process can terminate between creating and resuming an upload.
            // Resume only persisted in-flight work, never a delivery-unknown job.
            if task.state == .suspended { task.resume() }
        }
    }
    func accountChanged() {
        guard !VoiceSimulatorUI.enabled else { return }
        sentNotice.accountChanged(messages: messages, account: AccountVault.load())
        if let previewMessage, !previewMessage.belongs(to: AccountVault.load()) { self.previewMessage = nil }
        if let previewTargetID, !messages.contains(where: { $0.id == previewTargetID && $0.belongs(to: AccountVault.load()) }) { self.previewTargetID = nil }
        // Reconciliation owns the initial task snapshot. Calling pump before it
        // completes could send a second copy of a persisted in-flight message.
        resume()
        session.getAllTasks { tasks in
            Task { @MainActor in self.cancelMismatchedTasks(tasks); await self.pump() }
        }
    }
    #if os(watchOS)
    func handle(_ task: WKURLSessionRefreshBackgroundTask) {
        guard task.sessionIdentifier == Self.sessionID else { task.setTaskCompletedWithSnapshot(false); return }
        wakes.append(task)
        _ = session
        resume()
        finishWakesIfReady()
    }
    #elseif os(iOS)
    // Called by UIApplicationDelegate when iOS relaunches this app for its
    // existing background session. The completion is held until reconciliation,
    // delegate processing, and any scheduled follow-up upload preparation drain.
    func handleBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard !VoiceSimulatorUI.enabled else { completionHandler(); return }
        guard identifier == Self.sessionID else { completionHandler(); return }
        backgroundCompletions.append(completionHandler)
        _ = session
        resume()
        finishWakesIfReady()
    }
    #endif
    private func finishWakesIfReady() {
        guard eventsFinished, processing == 0, scheduledPumps == 0, !restoring, !preparing, hasBackgroundWake else { return }
        #if os(watchOS)
        let ready = wakes; wakes.removeAll()
        #elseif os(iOS)
        let ready = backgroundCompletions; backgroundCompletions.removeAll()
        #endif
        eventsFinished = false
        #if os(watchOS)
        ready.forEach { $0.setTaskCompletedWithSnapshot(false) }
        #elseif os(iOS)
        ready.forEach { $0() }
        #endif
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard session.configuration.identifier == Self.sessionID else { return }
        eventsFinished = true; finishWakesIfReady()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session.configuration.identifier == Self.sessionID else { return }
        // Bound response memory; never print server bodies, transcript, or tokens.
        if (responseData[dataTask.taskIdentifier]?.count ?? 0) + data.count > 1_000_000 { dataTask.cancel(); return }
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError failure: Error?) {
        guard session.configuration.identifier == Self.sessionID else { return }
        let data = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        activeTasks.removeValue(forKey: task.taskIdentifier)
        if restoring { completedDuringRestore.insert(task.taskIdentifier) }
        processing += 1
        defer {
            processing -= 1
            schedulePump()
            finishWakesIfReady()
        }
        // Unknown or stale tasks still release their scheduler slot and response
        // buffer. They must never change another message or reset preparation.
        guard let value = task.taskDescription, let id = UUID(uuidString: value),
              let job = messages.first(where: { $0.id == id }), job.state != .sent else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let sending = task.originalRequest?.url?.lastPathComponent == "messages" || job.state == .sending
        // Background URLSession follows redirects without calling our redirect
        // delegate. Validate its final response before trusting any server body;
        // this cannot prevent a redirect or the preceding data transfer.
        if task.response != nil, !hasExpectedResponseURL(task) {
            update(id) {
                $0.state = sending ? .uncertain : .failed
                $0.detail = sending
                    ? "Delivery is unconfirmed after an unexpected response. Check Dot before retrying."
                    : "ChatGPT returned an unexpected response destination. Recording saved; retry later."
            }
            return
        }
        if failure == nil, let status, (200..<300).contains(status) {
            do {
                if sending {
                    let receipt = try VoiceMessageWire.receipt(data)
                    let saved = update(id) { $0.state = .sent; $0.serverMessageID = receipt; $0.detail = nil; $0.transcript = nil }
                    if saved {
                        store?.removeMedia(id)
                        if let confirmed = messages.first(where: { $0.id == id }) { sentNotice.received(confirmed, account: AccountVault.load()) }
                    }
                } else {
                    let transcript = try VoiceMessageWire.transcript(data)
                    let saved = update(id) { $0.transcript = transcript; $0.state = .queued; $0.detail = nil }
                    if saved, previewTargetID == id, let transcribed = messages.first(where: { $0.id == id }), transcribed.belongs(to: AccountVault.load()) {
                        previewMessage = transcribed
                    }
                }
            } catch {
                update(id) { $0.state = sending ? .uncertain : .failed; $0.detail = (error as? RelayFailure)?.message ?? "Could not read ChatGPT's response. Recording saved." }
            }
        } else {
            let result = VoiceMessageWire.failure(status: failure == nil ? status : nil, sending: sending)
            update(id) { $0.state = result.0; $0.detail = result.1 }
        }
    }
    private func hasExpectedResponseURL(_ task: URLSessionTask) -> Bool {
        guard let originalURL = task.originalRequest?.url, let finalURL = task.response?.url,
              let original = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              let final = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) else { return false }
        return original.scheme == "https" && original.host == "chatgpt.com"
            && final.scheme == "https" && final.host == "chatgpt.com"
            && (final.port == nil || final.port == 443)
            && final.user == nil && final.password == nil
            && final.percentEncodedPath == original.percentEncodedPath
            && final.percentEncodedQuery == original.percentEncodedQuery
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
