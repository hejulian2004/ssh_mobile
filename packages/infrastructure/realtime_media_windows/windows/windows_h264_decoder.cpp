#include "windows_h264_decoder.h"

#include "windows_video_processor.h"

#include <d3d11.h>
#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>

#include <flutter/texture_registrar.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <utility>

#include <winrt/base.h>

namespace realtime_media_windows {
namespace {

constexpr uint32_t kFrameRateNumerator = 30;

class NativeH264Decoder final {
 public:
  static std::unique_ptr<NativeH264Decoder> Create(ID3D11Device* device,
                                                   ID3D11DeviceContext* context,
                                                   NativeCodecMode mode) {
    if (mode == NativeCodecMode::Hardware &&
        (device == nullptr || context == nullptr))
      return nullptr;
    auto transform = CreateH264DecoderTransform(mode);
    if (transform == nullptr) return nullptr;
    auto decoder = std::unique_ptr<NativeH264Decoder>(
        new NativeH264Decoder(std::move(transform), mode));
    if (!decoder->Initialize(device, context)) return nullptr;
    return decoder;
  }

  ~NativeH264Decoder() {
    if (transform_ != nullptr) {
      transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
      transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }
  }

  NativeH264Decoder(const NativeH264Decoder&) = delete;
  NativeH264Decoder& operator=(const NativeH264Decoder&) = delete;

  bool Decode(const NativeH264FrameMetadata& metadata, const uint8_t* payload,
              size_t payload_length, DecodedVideoFrame* output) {
    if (transform_ == nullptr || payload == nullptr || payload_length == 0 ||
        output == nullptr || payload_length > 4 * 1024 * 1024) {
      return false;
    }
    if (metadata.width == 0 || metadata.height == 0 ||
        metadata.width > 16'384 || metadata.height > 16'384) {
      return false;
    }
    failure_stage_ = "configure";
    if (!Configure(metadata.width, metadata.height)) return false;
    failure_stage_ = "input_sample";

    winrt::com_ptr<IMFMediaBuffer> buffer;
    winrt::com_ptr<IMFSample> sample;
    if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(payload_length),
                                    buffer.put())) ||
        FAILED(MFCreateSample(sample.put()))) {
      return false;
    }
    BYTE* destination = nullptr;
    DWORD maximum_length = 0;
    DWORD current_length = 0;
    if (FAILED(buffer->Lock(&destination, &maximum_length, &current_length)) ||
        maximum_length < payload_length) {
      if (destination != nullptr) buffer->Unlock();
      return false;
    }
    std::memcpy(destination, payload, payload_length);
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(payload_length));
    if (FAILED(sample->AddBuffer(buffer.get()))) return false;
    sample->SetSampleTime(
        static_cast<LONGLONG>(TimestampTo100Ns(metadata.timestamp)));
    sample->SetSampleDuration(10'000'000 / kFrameRateNumerator);
    if (metadata.keyframe != 0)
      sample->SetUINT32(MFSampleExtension_CleanPoint, 1);
    if (!Drain(output)) return false;
    failure_stage_ = "input";
    if (FAILED(transform_->ProcessInput(0, sample.get(), 0))) return false;
    return Drain(output);
  }

  const char* FailureStage() const { return failure_stage_; }
  bool Reset() {
    if (transform_ == nullptr) return false;
    return SUCCEEDED(transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0));
  }

 private:
  explicit NativeH264Decoder(winrt::com_ptr<IMFTransform> transform,
                             NativeCodecMode mode)
      : transform_(std::move(transform)), mode_(mode) {}

  bool Initialize(ID3D11Device* device, ID3D11DeviceContext* context) {
    if (mode_ == NativeCodecMode::Cpu) return true;
    if (!InitializeHardwareDecoderDevice(transform_.get(), device,
                                         device_manager_.put()))
      return false;
    converter_ = std::make_unique<Nv12ToBgraConverter>();
    return converter_->Initialize(device, context);
  }

  bool Configure(uint32_t width, uint32_t height) {
    if (configured_ && width_ == width && height_ == height) return true;
    if (configured_) {
      transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
      transform_->SetInputType(0, nullptr, 0);
      transform_->SetOutputType(0, nullptr, 0);
      configured_ = false;
    }
    winrt::com_ptr<IMFMediaType> input_type;
    winrt::com_ptr<IMFMediaType> output_type;
    if (FAILED(MFCreateMediaType(input_type.put())) ||
        FAILED(MFCreateMediaType(output_type.put())) ||
        !SetVideoType(input_type.get(), MFVideoFormat_H264, width, height) ||
        !SetVideoType(output_type.get(), MFVideoFormat_NV12, width, height) ||
        FAILED(transform_->SetInputType(0, input_type.get(), 0)) ||
        FAILED(transform_->SetOutputType(0, output_type.get(), 0))) {
      return false;
    }
    if (!ReadDecoderOutputInfo(transform_.get(), &output_buffer_size_,
                               &output_provides_samples_))
      return false;
    if (mode_ == NativeCodecMode::Hardware &&
        (converter_ == nullptr || !converter_->Configure(width, height))) {
      return false;
    }
    width_ = width;
    height_ = height;
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    configured_ = true;
    return true;
  }

  bool Drain(DecodedVideoFrame* output) {
    for (unsigned iteration = 0; iteration < 32; ++iteration) {
      failure_stage_ = "output";
      winrt::com_ptr<IMFSample> supplied_sample;
      winrt::com_ptr<IMFMediaBuffer> supplied_buffer;
      MFT_OUTPUT_DATA_BUFFER output_buffer = {};
      if (!output_provides_samples_) {
        if (FAILED(MFCreateSample(supplied_sample.put())) ||
            FAILED(MFCreateMemoryBuffer(output_buffer_size_,
                                        supplied_buffer.put())) ||
            FAILED(supplied_sample->AddBuffer(supplied_buffer.get()))) {
          return false;
        }
        output_buffer.pSample = supplied_sample.get();
      }
      DWORD status = 0;
      const HRESULT result =
          transform_->ProcessOutput(0, 1, &output_buffer, &status);
      if (output_buffer.pEvents != nullptr) output_buffer.pEvents->Release();
      if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
      if (result == MF_E_TRANSFORM_STREAM_CHANGE) {
        failure_stage_ = "output_layout";
        if (!RefreshDecoderOutput(transform_.get(), width_, height_,
                                  &output_buffer_size_,
                                  &output_provides_samples_))
          return false;
        continue;
      }
      if (FAILED(result) || output_buffer.pSample == nullptr) return false;

      winrt::com_ptr<IMFSample> produced_sample;
      if (output_buffer.pSample == supplied_sample.get()) {
        produced_sample = std::move(supplied_sample);
      } else {
        produced_sample.attach(output_buffer.pSample);
      }
      failure_stage_ = "pixel_conversion";
      if (mode_ == NativeCodecMode::Cpu) {
        if (!ConvertSoftwareDecodedSample(transform_.get(),
                                          produced_sample.get(), width_,
                                          height_, &output->pixels))
          return false;
      } else if (!ConvertDecodedSample(produced_sample.get(), converter_.get(),
                                       &output->texture))
        return false;
    }
    return false;
  }

  NativeCodecMode mode_;
  const char* failure_stage_ = "decode";
  winrt::com_ptr<IMFDXGIDeviceManager> device_manager_;
  winrt::com_ptr<IMFTransform> transform_;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  uint32_t output_buffer_size_ = 0;
  bool configured_ = false;
  bool output_provides_samples_ = false;
  std::unique_ptr<Nv12ToBgraConverter> converter_;
};

