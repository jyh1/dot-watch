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

## Native incoming-audio receiver

`Tools/build-neteq.sh` builds the local NetEq XCFramework from pinned upstream sources:

| Project | Revision | License |
| --- | --- | --- |
| [WebRTC](https://webrtc.googlesource.com/src/+/ddd3e1dc172f322356ca91cb764d57c7b81ed282) | `ddd3e1dc172f322356ca91cb764d57c7b81ed282` | BSD-style license and additional patent grant; retain included third-party notices |
| [Opus](https://github.com/xiph/opus/tree/v1.6.1) | `v1.6.1` | BSD-style license and accompanying patent grants |
| [Abseil](https://github.com/abseil/abseil-cpp/tree/20260107.1) | `20260107.1` | Apache-2.0 |

The app calls the genuine NetEq receiver and upstream Opus decoder through a small first-party C interface. [License and patent notices](DirectRTC/Native/licenses) remain separate from the app's MIT license and are included in both device app bundles. See the [native build provenance](DirectRTC/NETEQ_BUILD.md). Generated libraries and dependency caches are local build artifacts; conversation recordings are never build inputs.
