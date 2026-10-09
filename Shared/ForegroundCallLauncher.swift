import Foundation
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

// A widget URL can arrive while the app is still background/inactive. Starting
// CallKit at that point can be rejected even though the app is about to appear.
@MainActor final class ForegroundCallLauncher {
    private let isActive: () -> Bool
    private let timeout: Duration
    private var pending: Task<Void, Never>?
    private var cancellationGeneration = 0
    var isPending: Bool { pending != nil }

    init(timeout: Duration = .seconds(10), isActive: @escaping () -> Bool = ForegroundCallLauncher.appIsActive) {
        self.timeout = timeout
        self.isActive = isActive
    }
    static func appIsActive() -> Bool {
        #if os(watchOS)
        return WKExtension.shared().applicationState == .active
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }
    // Intent execution may begin before the foreground scene finishes activating.
    // Keep this wait in the caller's task so cancellation leaves no queued call.
    func awaitActive(sceneIsActive: @escaping () -> Bool) async throws {
        let generation = cancellationGeneration
        let deadline = ContinuousClock.now.advanced(by: timeout)
        await Task.yield()
        while true {
            try Task.checkCancellation()
            guard generation == cancellationGeneration else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw ActivationTimeout() }
            if sceneIsActive() && isActive() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private struct ActivationTimeout: LocalizedError {
        var errorDescription: String? { "The app could not become active. Open it and tap Call." }
    }
    func request(sceneIsActive: @escaping () -> Bool = { true }, start: @escaping () -> Void, onTimeout: @escaping () -> Void) {
        guard pending == nil else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        pending = Task { [weak self] in
            // Leave the URL delivery callback before consulting native app state.
            await Task.yield()
            guard let self else { return }
            while !Task.isCancelled {
                guard ContinuousClock.now < deadline else {
                    pending = nil
                    onTimeout()
                    return
                }
                if sceneIsActive() && isActive() {
                    pending = nil
                    start()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }
    func cancel() {
        cancellationGeneration += 1
        pending?.cancel()
        pending = nil
    }
}