struct DecoderState final {
  uint64_t owner = 0;
  H264PullCallback pull = nullptr;
  H264BufferFreeCallback free_buffer = nullptr;
  flutter::TextureRegistrar* registrar = nullptr;
  std::unique_ptr<NativeH264Decoder> decoder;
  std::unique_ptr<flutter::TextureVariant> texture;
  std::thread worker;
  std::mutex mutex;
  std::atomic<bool> stopped{false};
  std::atomic<bool> reset_requested{false};
  std::atomic<int> terminal_status{0};
  std::atomic<const char*> failure_stage{"decode"};
  std::atomic<uint64_t> frames_decoded{0};
  std::atomic<uint64_t> frames_rendered{0};
  std::atomic<uint64_t> frames_dropped{0};
  winrt::com_ptr<ID3D11Texture2D> latest_texture;
  std::shared_ptr<std::vector<uint8_t>> latest_pixels;
  const FlutterDesktopPixelBuffer* DescribePixels() {
    std::lock_guard<std::mutex> lock(mutex);
    if (stopped.load() || !latest_pixels) return nullptr;
    frames_rendered.fetch_add(1);
    return NativePixelFrameLease::Retain(latest_pixels, width, height);
  }
  FlutterDesktopGpuSurfaceDescriptor descriptor = {};
  int64_t texture_id = -1;
  int width = 0;
  int height = 0;

  static void ReleaseTexture(void* context) {
    if (context != nullptr) {
      static_cast<IUnknown*>(context)->Release();
    }
  }

