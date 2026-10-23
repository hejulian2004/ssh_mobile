#include "windows_media_channel.h"

#include <windows.h>

#include <cstdlib>
#include <limits>

namespace realtime_media_windows {
using flutter::EncodableMap;
using flutter::EncodableValue;
namespace {

constexpr char kBackendFailure[] = "backend_failure";
constexpr char kCaptureSourceEnded[] = "capture_source_ended";
constexpr char kDecoderUnavailable[] = "decoder_unavailable";
constexpr char kDecoderFailed[] = "decoder_failed";
constexpr char kEncoderUnavailable[] = "encoder_unavailable";
constexpr char kEncoderFailed[] = "encoder_failed";
constexpr char kRecreateRequired[] = "recreate_required";

int64_t BoundedInt64(uint64_t value) {
  constexpr auto kMax =
      static_cast<uint64_t>((std::numeric_limits<int64_t>::max)());
  return static_cast<int64_t>(value > kMax ? kMax : value);
}

}  // namespace

NativeMediaApi NativeMediaApi::Resolve() {
  NativeMediaApi api;
  const HMODULE module = GetModuleHandleW(L"network_ffi.dll");
  if (module == nullptr) return api;
  api.abi_version = reinterpret_cast<OwnerAbiVersionFunction>(
      GetProcAddress(module, "ssh_net_abi_version"));
  api.start_owner = reinterpret_cast<OwnerStartFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_start"));
  api.stop_owner = reinterpret_cast<OwnerStopFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_stop"));
  api.validate_owner = reinterpret_cast<OwnerValidateFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_validate"));
  api.request_keyframe = reinterpret_cast<OwnerRecoveryFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_request_keyframe"));
  api.reset_decoder = reinterpret_cast<OwnerRecoveryFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_reset_decoder"));
  api.read_stats = reinterpret_cast<OwnerStatsFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_read_stats"));
  api.apply_adaptation = reinterpret_cast<OwnerAdaptationFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_apply_adaptation"));
  api.close_owner = reinterpret_cast<OwnerCloseFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_close"));
  api.attach_renderer = reinterpret_cast<OwnerRendererFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_attach_renderer"));
  api.detach_renderer = reinterpret_cast<OwnerRendererFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_detach_renderer"));
  api.push_h264 = reinterpret_cast<OwnerPushFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_push_h264"));
  api.pull_h264 = reinterpret_cast<OwnerPullFunction>(
      GetProcAddress(module, "ssh_net_realtime_media_owner_pull_h264"));
  api.free_buffer = reinterpret_cast<BufferFreeFunction>(
      GetProcAddress(module, "ssh_net_buffer_free"));
  return api;
}

std::optional<std::string> StringArgument(
    const flutter::EncodableMap& arguments, const char* key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) return std::nullopt;
  const auto* value = std::get_if<std::string>(&it->second);
  if (value == nullptr || value->empty() || value->size() > 128) {
    return std::nullopt;
  }
  return *value;
}

std::optional<uint64_t> OwnerIdArgument(
    const flutter::EncodableMap& arguments) {
  const auto token = StringArgument(arguments, "owner_token");
  if (!token) return std::nullopt;
  char* end = nullptr;
  const auto value = std::strtoull(token->c_str(), &end, 10);
  if (end == token->c_str() || *end != '\0' || value == 0) {
    return std::nullopt;
  }
  return value;
}

void ReplyError(const std::unique_ptr<
                    flutter::MethodResult<flutter::EncodableValue>>& result,
                const char* code, const char* message) {
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
    case CaptureStatus::kEncoderUnavailable:
      return kEncoderUnavailable;
    case CaptureStatus::kEncoderFailed:
      return kEncoderFailed;
    case CaptureStatus::kRecreateRequired:
      return kRecreateRequired;
    case CaptureStatus::kUnsupported:
    case CaptureStatus::kBackendFailure:
    case CaptureStatus::kNativeFailure:
    case CaptureStatus::kNotFound:
    case CaptureStatus::kOk:
      return kBackendFailure;
  }
  return kBackendFailure;
}

const char* DecoderStatusCode(DecoderStatus status) {
  switch (status) {
    case DecoderStatus::kDecoderUnavailable:
      return kDecoderUnavailable;
    case DecoderStatus::kDecoderFailed:
      return kDecoderFailed;
    case DecoderStatus::kDuplicate:
      return "duplicate_endpoint";
    case DecoderStatus::kNativeFailure:
    case DecoderStatus::kNotFound:
    case DecoderStatus::kBackendFailure:
    case DecoderStatus::kOk:
      return kBackendFailure;
  }
  return kBackendFailure;
}

