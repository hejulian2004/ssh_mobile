#include "include/realtime_media_windows/realtime_media_windows_plugin.h"

#include "windows_media_channel.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cmath>
#include <limits>
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
using realtime_media_windows::CaptureStats;
using realtime_media_windows::CaptureStatus;
using realtime_media_windows::CaptureStatusCode;
using realtime_media_windows::CodecModeArgument;
using realtime_media_windows::DecoderStats;
using realtime_media_windows::DecoderStatus;
using realtime_media_windows::DecoderStatusCode;
using realtime_media_windows::NativeMediaApi;
using realtime_media_windows::NativeMediaStats;
using realtime_media_windows::NativeStatusCode;
using realtime_media_windows::OwnerIdArgument;
using realtime_media_windows::ReplyError;
using realtime_media_windows::StatsMap;
using realtime_media_windows::StringArgument;
using realtime_media_windows::WindowsCaptureManager;
using realtime_media_windows::WindowsDecoderManager;

constexpr char kChannelName[] = "ssh_mobile/realtime_media/windows";
constexpr char kBackendFailure[] = "backend_failure";
constexpr char kCaptureSourceEnded[] = "capture_source_ended";
constexpr char kDecoderUnavailable[] = "decoder_unavailable";
constexpr char kEncoderUnavailable[] = "encoder_unavailable";
constexpr char kEncoderFailed[] = "encoder_failed";
constexpr char kDecoderFailed[] = "decoder_failed";
constexpr char kRecreateRequired[] = "recreate_required";

std::optional<uint32_t> Uint32Argument(const EncodableMap& arguments,
                                       const char* key) {
  const auto it = arguments.find(EncodableValue(key));
  if (it == arguments.end()) return std::nullopt;
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return *value >= 0 ? std::optional<uint32_t>(*value) : std::nullopt;
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return *value >= 0 && static_cast<uint64_t>(*value) <=
                              (std::numeric_limits<uint32_t>::max)()
               ? std::optional<uint32_t>(static_cast<uint32_t>(*value))
               : std::nullopt;
  }
  if (const auto* value = std::get_if<double>(&it->second)) {
    if (!std::isfinite(*value) || *value < 0 ||
        *value > (std::numeric_limits<uint32_t>::max)() ||
        std::floor(*value) != *value) {
      return std::nullopt;
    }
    return static_cast<uint32_t>(*value);
  }
  return std::nullopt;
}

class RealtimeMediaWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<RealtimeMediaWindowsPlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit RealtimeMediaWindowsPlugin(
      flutter::PluginRegistrarWindows* registrar)
      : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance())),
        native_media_api_(NativeMediaApi::Resolve()),
        decoder_manager_(registrar->texture_registrar()) {
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      HandleMethod(call, std::move(result));
    });
  }

  ~RealtimeMediaWindowsPlugin() override = default;

 private:
  void HandleMethod(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() == "listSources") {
      result->Success(ListSources());
      return;
    }
    const auto* arguments = std::get_if<EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      ReplyError(result, "invalid_argument",
                 "Windows media arguments are invalid.");
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
    } else if (call.method_name() == "requestKeyframe") {
      RequestKeyframe(*arguments, std::move(result));
    } else if (call.method_name() == "resetDecoder") {
      ResetDecoder(*arguments, std::move(result));
    } else if (call.method_name() == "applyAdaptation") {
      ApplyAdaptation(*arguments, std::move(result));
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
    capture_manager_.SetPushCallback(native_media_api_.push_h264);
    decoder_manager_.SetNativeCallbacks(native_media_api_.pull_h264,
                                        native_media_api_.free_buffer);
    return native_media_api_.available();
  }

  void StartCapture(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto source_id = StringArgument(arguments, "source_id");
    const auto source_kind = StringArgument(arguments, "source_kind");
    const auto direction = StringArgument(arguments, "direction");
    const auto codec_mode = CodecModeArgument(arguments);
    if (!owner_id || !source_id || !source_kind || !direction || !codec_mode) {
      ReplyError(result, "invalid_argument",
                 "A native owner and source are required.");
      return;
    }
    if (*direction != "send") {
      ReplyError(result, "direction_mismatch",
                 "Capture requires a send media owner.");
      return;
    }
    if (*source_kind != "display" && *source_kind != "window") {
      ReplyError(result, "invalid_argument",
                 "The capture source kind is invalid.");
      return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (!RefreshNativeMediaApi() || native_media_api_.push_h264 == nullptr) {
      ReplyError(result, kBackendFailure,
                 "The native media owner or H.264 ingress is unavailable.");
      return;
    }
    const auto start_status = native_media_api_.start_owner(*owner_id);
    if (start_status != 0) {
      ReplyError(result, NativeStatusCode(start_status),
                 "The native media owner could not be started.");
      return;
    }
    // Source IDs are generation-bound tokens returned by listSources. Do not
    // re-enumerate here: replacing the catalog between selection and start
    // could make an ordinal ID target a different window.
    const auto capture_status = capture_manager_.Start(
        *owner_id, *source_id, *source_kind, *codec_mode);
    if (capture_status != CaptureStatus::kOk) {
      native_media_api_.stop_owner(*owner_id);
      ReplyError(result, CaptureStatusCode(capture_status),
                 "The Windows capture owner could not be started.");
      return;
    }
    result->Success();
  }

  void AttachSurface(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    std::lock_guard<std::mutex> lock(mutex_);
    RefreshNativeMediaApi();
    AttachMediaSurface(arguments, std::move(result), native_media_api_,
                       decoder_manager_);
  }

  void StopOwner(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !direction ||
        (*direction != "send" && *direction != "receive")) {
      ReplyError(result, "invalid_argument",
                 "A native owner token is required.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const auto decoder_status = decoder_manager_.Detach(*owner_id);
    const auto capture_status = capture_manager_.Stop(*owner_id);
    if (!RefreshNativeMediaApi()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner lifecycle is unavailable.");
      return;
    }
    // Renderer state exists only for receive owners. The native ABI
    // intentionally returns direction-mismatch for detachRenderer(send), so
    // do not turn an ordinary send capture stop into a lifecycle failure.
    if (*direction == "receive" &&
        native_media_api_.detach_renderer != nullptr) {
      const auto renderer_status = native_media_api_.detach_renderer(*owner_id);
      if (renderer_status != 0 && renderer_status != -12) {
        ReplyError(result, NativeStatusCode(renderer_status),
                   "The native renderer capability could not be detached.");
        return;
      }
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
    if (decoder_status != DecoderStatus::kOk &&
        decoder_status != DecoderStatus::kNotFound) {
      ReplyError(result, DecoderStatusCode(decoder_status),
                 "The Windows decoder could not be stopped.");
      return;
    }
    result->Success();
  }

  void ReleaseOwner(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !direction ||
        (*direction != "send" && *direction != "receive")) {
      ReplyError(result, "invalid_argument",
                 "A native owner token is required.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    // Stop platform production before closing the generation-bound native
    // owner. A retry after a native close failure still sees the same stopped
    // capture record and cannot leak a frame callback.
    const auto decoder_status = decoder_manager_.Release(*owner_id);
    capture_manager_.Stop(*owner_id);
    if (!RefreshNativeMediaApi()) {
      ReplyError(result, kBackendFailure,
                 "The native media owner lifecycle is unavailable.");
      return;
    }
    if (*direction == "receive" &&
        native_media_api_.detach_renderer != nullptr) {
      const auto renderer_status = native_media_api_.detach_renderer(*owner_id);
      if (renderer_status != 0 && renderer_status != -12) {
        ReplyError(result, NativeStatusCode(renderer_status),
                   "The native renderer capability could not be detached.");
        return;
      }
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
    if (decoder_status != DecoderStatus::kOk &&
        decoder_status != DecoderStatus::kNotFound) {
      ReplyError(result, DecoderStatusCode(decoder_status),
                 "The Windows decoder stopped with a terminal failure.");
      return;
    }
    result->Success();
  }

  void ReadStats(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    std::lock_guard<std::mutex> lock(mutex_);
    ReplyMediaStats(arguments, std::move(result), native_media_api_,
                    capture_manager_, decoder_manager_);
  }

  void RequestKeyframe(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !direction) {
      ReplyError(result, "invalid_argument",
                 "A native owner token and media direction are required.");
      return;
    }
    if (*direction != "send" && *direction != "receive") {
      ReplyError(result, "invalid_argument", "The media direction is invalid.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!RefreshNativeMediaApi() ||
        native_media_api_.request_keyframe == nullptr) {
      ReplyError(result, kBackendFailure,
                 "Native keyframe recovery is unavailable.");
      return;
    }
    const auto status = native_media_api_.request_keyframe(*owner_id);
    if (status != 0) {
      ReplyError(result, NativeStatusCode(status),
                 "The native keyframe request failed.");
      return;
    }
    if (*direction == "send") {
      const auto capture_status = capture_manager_.RequestKeyframe(*owner_id);
      if (capture_status != CaptureStatus::kOk) {
        ReplyError(
            result, CaptureStatusCode(capture_status),
            "The Windows H.264 encoder could not request a keyframe.");
        return;
      }
    }
    result->Success();
  }

  void ResetDecoder(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !direction) {
      ReplyError(result, "invalid_argument",
                 "A native owner token and media direction are required.");
      return;
    }
    if (*direction != "receive") {
      ReplyError(result, "direction_mismatch",
                 "Decoder recovery requires a receive media owner.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!RefreshNativeMediaApi() ||
        native_media_api_.reset_decoder == nullptr) {
      ReplyError(result, kDecoderUnavailable,
                 "Native decoder recovery is unavailable.");
      return;
    }
    const auto native_status = native_media_api_.reset_decoder(*owner_id);
    if (native_status != 0) {
      ReplyError(result, NativeStatusCode(native_status),
                 "The native decoder reset failed.");
      return;
    }
    const auto decoder_status = decoder_manager_.Reset(*owner_id);
    if (decoder_status != DecoderStatus::kOk) {
      ReplyError(result, DecoderStatusCode(decoder_status),
                 "The Windows H.264 decoder reset failed.");
      return;
    }
    result->Success();
  }

  void ApplyAdaptation(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto direction = StringArgument(arguments, "direction");
    const auto bitrate = Uint32Argument(arguments, "bitrate_kbps");
    const auto framerate = Uint32Argument(arguments, "framerate");
    const auto width = Uint32Argument(arguments, "width");
    const auto height = Uint32Argument(arguments, "height");
    const auto reason = StringArgument(arguments, "reason");
    if (!owner_id || !direction || !bitrate || !framerate || !width ||
        !height || !reason) {
      ReplyError(result, "invalid_argument",
                 "A complete bounded adaptation target is required.");
      return;
    }
    if (*direction != "send") {
      ReplyError(result, "direction_mismatch",
                 "Adaptation requires a send media owner.");
      return;
    }
    uint32_t reason_value = 0;
    if (*reason == "congestion") {
      reason_value = 1;
    } else if (*reason == "recovery") {
      reason_value = 2;
    } else if (*reason != "steady") {
      ReplyError(result, "invalid_argument",
                 "The adaptation reason is invalid.");
      return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (!RefreshNativeMediaApi() ||
        native_media_api_.apply_adaptation == nullptr) {
      ReplyError(result, kEncoderUnavailable,
                 "Native H.264 adaptation is unavailable.");
      return;
    }
    uint32_t previous_bitrate = 0;
    uint32_t previous_framerate = 0;
    const auto previous_status = capture_manager_.CurrentAdaptation(
        *owner_id, &previous_bitrate, &previous_framerate);
    if (previous_status != CaptureStatus::kOk) {
      ReplyError(result, CaptureStatusCode(previous_status),
                 "The Windows capture owner has no current adaptation target.");
      return;
    }
    const auto capture_status = capture_manager_.ApplyAdaptation(
        *owner_id, *bitrate, *framerate, *width, *height);
    if (capture_status != CaptureStatus::kOk) {
      ReplyError(
          result, CaptureStatusCode(capture_status),
          "The Windows H.264 encoder rejected the adaptation target.");
      return;
    }
    const auto native_status = native_media_api_.apply_adaptation(
        *owner_id, *bitrate, *framerate, *width, *height, reason_value);
    if (native_status != 0) {
      const auto rollback_status = capture_manager_.RestoreAdaptation(
          *owner_id, previous_bitrate, previous_framerate);
      if (rollback_status != CaptureStatus::kOk) {
        capture_manager_.MarkAdaptationRecreateRequired(*owner_id);
        ReplyError(result, kRecreateRequired,
                   "Native adaptation failed and the encoder target could not "
                   "be rolled back.");
        return;
      }
      ReplyError(result, NativeStatusCode(native_status),
                 "The native adaptation target could not be committed.");
      return;
    }
    result->Success();
  }

  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  NativeMediaApi native_media_api_;
  WindowsCaptureManager capture_manager_;
  WindowsDecoderManager decoder_manager_;
  std::mutex mutex_;
};

}  // namespace

void RealtimeMediaWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  RealtimeMediaWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
