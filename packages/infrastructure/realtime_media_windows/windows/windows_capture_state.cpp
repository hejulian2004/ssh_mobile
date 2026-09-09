#include "windows_capture_state.h"

#include <d3d11.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <algorithm>
#include <chrono>
#include <vector>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

namespace realtime_media_windows {

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
        state->EnterCallback();
        struct CallbackExit final {
          std::shared_ptr<CaptureState> state;
          ~CallbackExit() { state->ExitCallback(); }
        } callback_exit{state};
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
            winrt::com_ptr<
                ::Windows::Graphics::DirectX::Direct3D11::
                    IDirect3DDxgiInterfaceAccess>
                access;
            winrt::check_hresult(winrt::get_unknown(surface)->QueryInterface(
                IID_PPV_ARGS(access.put())));
            winrt::com_ptr<ID3D11Texture2D> texture;
            winrt::check_hresult(
                access->GetInterface(IID_PPV_ARGS(texture.put())));
            std::vector<EncodedAccessUnit> access_units;
            const auto elapsed = std::chrono::steady_clock::now() -
                                 state->started_at;
            const auto elapsed_ns =
                std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed)
                    .count();
            const uint64_t timestamp_90khz =
                elapsed_ns <= 0
                    ? 0
                    : static_cast<uint64_t>(elapsed_ns) * 90'000ULL /
                          1'000'000'000ULL;
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
              std::lock_guard<std::mutex> encode_lock(state->encoder_mutex);
              if (!state->stopped.load() && state->encoder != nullptr) {
                encoded = state->encoder->Encode(texture.get(), timestamp_90khz,
                                                 &access_units);
              }
            }
            if (!encoded) {
              if (state->stopped.load()) break;
              state->frames_dropped.fetch_add(1);
              state->terminal_status.store(kCaptureTerminalEncoderFailed);
              state->stopped.store(true);
              break;
            }
            for (const auto& access_unit : access_units) {
              if (state->stopped.load()) break;
              NativeH264FrameMetadata metadata;
              metadata.sequence = state->sequence.fetch_add(1);
              metadata.timestamp = timestamp_90khz;
              metadata.width = static_cast<uint32_t>(content_size.Width);
              metadata.height = static_cast<uint32_t>(content_size.Height);
              metadata.keyframe = access_unit.keyframe ? 1 : 0;
              const int push_status = state->push_h264(
                  state->owner, metadata, access_unit.payload.data(),
                  access_unit.payload.size());
              if (push_status == 0) {
                state->frames_sent.fetch_add(1);
              } else if (push_status == 1) {
                // The native queue owns queue-drop accounting. Counting this
                // status here would make the platform/native merge report the
                // same dropped access unit twice.
                continue;
              } else {
                state->frames_dropped.fetch_add(1);
                state->terminal_status.store(push_status);
                state->stopped.store(true);
                break;
              }
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
        state->EnterCallback();
        struct CallbackExit final {
          std::shared_ptr<CaptureState> state;
          ~CallbackExit() { state->ExitCallback(); }
        } callback_exit{state};
        state->source_ended.store(true);
        state->stopped.store(true);
      });
}

}  // namespace realtime_media_windows
