#ifndef REALTIME_MEDIA_WINDOWS_MEDIA_CHANNEL_H_
#define REALTIME_MEDIA_WINDOWS_MEDIA_CHANNEL_H_

#include "windows_capture.h"
#include "windows_h264_decoder.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace realtime_media_windows {

// Fixed-width, payload-free queue/recovery and RTP counters returned by the
// native owner. Keep this layout identical to SshNetRealtimeMediaStats in
// network-ffi; it is never exposed as a Dart frame or texture payload.
struct NativeMediaStats {
  uint64_t enqueued = 0;
  uint64_t dequeued = 0;
  uint64_t dropped = 0;
  uint64_t keyframe_requests = 0;
  uint64_t packets_sent = 0;
  uint64_t packets_received = 0;
  uint64_t packets_lost = 0;
  uint64_t frames_recovered = 0;
  uint64_t jitter_ms = 0;
  uint64_t rtt_ms = 0;
  uint32_t queue_depth = 0;
  uint32_t queue_capacity = 3;
};

static_assert(sizeof(NativeMediaStats) == 88,
              "Windows and Rust media stats layouts must stay ABI-identical");
static_assert(offsetof(NativeMediaStats, enqueued) == 0);
static_assert(offsetof(NativeMediaStats, dequeued) == 8);
static_assert(offsetof(NativeMediaStats, dropped) == 16);
static_assert(offsetof(NativeMediaStats, keyframe_requests) == 24);
static_assert(offsetof(NativeMediaStats, packets_sent) == 32);
static_assert(offsetof(NativeMediaStats, packets_received) == 40);
static_assert(offsetof(NativeMediaStats, packets_lost) == 48);
static_assert(offsetof(NativeMediaStats, frames_recovered) == 56);
static_assert(offsetof(NativeMediaStats, jitter_ms) == 64);
static_assert(offsetof(NativeMediaStats, rtt_ms) == 72);
static_assert(offsetof(NativeMediaStats, queue_depth) == 80);
static_assert(offsetof(NativeMediaStats, queue_capacity) == 84);

using OwnerCloseFunction = int(__cdecl *)(uint64_t);
using OwnerStartFunction = int(__cdecl *)(uint64_t);
using OwnerStopFunction = int(__cdecl *)(uint64_t);
using OwnerValidateFunction = int(__cdecl *)(uint64_t);
using OwnerRecoveryFunction = int(__cdecl *)(uint64_t);
using OwnerStatsFunction = int(__cdecl *)(uint64_t, NativeMediaStats*);
using OwnerAdaptationFunction = int(__cdecl *)(uint64_t, uint32_t, uint32_t,
                                                uint32_t, uint32_t, uint32_t);
using OwnerRendererFunction = int(__cdecl *)(uint64_t);
using OwnerPushFunction = H264PushCallback;
using OwnerPullFunction = H264PullCallback;
using BufferFreeFunction = H264BufferFreeCallback;

struct NativeMediaApi {
  OwnerStartFunction start_owner = nullptr;
  OwnerStopFunction stop_owner = nullptr;
  OwnerValidateFunction validate_owner = nullptr;
  OwnerRecoveryFunction request_keyframe = nullptr;
  OwnerRecoveryFunction reset_decoder = nullptr;
  OwnerStatsFunction read_stats = nullptr;
  OwnerAdaptationFunction apply_adaptation = nullptr;
  OwnerCloseFunction close_owner = nullptr;
  OwnerRendererFunction attach_renderer = nullptr;
  OwnerRendererFunction detach_renderer = nullptr;
  OwnerPushFunction push_h264 = nullptr;
  OwnerPullFunction pull_h264 = nullptr;
  BufferFreeFunction free_buffer = nullptr;

  bool available() const { return close_owner != nullptr; }
  bool lifecycle_available() const {
    return start_owner != nullptr && stop_owner != nullptr &&
           close_owner != nullptr;
  }
  bool validation_available() const { return validate_owner != nullptr; }
  bool stats_available() const { return read_stats != nullptr; }

  static NativeMediaApi Resolve();
};

std::optional<std::string> StringArgument(
    const flutter::EncodableMap& arguments,
    const char* key);
std::optional<uint64_t> OwnerIdArgument(const flutter::EncodableMap& arguments);
void ReplyError(
    const std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>&
        result,
    const char* code,
    const char* message);
const char* NativeStatusCode(int status);
const char* CaptureStatusCode(CaptureStatus status);
const char* DecoderStatusCode(DecoderStatus status);
flutter::EncodableMap StatsMap(const CaptureStats& stats,
                               const DecoderStats* decoder = nullptr,
                               const NativeMediaStats* native = nullptr);

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_MEDIA_CHANNEL_H_
