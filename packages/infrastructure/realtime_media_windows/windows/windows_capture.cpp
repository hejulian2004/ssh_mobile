#include "windows_capture.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/base.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <optional>
#include <string_view>
#include <unordered_map>
#include <utility>

namespace realtime_media_windows {
namespace {

using winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
using winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
using winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
using winrt::Windows::Graphics::DirectX::DirectXPixelFormat;
using winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;

constexpr int kFramePoolBufferCount = 3;

struct NativeSource {
  CaptureSourceDescriptor descriptor;
  HMONITOR monitor = nullptr;
  HWND window = nullptr;
};

std::string Utf8FromWide(const wchar_t* value, int length) {
  if (value == nullptr || length <= 0) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value,
                                       length, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<size_t>(size), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, length,
                          result.data(), size, nullptr, nullptr) != size) {
    return {};
  }
  if (result.size() > 128) result.resize(128);
  return result;
}

bool IsLiveMonitor(HMONITOR monitor) {
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  return monitor != nullptr && GetMonitorInfoW(monitor, &info) != FALSE;
}

bool IsLiveWindow(HWND window) {
  return window != nullptr && IsWindow(window) != FALSE &&
         IsWindowVisible(window) != FALSE && IsIconic(window) == FALSE;
}

struct CaptureState final {
  uint64_t owner = 0;
  std::atomic<bool> stopped{false};
  std::atomic<bool> teardown_started{false};
  std::atomic<bool> source_ended{false};
  std::atomic<uint64_t> frames_captured{0};
  std::atomic<uint64_t> frames_dropped{0};
  std::atomic<int> width{0};
  std::atomic<int> height{0};

  IDirect3DDevice device{nullptr};
  GraphicsCaptureItem item{nullptr};
  Direct3D11CaptureFramePool frame_pool{nullptr};
  GraphicsCaptureSession session{nullptr};
  winrt::event_token frame_arrived_token{};
  winrt::event_token closed_token{};

  void Stop() {
    stopped.store(true);
    if (teardown_started.exchange(true)) return;
    try {
      if (frame_pool != nullptr && frame_arrived_token.value != 0) {
        frame_pool.FrameArrived(frame_arrived_token);
        frame_arrived_token = {};
      }
      if (item != nullptr && closed_token.value != 0) {
        item.Closed(closed_token);
        closed_token = {};
      }
      if (session != nullptr) session.Close();
      if (frame_pool != nullptr) frame_pool.Close();
      session = nullptr;
      frame_pool = nullptr;
      item = nullptr;
    } catch (...) {
      // Teardown is idempotent and cannot allow a platform callback to escape
      // into the Flutter method-channel thread.
      session = nullptr;
      frame_pool = nullptr;
      item = nullptr;
    }
  }
};

}  // namespace

struct WindowsCaptureManager::Impl final {
  std::mutex mutex;
  std::vector<NativeSource> sources;
  std::unordered_map<uint64_t, std::shared_ptr<CaptureState>> captures;
  winrt::com_ptr<ID3D11Device> d3d_device;
  winrt::com_ptr<ID3D11DeviceContext> d3d_context;
  IDirect3DDevice winrt_device{nullptr};
  bool com_initialized = false;

  Impl() {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    com_initialized = com_result == S_OK || com_result == S_FALSE;
  }

  ~Impl() {
    std::vector<std::shared_ptr<CaptureState>> captures_to_stop;
    {
      std::lock_guard<std::mutex> lock(mutex);
      for (auto& entry : captures) captures_to_stop.push_back(entry.second);
      captures.clear();
      sources.clear();
    }
    for (const auto& capture : captures_to_stop) capture->Stop();
    winrt_device = nullptr;
    d3d_context = nullptr;
    d3d_device = nullptr;
    if (com_initialized) CoUninitialize();
  }