  const FlutterDesktopGpuSurfaceDescriptor* Describe(size_t width_hint,
                                                     size_t height_hint) {
    std::lock_guard<std::mutex> lock(mutex);
    if (stopped.load() || latest_texture == nullptr) return nullptr;
    frames_rendered.fetch_add(1);
    latest_texture->AddRef();
    descriptor.struct_size = sizeof(descriptor);
    descriptor.handle = latest_texture.get();
    descriptor.width = width > 0 ? static_cast<size_t>(width) : width_hint;
    descriptor.height = height > 0 ? static_cast<size_t>(height) : height_hint;
    descriptor.visible_width = descriptor.width;
    descriptor.visible_height = descriptor.height;
    descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
    descriptor.release_callback = &ReleaseTexture;
    descriptor.release_context = latest_texture.get();
    return &descriptor;
  }

  void Run(const std::weak_ptr<DecoderState>& weak_state) {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com_initialized = com_result == S_OK || com_result == S_FALSE;
    while (!stopped.load()) {
      const auto state = weak_state.lock();
      if (!state || state.get() != this || stopped.load()) break;
      if (reset_requested.exchange(false)) {
        if (!decoder->Reset()) {
          terminal_status.store(kDecoderTerminalFailed);
          stopped.store(true);
          break;
        }
        std::lock_guard<std::mutex> lock(mutex);
        latest_texture = nullptr;
        latest_pixels.reset();
      }
      NativeH264FrameMetadata metadata;
      NativeH264Buffer payload;
      const int pull_status = pull(owner, &metadata, &payload);
      if (pull_status == 1) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        continue;
      }
      if (pull_status != 0 || payload.ptr == nullptr || payload.len == 0) {
        if (payload.ptr != nullptr || payload.len != 0) free_buffer(payload);
        terminal_status.store(pull_status == 0 ? kDecoderTerminalFailed
                                               : pull_status);
        stopped.store(true);
        break;
      }
      DecodedVideoFrame decoded_frame;
      const bool decoded =
          decoder->Decode(metadata, payload.ptr, payload.len, &decoded_frame);
      free_buffer(payload);
      if (stopped.load()) break;
      if (!decoded) {
        failure_stage.store(decoder->FailureStage());
        frames_dropped.fetch_add(1);
        terminal_status.store(kDecoderTerminalFailed);
        stopped.store(true);
        break;
      }
      if (decoded_frame.texture == nullptr && decoded_frame.pixels.empty())
        continue;
      {
        std::lock_guard<std::mutex> lock(mutex);
        latest_texture = std::move(decoded_frame.texture);
        latest_pixels = decoded_frame.pixels.empty()
                            ? nullptr
                            : std::make_shared<std::vector<uint8_t>>(
                                  std::move(decoded_frame.pixels));
        width = static_cast<int>(metadata.width);
        height = static_cast<int>(metadata.height);
        frames_decoded.fetch_add(1);
      }
      if (registrar == nullptr ||
          !registrar->MarkTextureFrameAvailable(texture_id)) {
        if (!stopped.load()) terminal_status.store(kDecoderTerminalFailed);
        stopped.store(true);
        break;
      }
    }
    if (com_initialized) CoUninitialize();
  }

  void Stop() {
    stopped.store(true);
    reset_requested.store(false);
    if (worker.joinable()) worker.join();
    if (registrar != nullptr && texture_id >= 0) {
      registrar->UnregisterTexture(texture_id);
      texture_id = -1;
    }
    std::lock_guard<std::mutex> lock(mutex);
    latest_texture = nullptr;
    latest_pixels.reset();
    texture.reset();
    decoder.reset();
  }
};

}  // namespace

struct WindowsDecoderManager::Impl final {
  explicit Impl(flutter::TextureRegistrar* texture_registrar)
      : registrar(texture_registrar) {
    const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    com_initialized = com_result == S_OK || com_result == S_FALSE;
    if (com_initialized || com_result == RPC_E_CHANGED_MODE) {
      mf_initialized = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
    }
  }

  ~Impl() {
    std::vector<std::shared_ptr<DecoderState>> states;
    {
      std::lock_guard<std::mutex> lock(mutex);
      for (auto& entry : decoders) states.push_back(entry.second);
      decoders.clear();
    }
    for (const auto& state : states) state->Stop();
    d3d_context = nullptr;
    d3d_device = nullptr;
    if (mf_initialized) MFShutdown();
    if (com_initialized) CoUninitialize();
  }

  flutter::TextureRegistrar* registrar = nullptr;
  H264PullCallback pull = nullptr;
  H264BufferFreeCallback free_buffer = nullptr;
  std::mutex mutex;
  std::unordered_map<uint64_t, std::shared_ptr<DecoderState>> decoders;
  winrt::com_ptr<ID3D11Device> d3d_device;
  winrt::com_ptr<ID3D11DeviceContext> d3d_context;
  bool com_initialized = false;
  bool mf_initialized = false;
  bool device_ready = false;
};

