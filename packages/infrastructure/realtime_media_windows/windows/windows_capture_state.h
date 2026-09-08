#ifndef REALTIME_MEDIA_WINDOWS_CAPTURE_STATE_H_
#define REALTIME_MEDIA_WINDOWS_CAPTURE_STATE_H_

#include "windows_capture.h"
#include "windows_h264_encoder.h"

#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>

namespace realtime_media_windows {

using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;

struct CaptureState final {
  uint64_t owner = 0;
  H264PushCallback push_h264 = nullptr;
  std::shared_ptr<std::mutex> encoder_mutex;
  std::unique_ptr<HardwareH264Encoder> encoder;
  std::chrono::steady_clock::time_point started_at;
  std::atomic<bool> stopped{false};
  std::atomic<bool> teardown_started{false};
  std::atomic<bool> source_ended{false};
  std::atomic<uint64_t> frames_captured{0};
  std::atomic<uint64_t> frames_sent{0};
  std::atomic<uint64_t> frames_dropped{0};
  std::atomic<uint64_t> sequence{0};
  std::atomic<int> terminal_status{0};
  std::atomic<int> width{0};
  std::atomic<int> height{0};

  IDirect3DDevice device{nullptr};
  GraphicsCaptureItem item{nullptr};
  Direct3D11CaptureFramePool frame_pool{nullptr};
  GraphicsCaptureSession session{nullptr};
  winrt::event_token frame_arrived_token{};
  winrt::event_token closed_token{};

  void Stop();
};

// Installs the native FrameArrived/Closed callbacks after all capture resources
// have been assigned to the state. The callback owns the capture→encode→push
// hot path and never posts frame bytes to Dart.
void InstallCaptureCallbacks(const std::shared_ptr<CaptureState>& state);

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_CAPTURE_STATE_H_
