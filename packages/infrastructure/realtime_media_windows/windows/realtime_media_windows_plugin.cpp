#include "include/realtime_media_windows/realtime_media_windows_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <d3d11.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannelName[] = "ssh_mobile/realtime_media/windows";
constexpr char kBackendFailure[] = "backend_failure";
constexpr char kCaptureSourceEnded[] = "capture_source_ended";
constexpr char kEncoderUnavailable[] = "encoder_unavailable";
constexpr char kDecoderUnavailable[] = "decoder_unavailable";

using OwnerCloseFunction = int(__cdecl*)(uint64_t);
using OwnerStartFunction = int(__cdecl*)(uint64_t);
using OwnerStopFunction = int(__cdecl*)(uint64_t);
using OwnerRendererFunction = int(__cdecl*)(uint64_t);

struct NativeMediaApi {
  OwnerStartFunction start_owner = nullptr;
  OwnerStopFunction stop_owner = nullptr;
  OwnerCloseFunction close_owner = nullptr;
  OwnerRendererFunction attach_renderer = nullptr;
  OwnerRendererFunction detach_renderer = nullptr;

  bool available() const { return close_owner != nullptr; }
  bool lifecycle_available() const {
    return start_owner != nullptr && stop_owner != nullptr &&
           close_owner != nullptr;
  }

  static NativeMediaApi Resolve() {
    NativeMediaApi api;
    const HMODULE module = GetModuleHandleW(L"network_ffi.dll");
    if (module == nullptr) return api;
    api.start_owner = reinterpret_cast<OwnerStartFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_start"));
    api.stop_owner = reinterpret_cast<OwnerStopFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_stop"));
    api.close_owner = reinterpret_cast<OwnerCloseFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_close"));
    api.attach_renderer = reinterpret_cast<OwnerRendererFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_attach_renderer"));
    api.detach_renderer = reinterpret_cast<OwnerRendererFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_detach_renderer"));
    return api;
  }
};

std::optional<std::string> StringArgument(const EncodableMap& arguments,
                                          const char* key) {
  const auto it = arguments.find(EncodableValue(key));
  if (it == arguments.end()) return std::nullopt;
  const auto* value = std::get_if<std::string>(&it->second);
  if (value == nullptr || value->empty() || value->size() > 128) {
    return std::nullopt;
  }
  return *value;
}

std::optional<uint64_t> OwnerIdArgument(const EncodableMap& arguments) {
  const auto token = StringArgument(arguments, "owner_token");
  if (!token) return std::nullopt;
  char* end = nullptr;
  const auto value = std::strtoull(token->c_str(), &end, 10);
  if (end == token->c_str() || *end != '\0' || value == 0) {
    return std::nullopt;
  }
  return value;
}

void ReplyError(const std::unique_ptr<flutter::MethodResult<EncodableValue>>&
                    result,
                const char* code,
                const char* message) {
  result->Error(code, message);
}

const char* NativeStatusCode(int status) {
  switch (status) {
    case -5:
      return "stale_generation";
    case -6:
    case -12:
      return "stale_endpoint";
    case -7:
      return "direction_mismatch";
    case -8:
      return "duplicate_endpoint";
    case -9:
      return "driver_unavailable";
    case -10:
      return "peer_mismatch";
    case -11:
      return "frame_rejected";
    case -4:
      return "session_released";
    case -1:
      return "invalid_argument";
    default:
      return kBackendFailure;
  }
}

struct SourceRecord {
  std::string id;
  std::string kind;
  std::string label;
  int width = 0;
  int height = 0;
  HMONITOR monitor = nullptr;
  HWND window = nullptr;
};

struct OwnerRecord {
  std::string token;
  std::string endpoint_id;
  std::string realtime_id;
  std::string peer_id;
  uint64_t generation = 0;
  std::string direction;
  bool capture_started = false;
  bool surface_attached = false;
};

class RealtimeMediaWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<RealtimeMediaWindowsPlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit RealtimeMediaWindowsPlugin(flutter::PluginRegistrarWindows* registrar)
      : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance())),
        native_media_api_(NativeMediaApi::Resolve()) {
    ProbeHardwareCodecs();
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { HandleMethod(call, std::move(result)); });
  }

  ~RealtimeMediaWindowsPlugin() override {
    std::lock_guard<std::mutex> lock(mutex_);
    owners_.clear();
    sources_.clear();
    MFShutdown();
  }

 private:
  void ProbeHardwareCodecs() {
    if (MFStartup(MF_VERSION, MFSTARTUP_LITE) != S_OK) return;
    hardware_encoder_available_ = HasHardwareTransform(MFT_CATEGORY_VIDEO_ENCODER);
    hardware_decoder_available_ = HasHardwareTransform(MFT_CATEGORY_VIDEO_DECODER);
  }

  static bool HasHardwareTransform(const GUID& category) {
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    const HRESULT hr = MFTEnumEx(category, MFT_ENUM_FLAG_HARDWARE, nullptr,
                                  nullptr, &activates, &count);
    if (FAILED(hr) || activates == nullptr) return false;
    for (UINT32 index = 0; index < count; ++index) {
      if (activates[index] != nullptr) activates[index]->Release();
    }
    CoTaskMemFree(activates);
    return count != 0;
  }

  void HandleMethod(const flutter::MethodCall<EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() == "listSources") {
      result->Success(ListSources());
      return;
    }
    const auto* arguments = std::get_if<EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      ReplyError(result, "invalid_argument", "Windows media arguments are invalid.");
      return;
    }

    if (call.method_name() == "startCapture") {
      StartCapture(*arguments, std::move(result));
    } else if (call.method_name() == "attachRemoteVideoSurface") {
      AttachSurface(*arguments, std::move(result));
    } else if (call.method_name() == "detach") {
      StopOwner(*arguments, std::move(result));
    } else if (call.method_name() == "release") {
      ReleaseOwner(*arguments, std::move(result));
    } else if (call.method_name() == "readStats") {
      ReadStats(*arguments, std::move(result));
    } else {
      result->NotImplemented();
    }
  }

  EncodableList ListSources() {
    std::lock_guard<std::mutex> lock(mutex_);
    sources_.clear();
    EncodableList output;

    struct MonitorContext {
      std::vector<SourceRecord>* sources;
      int ordinal = 0;
    } context{&sources_};
    EnumDisplayMonitors(
        nullptr, nullptr,
        [](HMONITOR monitor, HDC, LPRECT rect, LPARAM data) -> BOOL {
          auto* context = reinterpret_cast<MonitorContext*>(data);
          const int ordinal = context->ordinal++;
          SourceRecord source;
          source.id = "display:" + std::to_string(ordinal);
          source.kind = "display";
          source.label = "Display " + std::to_string(ordinal + 1);
          source.width = rect->right - rect->left;
          source.height = rect->bottom - rect->top;
          source.monitor = monitor;
          context->sources->push_back(std::move(source));
          return TRUE;
        },
        reinterpret_cast<LPARAM>(&context));

    std::pair<RealtimeMediaWindowsPlugin*, int> window_context{this, 0};
    EnumWindows(
        [](HWND window, LPARAM data) -> BOOL {
          auto* context = reinterpret_cast<std::pair<RealtimeMediaWindowsPlugin*, int>*>(data);
          if (!IsWindowVisible(window) || IsIconic(window)) return TRUE;
          wchar_t title[256] = {};
          const int length = GetWindowTextW(window, title, 256);
          if (length <= 0) return TRUE;
          const int ordinal = (*context).second++;
          SourceRecord source;
          source.id = "window:" + std::to_string(ordinal);
          source.kind = "window";
          source.label = "Window " + std::to_string(ordinal + 1);
          source.window = window;
          RECT client = {};
          if (GetClientRect(window, &client) != FALSE) {
            source.width = client.right - client.left;
            source.height = client.bottom - client.top;
          }
          context->first->sources_.push_back(std::move(source));
          return TRUE;
        },
        reinterpret_cast<LPARAM>(&window_context));

    for (const auto& source : sources_) {
      EncodableMap item;
      item[EncodableValue("id")] = EncodableValue(source.id);
      item[EncodableValue("kind")] = EncodableValue(source.kind);
      item[EncodableValue("label")] = EncodableValue(source.label);
      if (source.width > 0) item[EncodableValue("width")] = EncodableValue(source.width);
      if (source.height > 0) item[EncodableValue("height")] = EncodableValue(source.height);
      output.emplace_back(std::move(item));
    }
    return output;
  }

  void StartCapture(const EncodableMap& arguments,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto endpoint = StringArgument(arguments, "endpoint_id");
    const auto source = StringArgument(arguments, "source_id");
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !endpoint || !source || !direction) {
      ReplyError(result, "invalid_argument", "A native owner and source are required.");
      return;
    }
    if (*direction != "send") {
      ReplyError(result, "direction_mismatch",
                 "Capture requires a send media owner.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!native_media_api_.available()) {
      native_media_api_ = NativeMediaApi::Resolve();
    }
    const auto source_it = std::find_if(sources_.begin(), sources_.end(),
                                        [&](const SourceRecord& item) { return item.id == *source; });
    if (source_it == sources_.end()) {
      ReplyError(result, kCaptureSourceEnded, "The selected Windows source is no longer available.");
      return;
    }
    if ((source_it->kind == "window" &&
         (source_it->window == nullptr || !IsWindow(source_it->window) ||
          !IsWindowVisible(source_it->window))) ||
        (source_it->kind == "display" && [&]() {
          if (source_it->monitor == nullptr) return true;
          MONITORINFO monitor_info = {};
          monitor_info.cbSize = sizeof(monitor_info);
          return GetMonitorInfoW(source_it->monitor, &monitor_info) == FALSE;
        }())) {
      ReplyError(result, kCaptureSourceEnded,
                 "The selected Windows source is no longer available.");
      return;
    }
    if (!hardware_encoder_available_) {
      ReplyError(result, kEncoderUnavailable,
                 "A hardware Media Foundation H.264 encoder is unavailable.");
      return;
    }
    if (!native_media_api_.lifecycle_available()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner lifecycle is unavailable.");
      return;
    }
    const auto start_status = native_media_api_.start_owner(*owner_id);
    if (start_status != 0) {
      ReplyError(result, NativeStatusCode(start_status),
                 "The native media owner could not be started.");
      return;
    }
    // The owner/capture pipeline is intentionally fail-closed until the
    // Graphics Capture + Media Foundation worker is constructed. Reporting
    // success here would violate the native-owner contract and leak a live
    // endpoint, so the current capability gate is explicit.
    const auto stop_status = native_media_api_.stop_owner(*owner_id);
    if (stop_status != 0 && stop_status != -12) {
      ReplyError(result, NativeStatusCode(stop_status),
                 "The native media owner could not be stopped.");
      return;
    }
    ReplyError(result, kBackendFailure,
               "Windows Graphics Capture owner is not initialized.");
  }

  void AttachSurface(const EncodableMap& arguments,
                     std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    if (!owner_id) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
      return;
    }
    const auto direction = StringArgument(arguments, "direction");
    if (!direction) {
      ReplyError(result, "invalid_argument", "A media direction is required.");
      return;
    }
    if (*direction != "receive") {
      ReplyError(result, "direction_mismatch",
                 "Rendering requires a receive media owner.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!native_media_api_.available()) {
      native_media_api_ = NativeMediaApi::Resolve();
    }
    if (!hardware_decoder_available_) {
      ReplyError(result, kDecoderUnavailable,
                 "A hardware Media Foundation H.264 decoder is unavailable.");
      return;
    }
    if (native_media_api_.attach_renderer == nullptr ||
        native_media_api_.detach_renderer == nullptr) {
      ReplyError(result, kBackendFailure,
                 "The native renderer owner lifecycle is unavailable.");
      return;
    }
    const auto attach_status =
        native_media_api_.attach_renderer(*owner_id);
    if (attach_status != 0) {
      ReplyError(result, NativeStatusCode(attach_status),
                 "The native renderer owner could not be attached.");
      return;
    }
    const auto detach_status =
        native_media_api_.detach_renderer(*owner_id);
    if (detach_status != 0 && detach_status != -12) {
      ReplyError(result, NativeStatusCode(detach_status),
                 "The native renderer owner could not be detached.");
      return;
    }
    ReplyError(result, kBackendFailure,
               "The Windows GPU decoder surface is not initialized.");
  }

  void StopOwner(const EncodableMap& arguments,
                 std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    if (!owner_id) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!native_media_api_.available()) {
      native_media_api_ = NativeMediaApi::Resolve();
    }
    if (!native_media_api_.lifecycle_available()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner lifecycle is unavailable.");
      return;
    }
    const auto status = native_media_api_.stop_owner(*owner_id);
    if (status != 0 && status != -12) {
      ReplyError(result, NativeStatusCode(status),
                 "The native media owner could not be stopped.");
      return;
    }
    const auto token = std::to_string(*owner_id);
    auto owner = owners_.find(token);
    if (owner != owners_.end()) owner->second.capture_started = false;
    result->Success();
  }

  void ReleaseOwner(const EncodableMap& arguments,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    if (!owner_id) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!native_media_api_.available()) {
      native_media_api_ = NativeMediaApi::Resolve();
    }
    if (!native_media_api_.lifecycle_available()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner lifecycle is unavailable.");
      return;
    }
    int close_status = 0;
    const auto stop_status = native_media_api_.stop_owner(*owner_id);
    if (stop_status != 0 && stop_status != -12) {
      ReplyError(result, NativeStatusCode(stop_status),
                 "The native media owner could not be stopped.");
      return;
    }
    close_status = native_media_api_.close_owner(*owner_id);
    if (close_status != 0) {
      ReplyError(result, kBackendFailure,
                 "The native media owner could not be closed.");
      return;
    }
    owners_.erase(std::to_string(*owner_id));
    result->Success();
  }

  void ReadStats(const EncodableMap& arguments,
                 std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    if (!owner_id) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (owners_.find(std::to_string(*owner_id)) == owners_.end()) {
      ReplyError(result, kBackendFailure, "The native media owner is no longer active.");
      return;
    }
    result->Success(EncodableMap{
        {EncodableValue("width"), EncodableValue(0)},
        {EncodableValue("height"), EncodableValue(0)},
        {EncodableValue("frames_captured"), EncodableValue(0)},
        {EncodableValue("frames_sent"), EncodableValue(0)},
        {EncodableValue("frames_dropped"), EncodableValue(0)},
        {EncodableValue("frames_decoded"), EncodableValue(0)},
        {EncodableValue("frames_rendered"), EncodableValue(0)},
    });
  }

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  NativeMediaApi native_media_api_;
  std::mutex mutex_;
  std::vector<SourceRecord> sources_;
  std::unordered_map<std::string, OwnerRecord> owners_;
  bool hardware_encoder_available_ = false;
  bool hardware_decoder_available_ = false;
};

}  // namespace

void RealtimeMediaWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  RealtimeMediaWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
