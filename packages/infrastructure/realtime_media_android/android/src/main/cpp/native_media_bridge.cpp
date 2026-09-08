#include <jni.h>

#include <dlfcn.h>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace {

struct FrameMetadata {
  uint64_t sequence = 0;
  uint64_t timestamp = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint8_t keyframe = 0;
};

// Keep this layout locked to the Rust `#[repr(C)]` frame metadata. A mismatch
// would corrupt every native push/pull call, so fail the platform build rather
// than attempting a best-effort translation.
static_assert(sizeof(FrameMetadata) == 32,
              "FrameMetadata must match the Rust C ABI");
static_assert(offsetof(FrameMetadata, sequence) == 0);
static_assert(offsetof(FrameMetadata, timestamp) == 8);
static_assert(offsetof(FrameMetadata, width) == 16);
static_assert(offsetof(FrameMetadata, height) == 20);
static_assert(offsetof(FrameMetadata, keyframe) == 24);

struct NativeBuffer {
  uint8_t* ptr = nullptr;
  size_t len = 0;
};

static_assert(sizeof(NativeBuffer) == sizeof(void*) + sizeof(size_t),
              "NativeBuffer must match the Rust C ABI");

using OwnerStatusFunction = int (*)(uint64_t);
using OwnerAdaptationFunction = int (*)(uint64_t, uint32_t, uint32_t, uint32_t,
                                        uint32_t, uint32_t);
using PushFunction = int (*)(uint64_t, FrameMetadata, const uint8_t*, size_t);
using PullFunction = int (*)(uint64_t, FrameMetadata*, NativeBuffer*);
using BufferFreeFunction = void (*)(NativeBuffer);

constexpr int kNoFrame = 1;
constexpr int kDriverUnavailable = -9;
constexpr int kInternal = -3;
constexpr size_t kMaxFrameBytes = 4 * 1024 * 1024;

void* ResolveSymbol(const char* name) {
  if (name == nullptr) return nullptr;
  static std::mutex mutex;
  static void* network_library = nullptr;
  std::lock_guard<std::mutex> lock(mutex);
  void* symbol = dlsym(RTLD_DEFAULT, name);
  if (symbol != nullptr) return symbol;
  if (network_library == nullptr) {
    network_library = dlopen("libnetwork_ffi.so", RTLD_NOW | RTLD_NOLOAD);
  }
  return network_library == nullptr ? nullptr : dlsym(network_library, name);
}

template <typename Function>
Function Resolve(const char* name) {
  return reinterpret_cast<Function>(ResolveSymbol(name));
}

int ResolveOwnerStatus(const char* name, uint64_t owner) {
  const auto function = Resolve<OwnerStatusFunction>(name);
  return function == nullptr ? kDriverUnavailable : function(owner);
}

int ResolveOwnerAdaptation(uint64_t owner, uint32_t bitrate_kbps,
                           uint32_t framerate, uint32_t width, uint32_t height,
                           uint32_t reason) {
  const auto function = Resolve<OwnerAdaptationFunction>(
      "ssh_net_realtime_media_owner_apply_adaptation");
  return function == nullptr
             ? kDriverUnavailable
             : function(owner, bitrate_kbps, framerate, width, height, reason);
}

