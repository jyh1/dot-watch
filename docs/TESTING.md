# Validation and troubleshooting

## Release preparation, 2026-10-04

- iPhone app, Watch app and widget compile for the simulator with public defaults.
- 21 app tests cover session-account matching, HTTP retry, direct-call lifecycle, foreground widget launch ordering, microphone conversion, call URLs and page input validation.
- 6 DirectRTC tests cover Opus, signaling validation and RTCP CNAME length/padding.
- 4 configuration tests cover public defaults, changing back from private configuration, unknown fields, malformed values and relative asset paths.
- A 30-second Watch simulator call completed with 1,529 outgoing packets and 1,344 incoming packets. The local peer decoded the audio, measured mute/unmute and observed cleanup.

The call fixture bypasses CallKit and audio hardware. It invokes the App Intent code directly; it does not establish spoken Siri recognition, microphone/speaker quality or locked-device Siri behavior. The earlier personal build's real Watch calls and Smart Stack launch were user-reported working. The configurable package still needs its own physical-device regression check before describing it as a validated hardware release.

## Silent simulator call

Boot paired iPhone and Watch simulators, then run:

```sh
bash Tools/direct-simulator.sh WATCH_SIMULATOR_ID PHONE_SIMULATOR_ID
```

The script generates/builds the app, installs it into the simulator and exchanges encrypted audio with a local aiortc peer using generated PCM. It does not play audio or use a microphone. Python 3.13 is used to create its local virtual environment. Set `DOTWATCH_TEST_PYTHON` to an existing compatible environment to avoid reinstalling dependencies.

Set `DOTWATCH_PROBE_DURATION=90` for a longer call, `DOTWATCH_PROBE_MODE=blackhole` to drop UDP traffic, or `DOTWATCH_PROBE_PLATFORM=phone` for iPhone. Set `DOTWATCH_PROBE_ENTRY=widget` to wait for an actual Smart Stack tap. The widget must be added in the simulator first. `simctl openurl` is not a reliable substitute for a real watchOS widget tap.

Other overrides: `DOTWATCH_WORK_DIR`, `DOTWATCH_BUILD_DIR`, `DOTWATCH_SKIP_BUILD=1`. For a personal configuration also set `DOTWATCH_CONFIG` and `DOTWATCH_BUNDLE_ID` to match the generated app.

## Hardware checklist

Check the installed version on both devices. Test Watch Call, Smart Stack, mute, hang-up, repeated calls, a locked nearby iPhone, expired-login handling, lost connectivity, and spoken Siri from each device. Do not infer these results from simulator transport tests.

## Common issues

- **Watch shows the previous build:** in the iPhone Watch app, turn off “Show App on Apple Watch,” wait for removal, then install it again. Recheck its About screen.
- **Smart Stack fails while Call works:** remove and re-add the widget after updating. This resolved a reported CallKit transaction error 6 on the earlier personal build; the precise cache cause is unconfirmed.
- **Sign-in required:** open the iPhone app and reconnect/refresh the login, then open the Watch app for session sync. A Google login within the embedded browser may need its own authentication; it does not reuse arbitrary Google app or Safari cookies.
- **Slow initial connection:** creating and attaching a service call can take tens of seconds. Timing diagnostics distinguish these requests from local media setup.
- **No connection on a restricted network:** this transport has no TURN/TCP fallback. Test an ordinary internet connection with UDP available.
