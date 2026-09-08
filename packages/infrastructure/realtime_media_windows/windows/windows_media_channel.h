#ifndef REALTIME_MEDIA_WINDOWS_MEDIA_CHANNEL_H_
#define REALTIME_MEDIA_WINDOWS_MEDIA_CHANNEL_H_

#include "windows_capture.h"
#include "windows_h264_decoder.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace realtime_media_windows {

using OwnerCloseFunction = int(__cdecl *)(uint64_t);
using OwnerStartFunction = int(__cdecl *)(uint64_t);
using OwnerStopFunction = int(__cdecl *)(uint64_t);
using OwnerValidateFunction = int(__cdecl *)(uint64_t);
using OwnerRendererFunction = int(__cdecl *)(uint64_t);
using OwnerPushFunction = H264PushCallback;
using OwnerPullFunction = H264PullCallback;
using BufferFreeFunction = H264BufferFreeCallback;

struct NativeMediaApi {
  OwnerStartFunction start_owner = nullptr;
  OwnerStopFunction stop_owner = nullptr;
  OwnerValidateFunction validate_owner = nullptr;
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
                               const DecoderStats* decoder = nullptr);

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_MEDIA_CHANNEL_H_
