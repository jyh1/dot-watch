# Incoming call audio

Build 32 replaces the live incoming-audio receiver with upstream WebRTC NetEq and libopus. It uses mono 48 kHz PCM in 10 ms blocks. Microphone capture and outgoing Apple Opus encoding remain at 24 kHz, with one outgoing packet every 20 ms.

See the [native build instructions](../DirectRTC/NETEQ_BUILD.md) for pinned sources, supported architectures and the cached dependency build. Upstream licenses are included in both device app bundles.

The receiver uses the configuration selected in a private listening comparison: an 80 ms minimum delay and a 500 ms maximum adaptive delay target, with other NetEq settings at upstream defaults. NetEq combines a jitter buffer, pitch-preserving time scaling and packet-loss concealment. Its local Opus format enables in-band FEC support; recovery through FEC still depends on redundancy actually supplied by the sender.

The 500 ms setting is a target limit, not a hard limit on every packet's age. A severe arrival burst can temporarily produce more buffering. In the selected offline comparison, smoother speech came with a few hundred milliseconds more typical receive-to-output delay and a rare peak around 1.3 seconds. Those figures exclude the device's audio engine and speaker. Neither concealment nor time scaling can restore the original contents of a packet that never arrived.

Packets become available only when the codec worker receives them. Their original monotonic network arrival time is passed separately to NetEq. The receiver is pulled on a serial 10 ms timer and does not synthesize missed timer callbacks using packets that arrived later. Audio output remains bounded separately from NetEq's adaptive buffer.

## Validation boundary

The implementation is based on the same pinned upstream receiver used for the listening comparison. Offline replay can check decoding, timing, loss recovery and source consistency without opening an audio device. Simulator transport checks can exercise the app's incoming and outgoing paths with a local synthetic peer. Neither establishes physical Watch battery use, Bluetooth routing, or the exact sound at its speaker.

Keep diagnostic captures and comparison audio private. See [capture and replay](AUDIO_DIAGNOSTICS.md) for the opt-in diagnostic workflow and [validation](TESTING.md) for completed checks and remaining hardware checks.