WindowsDecoderManager::WindowsDecoderManager(
    flutter::TextureRegistrar* texture_registrar)
    : impl_(std::make_unique<Impl>(texture_registrar)) {}

WindowsDecoderManager::~WindowsDecoderManager() = default;

void WindowsDecoderManager::SetNativeCallbacks(
    H264PullCallback pull_callback, H264BufferFreeCallback free_callback) {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->pull = pull_callback;
  impl_->free_buffer = free_callback;
}

DecoderStatus WindowsDecoderManager::Attach(uint64_t owner, int64_t* surface_id,
                                            NativeCodecMode mode) {
  if (owner == 0 || surface_id == nullptr)
    return DecoderStatus::kBackendFailure;
  *surface_id = -1;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  if (impl_->decoders.find(owner) != impl_->decoders.end()) {
    return DecoderStatus::kDuplicate;
  }
  if (mode == NativeCodecMode::Hardware && !impl_->device_ready &&
      impl_->mf_initialized) {
    impl_->device_ready = CreateHardwareDecoderGraphicsDevice(
        impl_->d3d_device.put(), impl_->d3d_context.put());
  }
  if ((mode == NativeCodecMode::Hardware && !impl_->device_ready) ||
      !impl_->mf_initialized || impl_->registrar == nullptr ||
      impl_->pull == nullptr || impl_->free_buffer == nullptr) {
    return DecoderStatus::kDecoderUnavailable;
  }
  auto decoder = NativeH264Decoder::Create(impl_->d3d_device.get(),
                                           impl_->d3d_context.get(), mode);
  if (decoder == nullptr) return DecoderStatus::kDecoderUnavailable;
  auto state = std::make_shared<DecoderState>();
  state->owner = owner;
  state->pull = impl_->pull;
  state->free_buffer = impl_->free_buffer;
  state->registrar = impl_->registrar;
  state->decoder = std::move(decoder);
  const std::weak_ptr<DecoderState> weak_state = state;
  state->texture = MakeDecodedVideoTexture(
      mode,
      [weak_state](size_t width, size_t height) {
        const auto state = weak_state.lock();
        return state == nullptr ? nullptr : state->Describe(width, height);
      },
      [weak_state](size_t, size_t) {
        const auto state = weak_state.lock();
        return state == nullptr ? nullptr : state->DescribePixels();
      });
  state->texture_id = impl_->registrar->RegisterTexture(state->texture.get());
  if (state->texture_id < 0) return DecoderStatus::kBackendFailure;
  *surface_id = state->texture_id;
  impl_->decoders.emplace(owner, state);
  state->worker = std::thread([state, weak_state] { state->Run(weak_state); });
  return DecoderStatus::kOk;
}

DecoderStatus WindowsDecoderManager::Detach(uint64_t owner) {
  std::shared_ptr<DecoderState> state;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto it = impl_->decoders.find(owner);
    if (it == impl_->decoders.end()) return DecoderStatus::kNotFound;
    state = it->second;
    impl_->decoders.erase(it);
  }
  state->Stop();
  return state->terminal_status.load() == 0 ? DecoderStatus::kOk
                                            : DecoderStatus::kNativeFailure;
}

DecoderStatus WindowsDecoderManager::Release(uint64_t owner) {
  return Detach(owner);
}

DecoderStatus WindowsDecoderManager::Reset(uint64_t owner) {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  const auto it = impl_->decoders.find(owner);
  if (it == impl_->decoders.end()) return DecoderStatus::kNotFound;
  const auto& state = it->second;
  if (state->stopped.load() || state->decoder == nullptr) {
    return DecoderStatus::kDecoderFailed;
  }
  state->reset_requested.store(true);
  return DecoderStatus::kOk;
}

DecoderStatus WindowsDecoderManager::ReadStats(uint64_t owner,
                                               DecoderStats* stats) {
  if (stats == nullptr) return DecoderStatus::kBackendFailure;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  const auto it = impl_->decoders.find(owner);
  if (it == impl_->decoders.end()) return DecoderStatus::kNotFound;
  const auto& state = it->second;
  std::lock_guard<std::mutex> state_lock(state->mutex);
  stats->width = state->width;
  stats->height = state->height;
  stats->frames_decoded = state->frames_decoded.load();
  stats->frames_rendered = state->frames_rendered.load();
  stats->frames_dropped = state->frames_dropped.load();
  stats->terminal_status = state->terminal_status.load();
  stats->failure_stage = state->failure_stage.load();
  return stats->terminal_status == 0 ? DecoderStatus::kOk
                                     : DecoderStatus::kNativeFailure;
}

}  // namespace realtime_media_windows
