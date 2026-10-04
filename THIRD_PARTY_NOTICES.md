# Third-party code and licensing

The root MIT license applies to first-party app code, tools and default waveform artwork. It does not relicense third-party code.

## Vendored source

`DirectRTC/Vendor/WatchRTC/Sources/WatchRTC` is adapted from [1amageek/swift-webrtc](https://github.com/1amageek/swift-webrtc/tree/f35ac95e4e743b1fb6be50c184e7d3691ef7ddb1), version 3.0.0, commit `f35ac95e4e743b1fb6be50c184e7d3691ef7ddb1`. Attribution: 1amageek and upstream contributors. The [README at that revision](https://github.com/1amageek/swift-webrtc/blob/f35ac95e4e743b1fb6be50c184e7d3691ef7ddb1/README.md#license) declares MIT. No separate LICENSE file or copyright notice was found at that revision. The original source headers are retained. See its [provenance](DirectRTC/Vendor/WatchRTC/PROVENANCE.md) for local modifications. Upstream should supply complete license/copyright text for an unambiguous redistribution record.

## Dependencies fetched by Swift Package Manager

| Project | Version | Observed license declaration |
| --- | --- | --- |
| [swift-networking](https://github.com/1amageek/swift-networking/tree/0.1.0) | 0.1.0 | No license file or README license declaration found at this tag; unresolved |
| [swift-tls](https://github.com/1amageek/swift-tls/tree/2.1.0) | 2.1.0 | README declares MIT; no separate license file found |
| [swift-ssl](https://github.com/1amageek/swift-ssl/blob/0.4.0/LICENSE) | 0.4.0 | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log/blob/1.15.1/LICENSE.txt) | 1.15.1 | Apache-2.0 |

Checked 2026-10-04. Dependency checkouts and compiled binaries are not included in the source package. Their absence from this package does not resolve downstream binary redistribution obligations. Confirm the unresolved licensing with upstream before distributing a compiled app.

Local test tooling optionally installs aiortc 1.15.0 and NumPy 2.5.3 in a virtual environment. They and their dependencies are not bundled with the application or this source distribution.
