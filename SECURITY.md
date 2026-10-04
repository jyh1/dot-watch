# Security and privacy

Dot signs in through ChatGPT's official website in an iPhone WKWebView. It reads the signed-in session for calls to `https://chatgpt.com` and transfers session material to the paired Watch through WatchConnectivity. No developer-run credential relay exists.

- Account tokens and filtered secure ChatGPT cookies use device-only Keychain storage, available after the device's first unlock following reboot.
- Session renewal requires the returned account identity to match the connected account.
- Authenticated session and call requests reject redirects.
- SDP must include the remote certificate fingerprint before encrypted media is accepted.
- The widget stores no account data and starts the containing app through a validated call URL.
- The call trace records timing, state and short error diagnostics. Review logs before sharing; they are not a public support attachment by default.
- The iPhone login web view uses persistent website storage. The in-app Disconnect action clears the app's saved account/session and sends a clearing update to the paired Watch; do not equate that with revoking a ChatGPT session on the server. Open the Watch and allow synchronization to finish. Use ChatGPT's account session controls if server-side revocation is needed.

Do not commit configuration overrides, generated Xcode projects, website data, device containers, auth/session exports, signed archives or provisioning material. `.gitignore` is a guardrail, not a secret scanner. Before release, inspect the staged file list and run a scanner over both the tree and Git history.

The simulator fixture uses synthetic account values and a local test peer. It is enabled only for simulator builds through explicit launch arguments; it does not require a real ChatGPT login or use audio hardware.

This experimental client and its custom WebRTC transport have not undergone an independent security audit. Report vulnerabilities without including account credentials or raw session data in public issues.
