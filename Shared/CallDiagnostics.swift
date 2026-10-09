import Foundation
import Combine
#if os(iOS) || os(watchOS)
import WatchConnectivity
#endif

@MainActor final class CallDiagnostics: ObservableObject {
    struct Recording: Identifiable, Equatable {
        let url: URL
        let date: Date
        let bytes: Int
        var id: URL { url }
    }
    static let shared = CallDiagnostics()
    // Consent is deliberately process-local and consumed by exactly one call.
    @Published var recordNextCall = false
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var status: String?
    private let directory: URL
    private let maximumFiles: Int
    private let maximumBytes: Int
    private var activeURL: URL?

    init(directory: URL? = nil, maximumFiles: Int = 5, maximumBytes: Int = 64 * 1024 * 1024) {
        self.directory = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CallDiagnostics", isDirectory: true)).resolvingSymlinksInPath()
        self.maximumFiles = max(1, maximumFiles)
        self.maximumBytes = max(1, maximumBytes)
        refresh()
    }

    func consumeNextCaptureURL() throws -> URL? {
        guard recordNextCall else { return nil }
        recordNextCall = false
        guard activeURL == nil else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var protectedDirectory = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            #if os(iOS) || os(watchOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            #endif
            try prune(reservingFile: true)
            let url = directory.resolvingSymlinksInPath().appendingPathComponent("call-\(UUID().uuidString).dotcall")
            activeURL = url
            status = "Recording incoming agent audio for this call."
            return url
        } catch {
            status = "Diagnostic recording could not start: \(error.localizedDescription)"
            throw error
        }
    }

    func captureFinished(url: URL, error: String?) {
        guard url == activeURL else { return }
        activeURL = nil
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                var protectedFile = url
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protectedFile.setResourceValues(values)
                #if os(iOS) || os(watchOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                #endif
            }
            try prune(reservingFile: false)
            refresh()
            status = error.map { "Diagnostic recording incomplete: \($0)" } ?? (recordings.contains(where: { $0.url == url }) ? "Diagnostic recording saved on this device." : "No diagnostic recording was retained.")
        } catch {
            refresh()
            status = "Diagnostic recording storage: \(error.localizedDescription)"
        }
    }

    nonisolated static func receiveTransferredFile(_ source: URL, directory: URL? = nil) throws -> URL {
        let targetDirectory = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CallDiagnostics", isDirectory: true)).resolvingSymlinksInPath()
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 10 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        var protectedDirectory = targetDirectory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: targetDirectory.path)
        #endif
        let target = targetDirectory.resolvingSymlinksInPath().appendingPathComponent("call-watch-\(UUID().uuidString).dotcall")
        try FileManager.default.copyItem(at: source, to: target)
        do {
            var protectedFile = target
            try protectedFile.setResourceValues(values)
            #if os(iOS) || os(watchOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            #endif
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        return target
    }

    func transferReceived(error: String?) {
        do { try prune(reservingFile: false) }
        catch { status = "Could not manage diagnostic storage: \(error.localizedDescription)"; refresh(); return }
        status = error.map { "Watch recording could not be saved: \($0)" } ?? "Watch diagnostic recording saved on this iPhone."
        refresh()
    }

    #if os(watchOS)
    func sendToPhone(_ recording: Recording) {
        guard savedRecordings().contains(where: { $0.url == recording.url }) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { status = "The iPhone connection is starting. Try again shortly."; return }
        guard session.outstandingFileTransfers.allSatisfy({ $0.file.metadata?["kind"] as? String != "callDiagnostics" }) else { status = "A diagnostic recording is already queued for iPhone."; return }
        session.transferFile(recording.url, metadata: ["kind": "callDiagnostics"])
        status = "Recording queued for iPhone. It remains on this Watch."
    }
    func transferFinished(error: String?) {
        status = error.map { "Recording transfer failed: \($0)" } ?? "Recording delivered to iPhone. The Watch copy is still saved."
    }
    #endif

    private func isTransferring(_ url: URL) -> Bool {
        #if os(watchOS)
        return WCSession.default.outstandingFileTransfers.contains { $0.file.metadata?["kind"] as? String == "callDiagnostics" && $0.file.fileURL.lastPathComponent == url.lastPathComponent }
        #else
        return false
        #endif
    }

    func refresh() {
        recordings = savedRecordings()
    }

    func delete(_ recording: Recording) {
        guard !isTransferring(recording.url) else { status = "Wait for the iPhone transfer to finish before deleting this recording."; return }
        guard recording.url != activeURL, savedRecordings().contains(where: { $0.url == recording.url }) else { return }
        do {
            try FileManager.default.removeItem(at: recording.url)
            refresh()
            status = "Diagnostic recording deleted."
        } catch { status = "Could not delete recording: \(error.localizedDescription)" }
    }

    private func savedRecordings() -> [Recording] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return [] }
        return files.compactMap { listedURL in
            let url = directory.appendingPathComponent(listedURL.lastPathComponent)
            guard url != activeURL, url.lastPathComponent.hasPrefix("call-"), url.pathExtension == "dotcall",
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return Recording(url: url, date: values.contentModificationDate ?? .distantPast, bytes: values.fileSize ?? 0)
        }.sorted { $0.date > $1.date }
    }

    private func prune(reservingFile: Bool) throws {
        var files = savedRecordings()
        let countLimit = maximumFiles - (reservingFile ? 1 : 0)
        var bytes = files.reduce(0) { $0 + $1.bytes }
        while files.count > countLimit || bytes > maximumBytes {
            guard let index = files.lastIndex(where: { !isTransferring($0.url) }) else { throw CocoaError(.fileWriteUnknown) }
            let oldest = files.remove(at: index)
            try FileManager.default.removeItem(at: oldest.url)
            bytes -= oldest.bytes
        }
        refresh()
    }
}
