#include "windows_media_channel.h"

#include <windows.h>

#include <cstdlib>

namespace realtime_media_windows {
namespace {

constexpr char kBackendFailure[] = "backend_failure";
constexpr char kCaptureSourceEnded[] = "capture_source_ended";
constexpr char kDecoderUnavailable[] = "decoder_unavailable";
constexpr char kDecoderFailed[] = "decoder_failed";
constexpr char kEncoderUnavailable[] = "encoder_unavailable";
constexpr char kEncoderFailed[] = "encoder_failed";

}  // namespace

NativeMediaApi NativeMediaApi::Resolve() {
  NativeMediaApi api;
  const HMODULE module = GetModuleHandleW(L"network_ffi.dll");
  if (module == nullptr) return api;
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
    const flutter::EncodableMap& arguments,
    const char* key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) return std::nullopt;
  const auto* value = std::get_if<std::string>(&it->second);
  if (value == nullptr || value->empty() || value->size() > 128) {
    return std::nullopt;
  }
  return *value;
}

std::optional<uint64_t> OwnerIdArgument(const flutter::EncodableMap& arguments) {
  const auto token = StringArgument(arguments, "owner_token");
  if (!token) return std::nullopt;
  char* end = nullptr;
  const auto value = std::strtoull(token->c_str(), &end, 10);
  if (end == token->c_str() || *end != '\0' || value == 0) {
    return std::nullopt;
  }
  return value;
}

void ReplyError(
    const std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>&
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
    case CaptureStatus::kEncoderUnavailable:
      return kEncoderUnavailable;
    case CaptureStatus::kEncoderFailed:
      return kEncoderFailed;
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
                               const DecoderStats* decoder) {
  const int width = decoder != nullptr && decoder->width > 0 ? decoder->width
                                                               : stats.width;
  const int height = decoder != nullptr && decoder->height > 0
                         ? decoder->height
                         : stats.height;
  const auto frames_decoded = decoder == nullptr ? 0 : decoder->frames_decoded;
  const auto frames_rendered = decoder == nullptr ? 0 : decoder->frames_rendered;
  const auto frames_dropped =
      stats.frames_dropped + (decoder == nullptr ? 0 : decoder->frames_dropped);
  return flutter::EncodableMap{
      {flutter::EncodableValue("width"), flutter::EncodableValue(width)},
      {flutter::EncodableValue("height"), flutter::EncodableValue(height)},
      {flutter::EncodableValue("frames_captured"),
       flutter::EncodableValue(static_cast<int64_t>(stats.frames_captured))},
      {flutter::EncodableValue("frames_sent"),
       flutter::EncodableValue(static_cast<int64_t>(stats.frames_sent))},
      {flutter::EncodableValue("frames_dropped"),
       flutter::EncodableValue(static_cast<int64_t>(frames_dropped))},
      {flutter::EncodableValue("frames_decoded"),
       flutter::EncodableValue(static_cast<int64_t>(frames_decoded))},
      {flutter::EncodableValue("frames_rendered"),
       flutter::EncodableValue(static_cast<int64_t>(frames_rendered))},
      // Packet-level QoS counters are populated by the shared native media
      // owner in later platform wiring. Keep the method-channel shape stable
      // now and report bounded zero values until that owner is attached.
      {flutter::EncodableValue("packets_sent"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("packets_received"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("packets_lost"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("frames_recovered"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("keyframe_requests"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("jitter_ms"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("rtt_ms"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("queue_depth"), flutter::EncodableValue(0)},
      {flutter::EncodableValue("queue_capacity"), flutter::EncodableValue(3)},
  };
}

}  // namespace realtime_media_windows
