// CallKit may finish creating its provider after the app receives a widget URL.
// Submit once, only after providerDidBegin; cancellation is terminal for this call.
@MainActor final class CallProviderReadiness {
    private var ready = false
    private var cancelled = false
    private var submitted = false
    private var pending: (() -> Void)?

    func request(_ action: @escaping () -> Void) {
        guard !cancelled, !submitted, pending == nil else { return }
        pending = action
        submitIfReady()
    }
    func providerDidBegin() {
        guard !cancelled else { return }
        ready = true
        submitIfReady()
    }
    func cancel() { cancelled = true; pending = nil }
    private func submitIfReady() {
        guard ready, !cancelled, !submitted, let action = pending else { return }
        submitted = true; pending = nil
        action()
    }
}
