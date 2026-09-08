#include "include/realtime_media_windows/realtime_media_windows_plugin.h"

#include "windows_media_channel.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <mutex>
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
using realtime_media_windows::DecoderStats;
using realtime_media_windows::DecoderStatus;
using realtime_media_windows::NativeMediaApi;
using realtime_media_windows::WindowsDecoderManager;
using realtime_media_windows::WindowsCaptureManager;
using realtime_media_windows::CaptureStatusCode;
using realtime_media_windows::DecoderStatusCode;
using realtime_media_windows::NativeStatusCode;
using realtime_media_windows::OwnerIdArgument;
using realtime_media_windows::ReplyError;
using realtime_media_windows::StatsMap;
using realtime_media_windows::StringArgument;

constexpr char kChannelName[] = "ssh_mobile/realtime_media/windows";
constexpr char kBackendFailure[] = "backend_failure";
constexpr char kCaptureSourceEnded[] = "capture_source_ended";
constexpr char kDecoderUnavailable[] = "decoder_unavailable";
constexpr char kEncoderUnavailable[] = "encoder_unavailable";
constexpr char kEncoderFailed[] = "encoder_failed";
constexpr char kDecoderFailed[] = "decoder_failed";

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
        native_media_api_(NativeMediaApi::Resolve()),
        decoder_manager_(registrar->texture_registrar()) {
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
    } else if (call.method_name() == "requestKeyframe") {
      RequestKeyframe(*arguments, std::move(result));
    } else if (call.method_name() == "resetDecoder") {
      ResetDecoder(*arguments, std::move(result));
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
    return native_media_api_.lifecycle_available();
  }

  void StartCapture(const EncodableMap& arguments,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto source_id = StringArgument(arguments, "source_id");
    const auto source_kind = StringArgument(arguments, "source_kind");
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !source_id || !source_kind || !direction) {
      ReplyError(result, "invalid_argument", "A native owner and source are required.");
      return;
    }
    if (*direction != "send") {
      ReplyError(result, "direction_mismatch", "Capture requires a send media owner.");
      return;
    }
    if (*source_kind != "display" && *source_kind != "window") {
      ReplyError(result, "invalid_argument", "The capture source kind is invalid.");
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
    const auto capture_status =
        capture_manager_.Start(*owner_id, *source_id, *source_kind);
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
    std::lock_guard<std::mutex> lock(mutex_);
    if (!RefreshNativeMediaApi() || native_media_api_.validate_owner == nullptr ||
        native_media_api_.attach_renderer == nullptr ||
        native_media_api_.detach_renderer == nullptr ||
        native_media_api_.pull_h264 == nullptr ||
        native_media_api_.free_buffer == nullptr) {
      ReplyError(result, kDecoderUnavailable,
                 "The native H.264 decoder surface is unavailable.");
      return;
    }
    const auto validation_status = native_media_api_.validate_owner(*owner_id);
    if (validation_status != 0) {
      ReplyError(result, NativeStatusCode(validation_status),
                 "The native receive owner is no longer current.");
      return;
    }
    const auto attach_status = native_media_api_.attach_renderer(*owner_id);
    if (attach_status != 0) {
      ReplyError(result, NativeStatusCode(attach_status),
                 "The native renderer capability could not be attached.");
      return;
    }
    int64_t surface_id = -1;
    const auto decoder_status = decoder_manager_.Attach(*owner_id, &surface_id);
    if (decoder_status != DecoderStatus::kOk) {
      native_media_api_.detach_renderer(*owner_id);
      ReplyError(result, DecoderStatusCode(decoder_status),
                 "The Windows H.264 decoder surface could not be attached.");
      return;
    }
    result->Success(EncodableMap{
        {EncodableValue("surface_id"),
         EncodableValue(std::to_string(surface_id))},
    });
  }

  void StopOwner(const EncodableMap& arguments,
                 std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !direction ||
        (*direction != "send" && *direction != "receive")) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
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

  void ReleaseOwner(const EncodableMap& arguments,
                    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    const auto direction = StringArgument(arguments, "direction");
    if (!owner_id || !direction ||
        (*direction != "send" && *direction != "receive")) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
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
      decoder_manager_.Release(*owner_id);
      ReplyError(result, NativeStatusCode(validation_status),
                 "The native media owner is no longer current.");
      return;
    }

    CaptureStats stats;
    const auto capture_status = capture_manager_.ReadStats(*owner_id, &stats);
    DecoderStats decoder_stats;
    const auto decoder_status = decoder_manager_.ReadStats(*owner_id, &decoder_stats);
    if (decoder_status == DecoderStatus::kNativeFailure) {
      const char* code =
          decoder_stats.terminal_status ==
                  realtime_media_windows::kDecoderTerminalFailed
              ? kDecoderFailed
              : NativeStatusCode(decoder_stats.terminal_status);
      ReplyError(result, code, "The Windows H.264 decoder owner failed.");
      return;
    }
    if (capture_status == CaptureStatus::kNotFound) {
      if (decoder_status == DecoderStatus::kOk) {
        result->Success(StatsMap(stats, &decoder_stats));
      } else {
        // A receive owner may be valid before a native decoder is attached.
        result->Success(StatsMap(stats));
      }
      return;
    }
    if (capture_status != CaptureStatus::kOk) {
      if (capture_status == CaptureStatus::kNativeFailure) {
        if (stats.terminal_status ==
            realtime_media_windows::kCaptureTerminalEncoderFailed) {
          ReplyError(result, kEncoderFailed,
                     "The Windows hardware H.264 encoder failed.");
        } else if (stats.terminal_status ==
                   realtime_media_windows::kCaptureTerminalResolutionChanged) {
          ReplyError(result, kCaptureSourceEnded,
                     "The capture resolution changed; restart the media owner.");
        } else {
          ReplyError(result, NativeStatusCode(stats.terminal_status),
                     "The native media owner rejected a captured frame.");
        }
        return;
      }
      ReplyError(result, CaptureStatusCode(capture_status),
                 "The Windows capture source is no longer producing frames.");
      return;
    }
    result->Success(decoder_status == DecoderStatus::kOk
                        ? StatsMap(stats, &decoder_stats)
                        : StatsMap(stats));
  }

  void RequestKeyframe(
      const EncodableMap& arguments,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto owner_id = OwnerIdArgument(arguments);
    if (!owner_id) {
      ReplyError(result, "invalid_argument", "A native owner token is required.");
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!RefreshNativeMediaApi() || native_media_api_.request_keyframe == nullptr) {
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
    if (!RefreshNativeMediaApi() || native_media_api_.reset_decoder == nullptr) {
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
