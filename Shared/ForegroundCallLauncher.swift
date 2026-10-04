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
    func request(start: @escaping () -> Void, onTimeout: @escaping () -> Void) {
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
                if isActive() {
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
        pending?.cancel()
        pending = nil
    }
}
