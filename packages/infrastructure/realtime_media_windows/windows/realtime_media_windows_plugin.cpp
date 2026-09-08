#include "include/realtime_media_windows/realtime_media_windows_plugin.h"

#include "windows_capture.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <cstdlib>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using realtime_media_windows::CaptureSourceDescriptor;
using realtime_media_windows::CaptureStatus;
using realtime_media_windows::CaptureStats;
using realtime_media_windows::WindowsCaptureManager;

constexpr char kChannelName[] = "ssh_mobile/realtime_media/windows";
constexpr char kBackendFailure[] = "backend_failure";
constexpr char kCaptureSourceEnded[] = "capture_source_ended";
constexpr char kDecoderUnavailable[] = "decoder_unavailable";

using OwnerCloseFunction = int(__cdecl*)(uint64_t);
using OwnerStartFunction = int(__cdecl*)(uint64_t);
using OwnerStopFunction = int(__cdecl*)(uint64_t);
using OwnerValidateFunction = int(__cdecl*)(uint64_t);
using OwnerRendererFunction = int(__cdecl*)(uint64_t);

struct NativeMediaApi {
  OwnerStartFunction start_owner = nullptr;
  OwnerStopFunction stop_owner = nullptr;
  OwnerValidateFunction validate_owner = nullptr;
  OwnerCloseFunction close_owner = nullptr;
  OwnerRendererFunction attach_renderer = nullptr;
  OwnerRendererFunction detach_renderer = nullptr;

  bool available() const { return close_owner != nullptr; }
  bool lifecycle_available() const {
    return start_owner != nullptr && stop_owner != nullptr &&
           close_owner != nullptr;
  }
  bool validation_available() const { return validate_owner != nullptr; }

