# Call audio capture and replay

Build 29 introduced opt-in incoming audio capture. Normal calls do not create these files. Build 32 uses NetEq/libopus for incoming call audio and records a version 2 header with mono 48 kHz PCM and a 10 ms render interval. Older version 1 captures retain their 24 kHz, 20 ms replay path.

## Runtime cost

Keep the feature available with **Record next call off by default**. When it is off, no packet-capture object or writer queue is created. The audio path only checks the optional recorder; it does not serialize audio or write capture files. Opening diagnostics may list the small set of retained files. Disabled capture has negligible audio-path overhead by code inspection; physical Watch battery overhead has not been measured directly.

Enabled capture adds brief bounded queue/lock work on the audio path and base64/JSON serialization plus file writes on a utility queue. Its storage and duration limits keep this work bounded, but it is not free. Use it for a specific diagnostic call rather than recording every call. Files contain incoming conversation audio and stay on the device until explicitly transferred/exported or removed.

## Capture one call

1. On iPhone, expand **Settings & diagnostics → Call audio diagnostics**. On Watch, open **Info → Call audio diagnostics**.
2. Enable **Record next call**, close the sheet, then make the call normally on that device. The option is consumed once and is off after the app restarts.
3. End the call. The recording appears after its writer finishes. Open diagnostics and export it on iPhone. On Watch, tap **Send to iPhone**, wait for delivery, then export from iPhone diagnostics. The Watch copy remains until deleted or pruned.

These files contain the agent's audible conversation, not just counters. No microphone audio is saved. Nothing uploads automatically. Each capture is capped at five minutes or 10 MiB; the call continues after capture stops. The five most recent files are kept within a 64 MiB storage limit. Delete individual captures in diagnostics when finished. Exported copies must be removed separately.

The `.dotcall` file is versioned newline-delimited JSON with an audio-clock header, base64 decrypted Opus packets, RTP sequence/timestamps, original monotonic arrival times, codec-worker insertion times, render times and a final summary. It excludes credentials, SDP, device/account IDs and network addresses. Aggregate call metrics also use bounded lines to avoid the earlier log truncation. This is diagnostic audio capture, not a standard PCAP file.

## Replay without making another call

On a Mac with the project toolchain, from `DirectRTC/`:

```sh
swift run PacketReplay /private/path/example.dotcall /private/path/new-replay-folder
```

The output directory must not exist. The tool opens no audio device and performs no service calls. SwiftPM may resolve build dependencies if not cached. Outputs:

- `arrival-playout.wav`: the receiver named by the capture format, applied to recorded packet insertion and render timing while retaining original arrival times. Version 2 uses genuine NetEq/libopus at 48 kHz; version 1 uses the earlier Apple-decoder receiver at 24 kHz.
- `timestamp-reference.wav`: the same received packets decoded in RTP media order, with missing ranges left silent. Version 2 uses libopus and anchors the reference to initial packet availability; this is a source-order reference, not the receiver's actual playout timing. It cannot reconstruct packets that were never received.
- `metrics.json`: buffering, concealment, late/drop, capture-integrity and waveform-size counters. Build 31 also reports receive-to-decode latency and counters restricted to the recorded render interval.
- `diagnostics.json`: bounded decode/late/conceal/rebuffer event timing and RTP metadata for correlating interruptions. It contains no additional audio payload, but keep it private alongside its capture.

Keep the original file fixed while changing the receiver in source, replay to a fresh directory, then compare artifacts. Replay appends a short synthetic drain after the captured render ticks; `actual*` metrics exclude that drain. Receive-to-decode latency excludes the audio engine, speaker and network before reception. Compare waiting plus concealment PCM, not concealment count alone: a receiver can previously have emitted uncounted silence while refilling. The reference is not browser output or a lossless original. Replay does not reproduce AVAudioEngine queues, voice processing, Bluetooth behavior or the exact sound heard through a speaker. Incomplete/capped captures and capture-writer drops are reported; distinguish these from actual network loss. A source-clock reset may prevent creating a meaningful single RTP-order reference. Never commit raw captures or replay audio; their extensions are ignored as a guardrail.

## Comparing burst recovery

The earlier adaptive-playback experiment applies only to version 1 captures. It compares the same capture with a larger bounded buffer, with and without pitch-preserving time compression. Output remains 480 samples at 24 kHz every 20 ms; acceleration consumes more source audio rather than changing the output sample rate. A requested speed is a ceiling, not a guarantee: the processor can decline a splice when it cannot find a sufficiently similar waveform.

The version 1 default replay keeps the earlier 500 ms limit with experimental compression disabled. The live Build 32 receiver uses NetEq instead; these legacy controls are rejected for version 2 captures. To compare the older experimental controls, use distinct output directories:

```sh
swift run PacketReplay /private/path/example.dotcall /private/path/baseline
swift run PacketReplay /private/path/example.dotcall /private/path/headroom --backlog-ms=1000
swift run PacketReplay /private/path/example.dotcall /private/path/accelerated --backlog-ms=1000 --compression --max-speed=1.10
```

Compare the same source interval at unchanged gain when listening. Different receiver delays mean equal wall-clock cuts may contain different words. Source-consumption diagnostics map RTP packets to output times. Consumption includes deliberately compressed spans; it does not mean every original sample was played. Arrival-to-decode latency alone understates delay when decoded audio is waiting in the receiver. Report waiting/concealment, safety discards and pending media alongside consumption latency, and compare the larger-buffer-only control to isolate the effect of compression.

Keep candidate recordings and experiments private. Listening comparisons guide a release choice; a successful replay or desktop benchmark does not validate physical Watch performance.

## Browser comparison

The previously inspected ChatGPT web client uses browser WebRTC. Chrome's `chrome://webrtc-internals` dump provides connection and receiver statistics; its diagnostic packet/event recording contains RTP headers and RTCP, not Opus payloads. Its optional diagnostic audio recording can produce input/output WAV and audio-processing dumps, potentially for other tabs/streams too. Keep those exports local and isolate unrelated browser audio before recording. See [Chromium's diagnostic UI source](https://chromium.googlesource.com/chromium/src.git/+/e102d7cb9bd8a6b610ca361cd9f07a7d434e9af6/content/browser/webrtc/resources/webrtc_internals.html) and [WebRTC statistics definitions](https://w3c.github.io/webrtc-stats/).

Useful browser comparisons include changes in concealment events/samples, discarded or lost packets, jitter, and average jitter-buffer delay calculated from interval counter differences. A separate browser call has different source audio and network timing; it is not an identical-packet A/B experiment. Use the app's raw capture for repeatable algorithm experiments, and browser recordings as an additional quality reference.
