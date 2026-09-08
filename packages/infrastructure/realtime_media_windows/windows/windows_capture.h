#ifndef REALTIME_MEDIA_WINDOWS_CAPTURE_H_
#define REALTIME_MEDIA_WINDOWS_CAPTURE_H_

#include <cstdint>
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
  uint64_t frames_dropped = 0;
  bool source_ended = false;
};

enum class CaptureStatus {
  kOk,
  kSourceEnded,
  kUnsupported,
  kDuplicate,
  kNotFound,
  kBackendFailure,
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

  bool EnumerateSources(std::vector<CaptureSourceDescriptor>* sources);
  CaptureStatus Start(uint64_t owner, const std::string& source_id);
  CaptureStatus Stop(uint64_t owner);
  CaptureStatus Release(uint64_t owner);
  CaptureStatus ReadStats(uint64_t owner, CaptureStats* stats);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_CAPTURE_H_
