#include "windows_capture.h"

#include "windows_capture_state.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.h>
#include <unknwn.h>

// C++/WinRT's generated headers are consumed alongside the Windows SDK COM
// headers. Some SDK/Flutter wrapper combinations do not expose the marker
// that tells C++/WinRT to use the SDK GUID/IUnknown types, so make the
// already-included COM ABI explicit before including the projection.
#ifndef WINRT_IMPL_IUNKNOWN_DEFINED
#define WINRT_IMPL_IUNKNOWN_DEFINED
#endif

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

}  // namespace

struct WindowsCaptureManager::Impl final {
  std::mutex mutex;
  std::vector<NativeSource> sources;
  std::unordered_map<uint64_t, std::shared_ptr<CaptureState>> captures;
  winrt::com_ptr<ID3D11Device> d3d_device;
  winrt::com_ptr<ID3D11DeviceContext> d3d_context;
  IDirect3DDevice winrt_device{nullptr};
  std::shared_ptr<std::mutex> encoder_mutex = std::make_shared<std::mutex>();
  H264PushCallback push_h264 = nullptr;
  bool com_initialized = false;
  bool mf_initialized = false;

  Impl() {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    com_initialized = com_result == S_OK || com_result == S_FALSE;
    if (com_initialized) {
      mf_initialized = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
    }
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
    if (mf_initialized) MFShutdown();
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
      // The WinRT projection's guid type is not ABI-identical to the SDK's
      // REFIID on all MSVC/Windows SDK combinations. Use the ABI default
      // interface directly so the GraphicsCapture interop call remains
      // portable across the supported toolchains.
      const IID iid =
          __uuidof(ABI::Windows::Graphics::Capture::IGraphicsCaptureItem);
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

void WindowsCaptureManager::SetPushCallback(H264PushCallback callback) {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->push_h264 = callback;
}

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
  if (impl_->push_h264 == nullptr || !impl_->mf_initialized) {
    return CaptureStatus::kBackendFailure;
  }
  if (!GraphicsCaptureSession::IsSupported() || !impl_->EnsureDevice()) {
    return CaptureStatus::kUnsupported;
  }
  const auto source = impl_->FindSource(source_id);
  if (!source) return CaptureStatus::kSourceEnded;
  const auto item = Impl::CreateCaptureItem(*source);
  if (!item) return CaptureStatus::kBackendFailure;

  try {
    auto encoder = HardwareH264Encoder::Create(impl_->d3d_device.get(),
                                                impl_->d3d_context.get());
    if (encoder == nullptr) return CaptureStatus::kEncoderUnavailable;
    const auto size = item->Size();
    auto frame_pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        impl_->winrt_device, DirectXPixelFormat::B8G8R8A8UIntNormalized,
        kFramePoolBufferCount, size);
    auto session = frame_pool.CreateCaptureSession(*item);
    session.IsCursorCaptureEnabled(false);
    session.IsBorderRequired(false);

    auto state = std::make_shared<CaptureState>();
    state->owner = owner;
    state->push_h264 = impl_->push_h264;
    state->encoder_mutex = impl_->encoder_mutex;
    state->encoder = std::move(encoder);
    state->started_at = std::chrono::steady_clock::now();
    state->device = impl_->winrt_device;
    state->item = *item;
    state->frame_pool = frame_pool;
    state->session = session;
    state->width.store(size.Width);
    state->height.store(size.Height);
    InstallCaptureCallbacks(state);
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
  stats->frames_sent = capture->frames_sent.load();
  stats->frames_dropped = capture->frames_dropped.load();
  stats->source_ended = capture->source_ended.load();
  stats->terminal_status = capture->terminal_status.load();
  if (stats->terminal_status != 0) return CaptureStatus::kNativeFailure;
  return stats->source_ended ? CaptureStatus::kSourceEnded : CaptureStatus::kOk;
}

}  // namespace realtime_media_windows
