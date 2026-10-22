Last updated: 2026-10-23

# realtime_media_windows

`realtime_media_windows` is the Windows-owned adapter for the public
`realtime_media` endpoint lifecycle. It composes the App Shell's native
endpoint lease backend with a Windows platform owner. The native owner now
implements Windows Graphics Capture for display/window sources, a native Media
Foundation H.264 send-ingress worker, and a receive decoder with native Flutter
Texture ownership. Hardware is the default; explicit CPU mode selects software
H.264 without changing the native media ABI or codec negotiation.

The Dart side deliberately carries no frame bytes, encoded data, native
addresses, or GPU buffers. Its method channel contains only bounded endpoint
identity, source metadata, opaque surface IDs, lifecycle operations, and
low-frequency payload-free statistics. A missing or unsupported native plugin
is a typed failure; it is never treated as a successful software fallback.

The App Shell registers the endpoint with the existing NetworkRuntime through
an opaque, generation-bound native owner token. Windows code may retain that
token for its native capture/codec worker, but it never receives a Dart runtime
pointer; native owner start/stop/renderer attach/detach and the high-frequency
H.264 push/pull port remain entirely native.

The same owner token carries payload-free `requestKeyframe`, `resetDecoder`,
and bounded `applyAdaptation` commands. Native rate limiting and generation
checks apply before a platform owner touches the encoder or decoder. Windows
applies bitrate targets through the selected Media Foundation MFT and bounds
frame-rate in the native capture state; a resolution target that differs from
the source is rejected and requires an explicit stop/release/recreate. PLI and
IDR requests stay on the native WebRTC/codec path and never become Dart bytes.

Release ordering is platform detach/close first, then native endpoint lease
release. The package does not own `NetworkRuntime`, signaling, consent, TURN
credentials, or feature state.

Capture reuses Flutter's existing COM apartment when changing its model is
rejected. It initializes Media Foundation in that apartment and uninitializes
COM only when it acquired its own reference. Selected source tokens stay bound
to the native catalog; capture start validates the original target's liveness.
The hardware encoder follows Media Foundation's asynchronous input/output
events, honors transform-owned output samples, and uses the Baseline H.264
profile advertised by the screen-track SDP. Explicit CPU capture uses a separate
WARP device and synchronous software MFT, without requiring a physical GPU.
Software encoding requests low-latency output rather than buffering a full
look-ahead window before the first frame.
BGRA/RGBA readback replicates at most one edge row/column for odd window sizes,
producing complete NV12 chroma blocks without discarding source pixels. Encoded
access-unit metadata uses that padded size; source-resize detection still uses
the original capture dimensions.
Windows Graphics Capture may emit only one frame for a static window. The
capture owner retains the last real NV12 snapshot and encodes it at a bounded
five frames per second while the source is quiet, with fresh timestamps. This
keeps decoder startup and keyframe recovery working without another source
change. Encoding and native queue ingress share the encoder lock; stop cancels
the timer before waiting for callbacks and releasing the cached frame/codec.
`test/windows/hardware_h264_encoder_probe.cpp` verifies encoding with a fixed
native texture; `--cpu` forces WARP and software encoding. Absent selected
hardware or software capability is a GAP, not a successful fallback.
`--odd` verifies padded NV12 layout, pixels, encoded dimensions, and IDR recovery
for an odd window fixture in either codec mode.
`--repeat` verifies cached-frame encoding and IDR recovery, including an empty
history that produces no access unit. `--export` writes only the fixed synthetic
fixture for the Android codec-output probe; it never captures a user window.

Receive initialization also borrows Flutter's existing COM apartment. Decoder
enumeration includes D3D11-aware H.264 transforms: synchronous MFT registration
does not by itself mean software decoding. The owner verifies the GPU's H.264
NV12 profile, requires the DXGI device-manager handshake, and accepts only GPU
output buffers. Parameter-set output-layout updates retain the negotiated
dimensions; GPU conversion uses the returned surface array slice. Missing GPU
capability remains `decoder_unavailable` in hardware mode. Integrated
GPUs can satisfy this contract; a discrete GPU is not required.
`test/windows/hardware_h264_decoder_probe.cpp` exercises the receive owner with
fixed hardware-encoded fixtures in an existing STA and verifies GPU surface
registration and release. `--cpu` verifies software decoding with hardware
acceleration disabled and native RGBA PixelBufferTexture registration; that
receive path creates no hardware graphics device. `--cropped` verifies visible
dimensions within a padded coded frame. Native buffers stay alive until
Flutter releases its frame lease, including during stop.
Rendering counters advance when Flutter obtains a frame descriptor, not merely
when the worker announces an available texture.
Decoder stop retains the registered callback until Flutter's asynchronous
texture-unregister completion. Releasing an operation cannot invalidate a
callback still reachable by the render thread.

## Current phase boundary

This package now includes the runtime owner-token bridge and a native Windows
Graphics Capture lifecycle owner for monitor/window sources, the native Media
Foundation H.264 send ingress, and the selected hardware or CPU receive
surface owner. Capture buffers, encoded access units, decoded pixels/textures, and
texture handles remain native; source close, resolution-change restart
boundaries, stop, and release are handled without a Dart frame path. Hardware
availability and Windows E2E acceptance remain separate gates; this package
must still fail closed when a platform capability is unavailable or stale.

## Validation

```sh
flutter analyze --no-pub
flutter test --no-pub
```

After building the Full App for Windows, build native probes from the repository
root with CMake and the installed MSVC generator:

```powershell
cmake -S packages/infrastructure/realtime_media_windows/test/windows -B apps/ssh_mobile_full/build/native-probes -A x64
cmake --build apps/ssh_mobile_full/build/native-probes --config Release
./apps/ssh_mobile_full/build/native-probes/Release/encoder_probe.exe --cpu --odd
./apps/ssh_mobile_full/build/native-probes/Release/decoder_probe.exe --cpu --retain-frame --defer-unregister
```

Run without `--cpu` to check hardware encoding, or without `--odd` for the even
fixture.
Add `--repeat` to verify the static-source path.
The decoder probe's `--defer-unregister` keeps Flutter's completion pending and
checks that its callback remains safe after owner release; `--retain-frame`
checks that an outstanding native pixel lease remains valid during stop.
