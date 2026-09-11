#ifndef REALTIME_MEDIA_WINDOWS_CAPTURE_H_
#define REALTIME_MEDIA_WINDOWS_CAPTURE_H_

#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace realtime_media_windows {

// These descriptors deliberately contain no HWND/HMONITOR or graphics
// resource. The native implementation keeps those handles behind this
// translation unit and only returns bounded UI metadata to the platform
// channel.
struct CaptureSourceDescriptor {
  std::string id;
  std::string kind;
  std::string label;
  int width = 0;
  int height = 0;
};

struct CaptureStats {
  int width = 0;
  int height = 0;
  uint64_t frames_captured = 0;
  uint64_t frames_sent = 0;
  uint64_t frames_dropped = 0;
  bool source_ended = false;
  // Zero means that no terminal encoder/native push failure was observed.
  // Negative values are the Phase 2 native status code; the internal sentinel
  // value declared below represents a platform-owned encoder failure.
  int terminal_status = 0;
};

// This layout must remain identical to the native-only
// SshNetRealtimeMediaFrameMetadata #[repr(C)] type. It is intentionally not
// exposed through the Flutter method channel.
struct NativeH264FrameMetadata {
  uint64_t sequence = 0;
  uint64_t timestamp = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint8_t keyframe = 0;
};

using H264PushCallback = int(__cdecl *)(uint64_t owner,
                                         NativeH264FrameMetadata metadata,
                                         const uint8_t* payload,
                                         size_t payload_length);

static_assert(sizeof(NativeH264FrameMetadata) == 32,
              "Windows and Rust H.264 metadata layouts must stay ABI-identical");

// Internal terminal values used when a platform encoder fails before a Phase
// 2 status code exists. They never cross Dart; the plugin maps them to typed
// encoder errors when a low-frequency stats read observes the failure.
constexpr int kCaptureTerminalEncoderFailed = -1001;
constexpr int kCaptureTerminalResolutionChanged = -1002;
constexpr int kCaptureTerminalRecreateRequired = -1003;

enum class CaptureStatus {
  kOk,
  kSourceEnded,
  kUnsupported,
  kDuplicate,
  kNotFound,
  kBackendFailure,
  kEncoderUnavailable,
  kEncoderFailed,
  kRecreateRequired,
  kNativeFailure,
};

// Owns Windows Graphics Capture objects and frame callbacks. The class is
// intentionally independent from the network endpoint ABI: callers provide
// only the opaque owner ID and receive no frame data or graphics pointer.
class WindowsCaptureManager final {
 public:
  WindowsCaptureManager();
  ~WindowsCaptureManager();

  WindowsCaptureManager(const WindowsCaptureManager&) = delete;
  WindowsCaptureManager& operator=(const WindowsCaptureManager&) = delete;

  void SetPushCallback(H264PushCallback callback);
  bool EnumerateSources(std::vector<CaptureSourceDescriptor>* sources);
  CaptureStatus Start(uint64_t owner,
                      const std::string& source_id,
                      const std::string& source_kind);
  CaptureStatus Stop(uint64_t owner);
  CaptureStatus Release(uint64_t owner);
  CaptureStatus ApplyAdaptation(uint64_t owner,
                                uint32_t bitrate_kbps,
                                uint32_t framerate,
                                uint32_t width,
                                uint32_t height);
  CaptureStatus CurrentAdaptation(uint64_t owner,
                                  uint32_t* bitrate_kbps,
                                  uint32_t* framerate);
  CaptureStatus RestoreAdaptation(uint64_t owner,
                                  uint32_t bitrate_kbps,
                                  uint32_t framerate);
  void MarkAdaptationRecreateRequired(uint64_t owner);
  CaptureStatus RequestKeyframe(uint64_t owner);
  CaptureStatus ReadStats(uint64_t owner, CaptureStats* stats);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_CAPTURE_H_