  bool EnsureDevice() {
    if (winrt_device != nullptr) return true;
    constexpr D3D_FEATURE_LEVEL kFeatureLevels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
    };
    D3D_FEATURE_LEVEL feature_level = D3D_FEATURE_LEVEL_11_0;
    const HRESULT device_result = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        kFeatureLevels, ARRAYSIZE(kFeatureLevels), D3D11_SDK_VERSION,
        d3d_device.put(), &feature_level, d3d_context.put());
    if (FAILED(device_result) || d3d_device == nullptr) return false;

    winrt::com_ptr<IDXGIDevice> dxgi_device;
    if (FAILED(d3d_device->QueryInterface(IID_PPV_ARGS(dxgi_device.put())))) {
      d3d_device = nullptr;
      d3d_context = nullptr;
      return false;
    }
    winrt::com_ptr<IInspectable> inspectable_device;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(
            dxgi_device.get(), inspectable_device.put()))) {
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

  static std::optional<GraphicsCaptureItem> CreateCaptureItem(
      const NativeSource& source) {
    try {
      auto interop = winrt::get_activation_factory<
          GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
      GraphicsCaptureItem item{nullptr};
      const auto iid = winrt::guid_of<GraphicsCaptureItem>();
      HRESULT result = E_INVALIDARG;
      if (source.descriptor.kind == "display") {
        result = interop->CreateForMonitor(source.monitor, iid,
                                           winrt::put_abi(item));
      } else if (source.descriptor.kind == "window") {
        result = interop->CreateForWindow(source.window, iid,
                                          winrt::put_abi(item));
      }
      if (FAILED(result) || item == nullptr) return std::nullopt;
      return item;
    } catch (...) {
      return std::nullopt;
    }
  }

  std::optional<NativeSource> FindSource(const std::string& source_id) {
    const auto source = std::find_if(
        sources.begin(), sources.end(), [&](const NativeSource& candidate) {
          return candidate.descriptor.id == source_id;
        });
    if (source == sources.end()) return std::nullopt;
    if ((source->descriptor.kind == "display" && !IsLiveMonitor(source->monitor)) ||
        (source->descriptor.kind == "window" && !IsLiveWindow(source->window))) {
      return std::nullopt;
    }
    return *source;
  }
};

WindowsCaptureManager::WindowsCaptureManager() : impl_(std::make_unique<Impl>()) {}

WindowsCaptureManager::~WindowsCaptureManager() = default;

bool WindowsCaptureManager::EnumerateSources(
    std::vector<CaptureSourceDescriptor>* output) {
  if (output == nullptr) return false;
  std::vector<NativeSource> sources;
  struct MonitorContext {
    std::vector<NativeSource>* sources;
    int ordinal = 0;
  } monitor_context{&sources};
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT rect, LPARAM data) -> BOOL {
        auto* context = reinterpret_cast<MonitorContext*>(data);
        NativeSource source;
        const int ordinal = context->ordinal++;
        source.descriptor.id = "display:" + std::to_string(ordinal);
        source.descriptor.kind = "display";
        source.descriptor.label = "Display " + std::to_string(ordinal + 1);
        source.descriptor.width = rect->right - rect->left;
        source.descriptor.height = rect->bottom - rect->top;
        source.monitor = monitor;
        context->sources->push_back(std::move(source));
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&monitor_context));

  struct WindowContext {
    std::vector<NativeSource>* sources;
    int ordinal = 0;
  } window_context{&sources};
  EnumWindows(
      [](HWND window, LPARAM data) -> BOOL {
        auto* context = reinterpret_cast<WindowContext*>(data);
        if (!IsLiveWindow(window)) return TRUE;
        wchar_t title[256] = {};
        const int length = GetWindowTextW(window, title, ARRAYSIZE(title));
        if (length <= 0) return TRUE;
        NativeSource source;
        const int ordinal = context->ordinal++;
        source.descriptor.id = "window:" + std::to_string(ordinal);
        source.descriptor.kind = "window";
        source.descriptor.label = Utf8FromWide(title, length);
        if (source.descriptor.label.empty()) {
          source.descriptor.label = "Window " + std::to_string(ordinal + 1);
        }
        RECT client = {};
        if (GetClientRect(window, &client) != FALSE) {
          source.descriptor.width = client.right - client.left;
          source.descriptor.height = client.bottom - client.top;
        }
        source.window = window;
        context->sources->push_back(std::move(source));
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&window_context));

  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->sources = std::move(sources);
    output->clear();
    output->reserve(impl_->sources.size());
    for (const auto& source : impl_->sources) {
      output->push_back(source.descriptor);
    }
  }
  return true;
}

