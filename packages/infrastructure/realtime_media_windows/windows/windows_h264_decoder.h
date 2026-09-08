#ifndef REALTIME_MEDIA_WINDOWS_H264_DECODER_H_
#define REALTIME_MEDIA_WINDOWS_H264_DECODER_H_

#include "windows_capture.h"

#include <cstddef>
#include <cstdint>
#include <memory>

namespace flutter {
class TextureRegistrar;
}

namespace realtime_media_windows {

// The Rust owner pull ABI returns an owned buffer which must be released with
// the matching native callback after the decoder copies/consumes it. Neither
// the buffer nor its address crosses the Flutter method channel.
struct NativeH264Buffer {
  uint8_t* ptr = nullptr;
  size_t len = 0;
};

using H264PullCallback = int(__cdecl *)(uint64_t owner,
                                         NativeH264FrameMetadata* metadata,
                                         NativeH264Buffer* payload);
using H264BufferFreeCallback = void(__cdecl *)(NativeH264Buffer payload);

struct DecoderStats {
  int width = 0;
  int height = 0;
  uint64_t frames_decoded = 0;
  uint64_t frames_rendered = 0;
  uint64_t frames_dropped = 0;
  int terminal_status = 0;
};

enum class DecoderStatus {
  kOk,
  kNotFound,
  kDuplicate,
  kDecoderUnavailable,
  kDecoderFailed,
  kNativeFailure,
  kBackendFailure,
};

// Owns the receive-side hardware decoder worker and Flutter GPU texture
// registration. The class exposes only an opaque texture ID and payload-free
// counters to the method-channel adapter.
class WindowsDecoderManager final {
 public:
  explicit WindowsDecoderManager(flutter::TextureRegistrar* texture_registrar);
  ~WindowsDecoderManager();

  WindowsDecoderManager(const WindowsDecoderManager&) = delete;
  WindowsDecoderManager& operator=(const WindowsDecoderManager&) = delete;

  void SetNativeCallbacks(H264PullCallback pull_callback,
                          H264BufferFreeCallback free_callback);

  DecoderStatus Attach(uint64_t owner, int64_t* surface_id);
  DecoderStatus Detach(uint64_t owner);
  DecoderStatus Release(uint64_t owner);
  DecoderStatus ReadStats(uint64_t owner, DecoderStats* stats);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

// Internal terminal value used when a native hardware decoder or GPU output
// surface fails before a Phase 2 status code exists.
constexpr int kDecoderTerminalFailed = -1003;

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_H264_DECODER_H_