jobject NewFrame(JNIEnv* env, jint status, const FrameMetadata& metadata,
                 const uint8_t* payload, size_t payload_length) {
  if (env == nullptr) return nullptr;
  jclass frame_class = env->FindClass(
      "com/hejulian/realtime_media_android/NativeH264Frame");
  if (frame_class == nullptr) return nullptr;
  jmethodID constructor = env->GetMethodID(frame_class, "<init>",
                                            "(IJJIIZ[B)V");
  if (constructor == nullptr) return nullptr;
  if (payload_length > kMaxFrameBytes) payload_length = 0;
  jbyteArray bytes = env->NewByteArray(static_cast<jsize>(payload_length));
  if (bytes == nullptr && payload_length != 0) return nullptr;
  if (payload_length != 0) {
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(payload_length),
                            reinterpret_cast<const jbyte*>(payload));
    if (env->ExceptionCheck()) return nullptr;
  }
  const jboolean keyframe = metadata.keyframe != 0 ? JNI_TRUE : JNI_FALSE;
  return env->NewObject(frame_class, constructor, status,
                        static_cast<jlong>(metadata.sequence),
                        static_cast<jlong>(metadata.timestamp),
                        static_cast<jint>(metadata.width),
                        static_cast<jint>(metadata.height), keyframe, bytes);
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeValidateOwner(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_validate",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeStartOwner(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_start",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeStopOwner(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_stop",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeAttachRenderer(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_attach_renderer",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeDetachRenderer(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_detach_renderer",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeRequestKeyframe(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_request_keyframe",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeResetDecoder(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_reset_decoder",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeApplyAdaptation(
    JNIEnv*, jclass, jlong owner, jint bitrate_kbps, jint framerate, jint width,
    jint height, jint reason) {
  if (owner <= 0 || bitrate_kbps < 0 || framerate < 0 || width < 0 ||
      height < 0 || reason < 0) {
    return -1;
  }
  return ResolveOwnerAdaptation(static_cast<uint64_t>(owner),
                                static_cast<uint32_t>(bitrate_kbps),
                                static_cast<uint32_t>(framerate),
                                static_cast<uint32_t>(width),
                                static_cast<uint32_t>(height),
                                static_cast<uint32_t>(reason));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativeCloseOwner(
    JNIEnv*, jclass, jlong owner) {
  return ResolveOwnerStatus("ssh_net_realtime_media_owner_close",
                           static_cast<uint64_t>(owner));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativePushH264(
    JNIEnv* env, jclass, jlong owner, jlong sequence, jlong timestamp,
    jint width, jint height, jboolean keyframe, jbyteArray payload) {
  if (env == nullptr || payload == nullptr || owner <= 0 || width <= 0 ||
      height <= 0) {
    return -1;
  }
  const jsize length = env->GetArrayLength(payload);
  if (length <= 0 || static_cast<size_t>(length) > kMaxFrameBytes) return -1;
  const auto function = Resolve<PushFunction>(
      "ssh_net_realtime_media_owner_push_h264");
  if (function == nullptr) return kDriverUnavailable;
  std::vector<uint8_t> bytes(static_cast<size_t>(length));
  env->GetByteArrayRegion(payload, 0, length,
                          reinterpret_cast<jbyte*>(bytes.data()));
  if (env->ExceptionCheck()) return kInternal;
  FrameMetadata metadata{static_cast<uint64_t>(sequence),
                         static_cast<uint64_t>(timestamp),
                         static_cast<uint32_t>(width),
                         static_cast<uint32_t>(height),
                         static_cast<uint8_t>(keyframe == JNI_TRUE ? 1 : 0)};
  return function(static_cast<uint64_t>(owner), metadata, bytes.data(),
                  bytes.size());
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_hejulian_realtime_1media_1android_NativeMediaBridge_nativePullH264(
    JNIEnv* env, jclass, jlong owner) {
  if (env == nullptr || owner <= 0) return nullptr;
  const auto function = Resolve<PullFunction>(
      "ssh_net_realtime_media_owner_pull_h264");
  const auto free_function =
      Resolve<BufferFreeFunction>("ssh_net_buffer_free");
  if (function == nullptr || free_function == nullptr) {
    FrameMetadata metadata;
    return NewFrame(env, kDriverUnavailable, metadata, nullptr, 0);
  }
  FrameMetadata metadata;
  NativeBuffer buffer;
  const int status = function(static_cast<uint64_t>(owner), &metadata, &buffer);
  if (status == kNoFrame) return nullptr;
  if (status != 0 || buffer.ptr == nullptr || buffer.len == 0 ||
      buffer.len > kMaxFrameBytes) {
    if (buffer.ptr != nullptr || buffer.len != 0) free_function(buffer);
    return NewFrame(env, status == 0 ? kInternal : status, metadata, nullptr,
                    0);
  }
  jobject frame = NewFrame(env, 0, metadata, buffer.ptr, buffer.len);
  free_function(buffer);
  return frame;
}
