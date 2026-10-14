#include "windows_capture_state.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/base.h>

#include <algorithm>
#include <chrono>
#include <vector>

namespace realtime_media_windows {
namespace {
constexpr uint64_t kIdleFrameInterval = 18'000;  // Five frames per second.
uint64_t CaptureTimestamp(const CaptureState& state) {
  const auto elapsed = std::chrono::steady_clock::now() - state.started_at;
  const auto ns =
      std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count();
  return ns <= 0 ? 0 : static_cast<uint64_t>(ns) * 90'000ULL / 1'000'000'000ULL;
}
struct CallbackExit final {
  std::shared_ptr<CaptureState> state;
  explicit CallbackExit(std::shared_ptr<CaptureState> value)
      : state(std::move(value)) {
    state->EnterCallback();
  }
  ~CallbackExit() { state->ExitCallback(); }
};
// Caller holds encoder_mutex through encoding and pushing so a timer cannot
// interleave a newer access unit with an actual capture callback.
void PushAccessUnits(const std::shared_ptr<CaptureState>& state,
                     uint64_t timestamp_90khz,
                     const std::vector<EncodedAccessUnit>& access_units) {
  for (const auto& access_unit : access_units) {
    if (state->stopped.load()) break;
    NativeH264FrameMetadata metadata;
    metadata.sequence = state->sequence.fetch_add(1);
    metadata.timestamp = timestamp_90khz;
    metadata.width = access_unit.width;
    metadata.height = access_unit.height;
    metadata.keyframe = access_unit.keyframe ? 1 : 0;
    const int push_status =
        state->push_h264(state->owner, metadata, access_unit.payload.data(),
                         access_unit.payload.size());
    if (push_status == 0) {
      state->frames_sent.fetch_add(1);
    } else if (push_status == 1) {
      // The native queue owns queue-drop accounting. Counting this
      // status here would make the platform/native merge report the
      // same dropped access unit twice.
      auto next_recovery = state->next_recovery_timestamp.load();
      if (timestamp_90khz >= next_recovery &&
          state->next_recovery_timestamp.compare_exchange_strong(
              next_recovery, timestamp_90khz + 90'000ULL)) {
        if (!state->stopped.load() && state->encoder != nullptr &&
            !state->encoder->RequestKeyframe()) {
          state->terminal_status.store(kCaptureTerminalEncoderFailed);
          state->stopped.store(true);
          break;
        }
      }
      continue;
    } else {
      state->frames_dropped.fetch_add(1);
      state->terminal_status.store(push_status);
      state->stopped.store(true);
      break;
    }
  }
}
}  // namespace

bool EnsureCaptureGraphicsDevice(NativeCodecMode mode,
                                 CaptureGraphicsDevice* graphics) {
  auto& d3d_device = graphics->d3d_device;
  auto& d3d_context = graphics->d3d_context;
  auto& winrt_device = graphics->winrt_device;
  if (winrt_device != nullptr) return true;
  constexpr D3D_FEATURE_LEVEL kFeatureLevels[] = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
  };
  D3D_FEATURE_LEVEL feature_level = D3D_FEATURE_LEVEL_11_0;
  const HRESULT device_result = D3D11CreateDevice(
      nullptr,
      mode == NativeCodecMode::Cpu ? D3D_DRIVER_TYPE_WARP
                                   : D3D_DRIVER_TYPE_HARDWARE,
      nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, kFeatureLevels,
      ARRAYSIZE(kFeatureLevels), D3D11_SDK_VERSION, d3d_device.put(),
      &feature_level, d3d_context.put());
  if (FAILED(device_result) || d3d_device == nullptr) return false;