CaptureStatus WindowsCaptureManager::Start(uint64_t owner,
                                           const std::string& source_id) {
  if (owner == 0 || source_id.empty()) return CaptureStatus::kBackendFailure;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  if (impl_->captures.find(owner) != impl_->captures.end()) {
    return CaptureStatus::kDuplicate;
  }
  if (!GraphicsCaptureSession::IsSupported() || !impl_->EnsureDevice()) {
    return CaptureStatus::kUnsupported;
  }
  const auto source = impl_->FindSource(source_id);
  if (!source) return CaptureStatus::kSourceEnded;
  const auto item = Impl::CreateCaptureItem(*source);
  if (!item) return CaptureStatus::kBackendFailure;

  try {
    const auto size = item->Size();
    auto frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        impl_->winrt_device, DirectXPixelFormat::B8G8R8A8UIntNormalized,
        kFramePoolBufferCount, size);
    auto session = frame_pool.CreateCaptureSession(*item);
    session.IsCursorCaptureEnabled(false);
    session.IsBorderRequired(false);

    auto state = std::make_shared<CaptureState>();
    state->owner = owner;
    state->device = impl_->winrt_device;
    state->item = *item;
    state->frame_pool = frame_pool;
    state->session = session;
    state->width.store(size.Width);
    state->height.store(size.Height);
    std::weak_ptr<CaptureState> weak_state = state;
    state->frame_arrived_token = frame_pool.FrameArrived(
        [weak_state](Direct3D11CaptureFramePool const& pool,
                     winrt::Windows::Foundation::IInspectable const&) {
          const auto state = weak_state.lock();
          if (!state || state->stopped.load()) return;
          try {
            while (!state->stopped.load()) {
              auto frame = pool.TryGetNextFrame();
              if (frame == nullptr) break;
              const auto content_size = frame.ContentSize();
              const auto old_width = state->width.load();
              const auto old_height = state->height.load();
              if ((content_size.Width != old_width ||
                   content_size.Height != old_height) &&
                  state->device != nullptr) {
                try {
                  pool.Recreate(state->device,
                                DirectXPixelFormat::B8G8R8A8UIntNormalized,
                                kFramePoolBufferCount, content_size);
                } catch (...) {
                  state->frames_dropped.fetch_add(1);
                  state->source_ended.store(true);
                  state->stopped.store(true);
                  break;
                }
              }
              state->width.store(content_size.Width);
              state->height.store(content_size.Height);
              state->frames_captured.fetch_add(1);
            }
          } catch (...) {
            state->frames_dropped.fetch_add(1);
            state->source_ended.store(true);
            state->stopped.store(true);
          }
        });
    state->closed_token = item->Closed(
        [weak_state](GraphicsCaptureItem const&,
                     winrt::Windows::Foundation::IInspectable const&) {
          const auto state = weak_state.lock();
          if (!state) return;
          state->source_ended.store(true);
          state->stopped.store(true);
        });
    session.StartCapture();
    impl_->captures.emplace(owner, std::move(state));
    return CaptureStatus::kOk;
  } catch (...) {
    return CaptureStatus::kBackendFailure;
  }
}

CaptureStatus WindowsCaptureManager::Stop(uint64_t owner) {
  std::shared_ptr<CaptureState> capture;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto it = impl_->captures.find(owner);
    if (it == impl_->captures.end()) return CaptureStatus::kOk;
    capture = it->second;
  }
  capture->Stop();
  return capture->source_ended.load() ? CaptureStatus::kSourceEnded
                                      : CaptureStatus::kOk;
}

CaptureStatus WindowsCaptureManager::Release(uint64_t owner) {
  std::shared_ptr<CaptureState> capture;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto it = impl_->captures.find(owner);
    if (it == impl_->captures.end()) return CaptureStatus::kOk;
    capture = it->second;
    impl_->captures.erase(it);
  }
  capture->Stop();
  return CaptureStatus::kOk;
}

CaptureStatus WindowsCaptureManager::ReadStats(uint64_t owner,
                                               CaptureStats* stats) {
  if (stats == nullptr) return CaptureStatus::kBackendFailure;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  const auto it = impl_->captures.find(owner);
  if (it == impl_->captures.end()) return CaptureStatus::kNotFound;
  const auto& capture = it->second;
  stats->width = capture->width.load();
  stats->height = capture->height.load();
  stats->frames_captured = capture->frames_captured.load();
  stats->frames_dropped = capture->frames_dropped.load();
  stats->source_ended = capture->source_ended.load();
  return stats->source_ended ? CaptureStatus::kSourceEnded : CaptureStatus::kOk;
}

}  // namespace realtime_media_windows