flutter::EncodableMap StatsMap(const CaptureStats& stats,
                               const DecoderStats* decoder,
                               const NativeMediaStats* native) {
  const int width =
      decoder != nullptr && decoder->width > 0 ? decoder->width : stats.width;
  const int height = decoder != nullptr && decoder->height > 0 ? decoder->height
                                                               : stats.height;
  const auto frames_decoded = decoder == nullptr ? 0 : decoder->frames_decoded;
  const auto frames_rendered =
      decoder == nullptr ? 0 : decoder->frames_rendered;
  const auto frames_dropped =
      stats.frames_dropped +
      (decoder == nullptr ? 0 : decoder->frames_dropped) +
      (native == nullptr ? 0 : native->dropped);
  const auto queue_depth = native == nullptr ? 0 : native->queue_depth;
  const auto queue_capacity = native == nullptr ? 3 : native->queue_capacity;
  const auto keyframe_requests =
      native == nullptr ? 0 : native->keyframe_requests;
  return flutter::EncodableMap{
      {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
      {flutter::EncodableValue("height"), flutter::EncodableValue(height)},
      {flutter::EncodableValue("frames_captured"),
       flutter::EncodableValue(BoundedInt64(stats.frames_captured))},
      {flutter::EncodableValue("frames_sent"),
       flutter::EncodableValue(BoundedInt64(stats.frames_sent))},
      {flutter::EncodableValue("frames_dropped"),
       flutter::EncodableValue(BoundedInt64(frames_dropped))},
      {flutter::EncodableValue("frames_decoded"),
       flutter::EncodableValue(BoundedInt64(frames_decoded))},
      {flutter::EncodableValue("frames_rendered"),
       flutter::EncodableValue(BoundedInt64(frames_rendered))},
      {flutter::EncodableValue("packets_sent"),
       flutter::EncodableValue(
           BoundedInt64(native == nullptr ? 0 : native->packets_sent))},
      {flutter::EncodableValue("packets_received"),
       flutter::EncodableValue(
           BoundedInt64(native == nullptr ? 0 : native->packets_received))},
      {flutter::EncodableValue("packets_lost"),
       flutter::EncodableValue(
           BoundedInt64(native == nullptr ? 0 : native->packets_lost))},
      {flutter::EncodableValue("frames_recovered"),
       flutter::EncodableValue(
           BoundedInt64(native == nullptr ? 0 : native->frames_recovered))},
      {flutter::EncodableValue("keyframe_requests"),
       flutter::EncodableValue(BoundedInt64(keyframe_requests))},
      {flutter::EncodableValue("jitter_ms"),
       flutter::EncodableValue(
           BoundedInt64(native == nullptr ? 0 : native->jitter_ms))},
      {flutter::EncodableValue("rtt_ms"),
       flutter::EncodableValue(
           BoundedInt64(native == nullptr ? 0 : native->rtt_ms))},
      {flutter::EncodableValue("queue_depth"),
       flutter::EncodableValue(static_cast<int64_t>(queue_depth))},
      {flutter::EncodableValue("queue_capacity"),
       flutter::EncodableValue(static_cast<int64_t>(queue_capacity))},
  };
}

std::optional<NativeCodecMode> CodecModeArgument(
    const flutter::EncodableMap& arguments) {
  const auto it = arguments.find(flutter::EncodableValue("codec_mode"));
  if (it == arguments.end()) return NativeCodecMode::Automatic;
  const auto value = StringArgument(arguments, "codec_mode");
  if (value && *value == "automatic") return NativeCodecMode::Automatic;
  if (value && *value == "hardware") return NativeCodecMode::Hardware;
  if (value && *value == "cpu") return NativeCodecMode::Cpu;
  return std::nullopt;
}

void AttachMediaSurface(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    NativeMediaApi& api, WindowsDecoderManager& decoder) {
  const auto codec_mode = CodecModeArgument(arguments);
  if (!codec_mode) {
    ReplyError(result, "invalid_argument", "The codec mode is invalid.");
    return;
  }
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

  if (!api.available() || api.validate_owner == nullptr ||
      api.attach_renderer == nullptr || api.detach_renderer == nullptr ||
      api.pull_h264 == nullptr || api.free_buffer == nullptr) {
    ReplyError(result, kDecoderUnavailable,
               "The native H.264 decoder surface is unavailable.");
    return;
  }
  const auto validation_status = api.validate_owner(*owner_id);
  if (validation_status != 0) {
    ReplyError(result, NativeStatusCode(validation_status),
               "The native receive owner is no longer current.");
    return;
  }
  const auto attach_status = api.attach_renderer(*owner_id);
  if (attach_status != 0) {
    ReplyError(result, NativeStatusCode(attach_status),
               "The native renderer capability could not be attached.");
    return;
  }
  const auto start_status = api.start_owner(*owner_id);
  if (start_status != 0) {
    api.detach_renderer(*owner_id);
    ReplyError(result, NativeStatusCode(start_status),
               "The native receive owner could not be started.");
    return;
  }
  int64_t surface_id = -1;
  const auto decoder_status =
      decoder.Attach(*owner_id, &surface_id, *codec_mode);
  if (decoder_status != DecoderStatus::kOk) {
    api.stop_owner(*owner_id);
    api.detach_renderer(*owner_id);
    ReplyError(result, DecoderStatusCode(decoder_status),
               "The Windows H.264 decoder surface could not be attached.");
    return;
  }
  result->Success(EncodableMap{
      {EncodableValue("surface_id"),
       EncodableValue(std::to_string(surface_id))},
  });
}

void ReplyMediaStats(
    const flutter::EncodableMap& arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
    NativeMediaApi& api, WindowsCaptureManager& capture,
    WindowsDecoderManager& decoder) {
  const auto owner_id = OwnerIdArgument(arguments);
  if (!owner_id) {
    ReplyError(result, "invalid_argument", "A native owner token is required.");
    return;
  }

  if (!api.available()) {
    api = NativeMediaApi::Resolve();
  }
  if (!api.validation_available()) {
    ReplyError(result, kBackendFailure,
               "The native media owner validation is unavailable.");
    return;
  }
  const auto validation_status = api.validate_owner(*owner_id);
  if (validation_status != 0) {
    capture.Release(*owner_id);
    decoder.Release(*owner_id);
    ReplyError(result, NativeStatusCode(validation_status),
               "The native media owner is no longer current.");
    return;
  }

  NativeMediaStats native_stats;
  const NativeMediaStats* native_stats_ptr = nullptr;
  if (api.stats_available()) {
    const auto native_stats_status = api.read_stats(*owner_id, &native_stats);
    if (native_stats_status != 0) {
      ReplyError(result, NativeStatusCode(native_stats_status),
                 "The native media statistics are unavailable.");
      return;
    }
    if (native_stats.queue_capacity != 3 || native_stats.queue_depth > 3) {
      ReplyError(result, kBackendFailure,
                 "The native media statistics violate the fixed queue ABI.");
      return;
    }
    native_stats_ptr = &native_stats;
  }

  CaptureStats stats;
  const auto capture_status = capture.ReadStats(*owner_id, &stats);
  DecoderStats decoder_stats;
  const auto decoder_status = decoder.ReadStats(*owner_id, &decoder_stats);
  if (decoder_status == DecoderStatus::kNativeFailure) {
    const char* code = decoder_stats.terminal_status ==
                               realtime_media_windows::kDecoderTerminalFailed
                           ? kDecoderFailed
                           : NativeStatusCode(decoder_stats.terminal_status);
    const std::string message =
        std::string("Windows H.264 decoder failed at ") +
        decoder_stats.failure_stage + ".";
    ReplyError(result, code, message.c_str());
    return;
  }
  if (capture_status == CaptureStatus::kNotFound) {
    if (decoder_status == DecoderStatus::kOk) {
      result->Success(StatsMap(stats, &decoder_stats, native_stats_ptr));
    } else {
      // A receive owner may be valid before a native decoder is attached.
      result->Success(StatsMap(stats, nullptr, native_stats_ptr));
    }
    return;
  }
  if (capture_status != CaptureStatus::kOk) {
    if (capture_status == CaptureStatus::kNativeFailure) {
      if (stats.terminal_status ==
          realtime_media_windows::kCaptureTerminalEncoderFailed) {
        ReplyError(result, kEncoderFailed,
                   "The Windows H.264 encoder failed.");
      } else if (stats.terminal_status ==
                 realtime_media_windows::kCaptureTerminalResolutionChanged) {
        ReplyError(result, kCaptureSourceEnded,
                   "The capture resolution changed; restart the media owner.");
      } else if (stats.terminal_status ==
                 realtime_media_windows::kCaptureTerminalRecreateRequired) {
        ReplyError(result, kRecreateRequired,
                   "The Windows encoder target is inconsistent; recreate the "
                   "media owner.");
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
                      ? StatsMap(stats, &decoder_stats, native_stats_ptr)
                      : StatsMap(stats, nullptr, native_stats_ptr));
}

}  // namespace realtime_media_windows