  winrt::com_ptr<IDXGIDevice> dxgi_device;
  if (FAILED(d3d_device->QueryInterface(IID_PPV_ARGS(dxgi_device.put())))) {
    d3d_device = nullptr;
    d3d_context = nullptr;
    return false;
  }
  winrt::com_ptr<IInspectable> inspectable_device;
  if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(),
                                                  inspectable_device.put()))) {
    d3d_device = nullptr;
    d3d_context = nullptr;
    return false;
  }
  try {
    winrt_device = inspectable_device.as<IDirect3DDevice>();
  } catch (...) {
    d3d_device = nullptr;
    d3d_context = nullptr;
    return false;
  }
  return winrt_device != nullptr;
}

CaptureState::~CaptureState() {
  if (Stop()) return;
  // A CaptureState can only be destroyed after its callback owner has been
  // removed from the manager. If a bounded foreground teardown timed out,
  // wait here before destroying codec resources so an in-flight callback can
  // never observe a released encoder.
  WaitForCallbacks();
  ReleaseResources();
}

void CaptureState::EnterCallback() {
  std::lock_guard<std::mutex> lock(callback_mutex);
  ++active_callbacks;
}

void CaptureState::ExitCallback() {
  std::lock_guard<std::mutex> lock(callback_mutex);
  if (active_callbacks > 0) --active_callbacks;
  if (active_callbacks == 0) callback_cv.notify_all();
}

bool CaptureState::WaitForCallbacks(std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lock(callback_mutex);
  return callback_cv.wait_for(lock, timeout,
                              [this] { return active_callbacks == 0; });
}

void CaptureState::WaitForCallbacks() {
  std::unique_lock<std::mutex> lock(callback_mutex);
  callback_cv.wait(lock, [this] { return active_callbacks == 0; });
}

bool CaptureState::ReleaseResources() {
  if (resources_released.load()) return true;
  stopped.store(true);
  try {
    if (session != nullptr) session.Close();
    if (frame_pool != nullptr) frame_pool.Close();
    session = nullptr;
    frame_pool = nullptr;
    item = nullptr;
  } catch (...) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(encoder_mutex);
    encoder.reset();
  }
  resources_released.store(true);
  return true;
}

bool CaptureState::Stop() {
  stopped.store(true);
  if (!teardown_started.exchange(true)) {
    try {
      if (idle_frame_timer != nullptr) {
        idle_frame_timer.Cancel();
        idle_frame_timer = nullptr;
      }
      if (frame_pool != nullptr && frame_arrived_token.value != 0) {
        frame_pool.FrameArrived(frame_arrived_token);
        frame_arrived_token = {};
      }
      if (item != nullptr && closed_token.value != 0) {
        item.Closed(closed_token);
        closed_token = {};
      }
    } catch (...) {
      teardown_started.store(false);
      return false;
    }
  }
  if (!WaitForCallbacks(std::chrono::seconds(2))) return false;
  return ReleaseResources();
}