  static NativeMediaApi Resolve() {
    NativeMediaApi api;
    const HMODULE module = GetModuleHandleW(L"network_ffi.dll");
    if (module == nullptr) return api;
    api.start_owner = reinterpret_cast<OwnerStartFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_start"));
    api.stop_owner = reinterpret_cast<OwnerStopFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_stop"));
    api.validate_owner = reinterpret_cast<OwnerValidateFunction>(
        GetProcAddress(module, "ssh_net_realtime_media_owner_validate"));
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

const char* CaptureStatusCode(CaptureStatus status) {
  switch (status) {
    case CaptureStatus::kSourceEnded:
      return kCaptureSourceEnded;
    case CaptureStatus::kDuplicate:
      return "duplicate_endpoint";
    case CaptureStatus::kUnsupported:
    case CaptureStatus::kBackendFailure:
      return kBackendFailure;
    case CaptureStatus::kNotFound:
    case CaptureStatus::kOk:
      return kBackendFailure;
  }
  return kBackendFailure;
}

EncodableMap StatsMap(const CaptureStats& stats) {
  return EncodableMap{
      {EncodableValue("width"), EncodableValue(stats.width)},
      {EncodableValue("height"), EncodableValue(stats.height)},
      {EncodableValue("frames_captured"),
       EncodableValue(static_cast<int64_t>(stats.frames_captured))},
      {EncodableValue("frames_sent"), EncodableValue(0)},
      {EncodableValue("frames_dropped"),
       EncodableValue(static_cast<int64_t>(stats.frames_dropped))},
      {EncodableValue("frames_decoded"), EncodableValue(0)},
      {EncodableValue("frames_rendered"), EncodableValue(0)},
  };
}

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
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { HandleMethod(call, std::move(result)); });
  }

  ~RealtimeMediaWindowsPlugin() override = default;

 private:
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
    std::vector<CaptureSourceDescriptor> sources;
    if (!capture_manager_.EnumerateSources(&sources)) return {};
    EncodableList output;
    output.reserve(sources.size());
    for (const auto& source : sources) {
      EncodableMap item{
          {EncodableValue("id"), EncodableValue(source.id)},
          {EncodableValue("kind"), EncodableValue(source.kind)},
          {EncodableValue("label"), EncodableValue(source.label)},
      };
      if (source.width > 0) item[EncodableValue("width")] = source.width;
      if (source.height > 0) item[EncodableValue("height")] = source.height;
      output.emplace_back(std::move(item));
    }
    return output;
  }

  bool RefreshNativeMediaApi() {
    if (!native_media_api_.available()) {
      native_media_api_ = NativeMediaApi::Resolve();
    }
    return native_media_api_.lifecycle_available();
  }

  void StartCapture(const EncodableMap& arguments,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto source_id = StringArgument(arguments, "source_id");
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !source_id || !direction) {
      ReplyError(result, "invalid_argument", "A native owner and source are required.");
      return;
    }
    if (*direction != "send") {
      ReplyError(result, "direction_mismatch", "Capture requires a send media owner.");
      return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (!RefreshNativeMediaApi()) {
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
    std::vector<CaptureSourceDescriptor> ignored_sources;
    if (!capture_manager_.EnumerateSources(&ignored_sources)) {
      native_media_api_.stop_owner(*owner_id);
      ReplyError(result, kBackendFailure,
                 "Windows capture source enumeration failed.");
      return;
    }
    const auto capture_status = capture_manager_.Start(*owner_id, *source_id);
    if (capture_status != CaptureStatus::kOk) {
      native_media_api_.stop_owner(*owner_id);
      ReplyError(result, CaptureStatusCode(capture_status),
                 "The Windows capture owner could not be started.");
      return;
    }
    result->Success();
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
      ReplyError(result, "direction_mismatch", "Rendering requires a receive media owner.");
      return;
    }
    // P3.3 owns the decoder/GPU surface implementation. Until that owner is
    // installed, fail explicitly instead of returning a synthetic texture ID.
    ReplyError(result, kDecoderUnavailable,
               "The Windows H.264 decoder surface is not initialized.");
  }

  void StopOwner(const EncodableMap& arguments,
                 std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    if (!owner_id) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const auto capture_status = capture_manager_.Stop(*owner_id);
    if (!RefreshNativeMediaApi()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner lifecycle is unavailable.");
      return;
    }
    const auto native_status = native_media_api_.stop_owner(*owner_id);
    if (native_status != 0 && native_status != -12) {
      ReplyError(result, NativeStatusCode(native_status),
                 "The native media owner could not be stopped.");
      return;
    }
    if (capture_status != CaptureStatus::kOk &&
        capture_status != CaptureStatus::kSourceEnded &&
        capture_status != CaptureStatus::kNotFound) {
      ReplyError(result, CaptureStatusCode(capture_status),
                 "The Windows capture owner could not be stopped.");
      return;
    }
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
    // Stop platform production before closing the generation-bound native
    // owner. A retry after a native close failure still sees the same stopped
    // capture record and cannot leak a frame callback.
    capture_manager_.Stop(*owner_id);
    if (!RefreshNativeMediaApi()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner lifecycle is unavailable.");
      return;
    }
    const auto stop_status = native_media_api_.stop_owner(*owner_id);
    if (stop_status != 0 && stop_status != -12) {
      ReplyError(result, NativeStatusCode(stop_status),
                 "The native media owner could not be stopped.");
      return;
    }
    const auto close_status = native_media_api_.close_owner(*owner_id);
    if (close_status != 0 && close_status != -12) {
      ReplyError(result, NativeStatusCode(close_status),
                 "The native media owner could not be closed.");
      return;
    }
    capture_manager_.Release(*owner_id);
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
    if (!native_media_api_.available()) {
      native_media_api_ = NativeMediaApi::Resolve();
    }
    if (!native_media_api_.validation_available()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner validation is unavailable.");
      return;
    }
    const auto validation_status = native_media_api_.validate_owner(*owner_id);
    if (validation_status != 0) {
      capture_manager_.Release(*owner_id);
      ReplyError(result, NativeStatusCode(validation_status),
                 "The native media owner is no longer current.");
      return;
    }

    CaptureStats stats;
    const auto capture_status = capture_manager_.ReadStats(*owner_id, &stats);
    if (capture_status == CaptureStatus::kNotFound) {
      // A receive owner may be valid before a native decoder is attached.
      result->Success(StatsMap(stats));
      return;
    }
    if (capture_status != CaptureStatus::kOk) {
      ReplyError(result, CaptureStatusCode(capture_status),
                 "The Windows capture source is no longer producing frames.");
      return;
    }
    result->Success(StatsMap(stats));
  }

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  NativeMediaApi native_media_api_;
  WindowsCaptureManager capture_manager_;
  std::mutex mutex_;
};

}  // namespace

void RealtimeMediaWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  RealtimeMediaWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
