# Local Watch transport adaptation

Source: https://github.com/1amageek/swift-webrtc, tag 3.0.0, commit `f35ac95e4e743b1fb6be50c184e7d3691ef7ddb1`.
Only `Sources/WebRTC` is included, compiled as `WatchRTC` for the native Watch transport. Dependency versions are pinned in Package.swift and Package.resolved. Network.framework is provided by DirectRTC; no NetworkingPOSIX socket implementation is instantiated on Watch.

Local changes:
- `WebRTCConnection.startDataChannelAssociation()` allows the SDP offerer to initiate SCTP when its negotiated DTLS role is server. DTLS role still determines data-channel stream parity. Tested against aiortc's DTLS-client/SCTP-server answer.
- `refreshConsent()` and the ICE owner seams start fresh authenticated STUN consent transactions without re-nominating a pair or resetting DTLS. Transactions run every five seconds and fail closed after a five-second response timeout.

Validation: bidirectional DTLS/SRTP/Opus and SCTP data-channel interoperability with aiortc 1.15.0, mismatch of the signalled certificate fingerprint rejected before media, real watchOS target compilation, and Watch simulator integration. This is a personal development build, not a general-purpose WebRTC stack. Candidate routing and hardware behavior must be verified on actual networks.