void InstallCaptureCallbacks(const std::shared_ptr<CaptureState>& state) {
  const std::weak_ptr<CaptureState> weak_state = state;
  state->frame_arrived_token = state->frame_pool.FrameArrived(
      [weak_state](Direct3D11CaptureFramePool const& pool,
                   winrt::Windows::Foundation::IInspectable const&) {
        const auto state = weak_state.lock();
        if (!state) return;
        CallbackExit callback_exit{state};
        if (state->stopped.load()) return;
        try {
          while (!state->stopped.load()) {
            auto frame = pool.TryGetNextFrame();
            if (frame == nullptr) break;
            const auto content_size = frame.ContentSize();
            const auto old_width = state->width.load();
            const auto old_height = state->height.load();
            if (content_size.Width != old_width ||
                content_size.Height != old_height) {
              // Resolution changes terminate this owner. The caller must
              // release the endpoint and create a fresh generation-bound
              // owner; no implicit reconfiguration is allowed in Phase 3.
              state->frames_dropped.fetch_add(1);
              state->terminal_status.store(kCaptureTerminalResolutionChanged);
              state->source_ended.store(true);
              state->stopped.store(true);
              break;
            }
            state->width.store(content_size.Width);
            state->height.store(content_size.Height);
            state->frames_captured.fetch_add(1);

            auto surface = frame.Surface();
            winrt::com_ptr<::Windows::Graphics::DirectX::Direct3D11::
                               IDirect3DDxgiInterfaceAccess>
                access;
            winrt::check_hresult(winrt::get_unknown(surface)->QueryInterface(
                IID_PPV_ARGS(access.put())));
            winrt::com_ptr<ID3D11Texture2D> texture;
            winrt::check_hresult(
                access->GetInterface(IID_PPV_ARGS(texture.put())));
            std::lock_guard<std::mutex> encode_lock(state->encoder_mutex);
            if (state->stopped.load() || state->encoder == nullptr) break;
            std::vector<EncodedAccessUnit> access_units;
            const uint64_t timestamp_90khz = CaptureTimestamp(*state);
            const auto target_framerate =
                std::max<uint32_t>(5, state->target_framerate.load());
            const uint64_t frame_interval = 90'000ULL / target_framerate;
            const auto next_encode = state->next_encode_timestamp.load();
            if (timestamp_90khz < next_encode) {
              state->frames_dropped.fetch_add(1);
              continue;
            }
            state->next_encode_timestamp.store(
                timestamp_90khz > UINT64_MAX - frame_interval
                    ? UINT64_MAX
                    : timestamp_90khz + frame_interval);
            bool encoded = false;
            {
              if (!state->stopped.load() && state->encoder != nullptr) {
                encoded = state->encoder->Encode(texture.get(), timestamp_90khz,
                                                 &access_units);
                if (encoded) {
                  state->last_encode_timestamp = timestamp_90khz;
                  PushAccessUnits(state, timestamp_90khz, access_units);
                }
              }
            }
            if (!encoded) {
              if (state->stopped.load()) break;
              state->frames_dropped.fetch_add(1);
              state->terminal_status.store(kCaptureTerminalEncoderFailed);
              state->stopped.store(true);
              break;
            }
          }
        } catch (...) {
          if (!state->stopped.load()) {
            state->frames_dropped.fetch_add(1);
            if (state->terminal_status.load() == 0) {
              state->terminal_status.store(kCaptureTerminalEncoderFailed);
            }
          }
          state->stopped.store(true);
        }
      });
  state->closed_token = state->item.Closed(
      [weak_state](GraphicsCaptureItem const&,
                   winrt::Windows::Foundation::IInspectable const&) {
        const auto state = weak_state.lock();
        if (!state) return;
        CallbackExit callback_exit{state};
        state->source_ended.store(true);
        state->stopped.store(true);
      });
  state->idle_frame_timer =
      winrt::Windows::System::Threading::ThreadPoolTimer::CreatePeriodicTimer(
          [weak_state](auto const&) {
            const auto state = weak_state.lock();
            if (!state) return;
            CallbackExit callback_exit{state};
            if (state->stopped.load()) return;
            try {
              std::lock_guard<std::mutex> encode_lock(state->encoder_mutex);
              if (state->stopped.load() || state->encoder == nullptr) return;
              const uint64_t timestamp = CaptureTimestamp(*state);
              if (timestamp < state->last_encode_timestamp ||
                  timestamp - state->last_encode_timestamp < kIdleFrameInterval)
                return;
              std::vector<EncodedAccessUnit> access_units;
              if (!state->encoder->RepeatFrame(timestamp, &access_units)) {
                state->terminal_status.store(kCaptureTerminalEncoderFailed);
                state->stopped.store(true);
                return;
              }
              state->last_encode_timestamp = timestamp;
              PushAccessUnits(state, timestamp, access_units);
            } catch (...) {
              if (!state->stopped.load()) {
                state->terminal_status.store(kCaptureTerminalEncoderFailed);
                state->stopped.store(true);
              }
            }
          },
          std::chrono::milliseconds(200));
}

}  // namespace realtime_media_windows
