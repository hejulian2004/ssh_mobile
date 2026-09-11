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
constexpr uint32_t kFrameRateDenominator = 1;

uint64_t TimestampTo100Ns(uint64_t timestamp_90khz) {
  const uint64_t seconds = timestamp_90khz / 90'000ULL;
  const uint64_t remainder = timestamp_90khz % 90'000ULL;
  return seconds * 10'000'000ULL + remainder * 10'000'000ULL / 90'000ULL;
}

bool SetVideoType(IMFMediaType* type,
                  const GUID& subtype,
                  uint32_t width,
                  uint32_t height) {
  return type != nullptr &&
         SUCCEEDED(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video)) &&
         SUCCEEDED(type->SetGUID(MF_MT_SUBTYPE, subtype)) &&
         SUCCEEDED(MFSetAttributeSize(type, MF_MT_FRAME_SIZE, width, height)) &&
         SUCCEEDED(MFSetAttributeRatio(type, MF_MT_FRAME_RATE,
                                       kFrameRateNumerator,
                                       kFrameRateDenominator)) &&
         SUCCEEDED(MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1)) &&
         SUCCEEDED(type->SetUINT32(MF_MT_INTERLACE_MODE,
                                   MFVideoInterlace_Progressive));
}

class HardwareH264Decoder final {
 public:
  static std::unique_ptr<HardwareH264Decoder> Create(
      ID3D11Device* device,
      ID3D11DeviceContext* context) {
    if (device == nullptr || context == nullptr) return nullptr;
    MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_H264};
    MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_NV12};
    IMFActivate** activations = nullptr;
    UINT32 count = 0;
    const HRESULT result = MFTEnumEx(
        MFT_CATEGORY_VIDEO_DECODER,
        MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &input_info,
        &output_info, &activations, &count);
    if (FAILED(result) || activations == nullptr || count == 0) {
      if (activations != nullptr) CoTaskMemFree(activations);
      return nullptr;
    }
    winrt::com_ptr<IMFTransform> transform;
    for (UINT32 index = 0; index < count && transform == nullptr; ++index) {
      if (activations[index] != nullptr) {
        activations[index]->ActivateObject(IID_PPV_ARGS(transform.put()));
      }
    }
    for (UINT32 index = 0; index < count; ++index) {
      if (activations[index] != nullptr) activations[index]->Release();
    }
    CoTaskMemFree(activations);
    if (transform == nullptr) return nullptr;

    auto decoder = std::unique_ptr<HardwareH264Decoder>(
        new HardwareH264Decoder(std::move(transform)));
    if (!decoder->Initialize(device, context)) return nullptr;
    return decoder;
  }

  ~HardwareH264Decoder() {
    if (transform_ != nullptr) {
      transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
      transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }
  }

  HardwareH264Decoder(const HardwareH264Decoder&) = delete;
  HardwareH264Decoder& operator=(const HardwareH264Decoder&) = delete;

  bool Decode(const NativeH264FrameMetadata& metadata,
              const uint8_t* payload,
              size_t payload_length,
              winrt::com_ptr<ID3D11Texture2D>* output) {
    if (transform_ == nullptr || payload == nullptr || payload_length == 0 ||
        output == nullptr || payload_length > 4 * 1024 * 1024) {
      return false;
    }
    if (metadata.width == 0 || metadata.height == 0 ||
        metadata.width > 16'384 || metadata.height > 16'384) {
      return false;
    }
    if (!Configure(metadata.width, metadata.height)) return false;

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
    sample->SetSampleTime(static_cast<LONGLONG>(TimestampTo100Ns(metadata.timestamp)));
    sample->SetSampleDuration(10'000'000 / kFrameRateNumerator);
    if (metadata.keyframe != 0) sample->SetUINT32(MFSampleExtension_CleanPoint, 1);
    if (FAILED(transform_->ProcessInput(0, sample.get(), 0))) return false;
    return Drain(output);
  }

 private:
  explicit HardwareH264Decoder(winrt::com_ptr<IMFTransform> transform)
      : transform_(std::move(transform)) {}

  bool Initialize(ID3D11Device* device, ID3D11DeviceContext* context) {
    if (FAILED(device->QueryInterface(IID_PPV_ARGS(device_.put()))) ||
        FAILED(context->QueryInterface(IID_PPV_ARGS(context_.put())))) {
      return false;
    }
    UINT reset_token = 0;
    if (FAILED(MFCreateDXGIDeviceManager(&reset_token,
                                         device_manager_.put())) ||
        FAILED(device_manager_->ResetDevice(device_.get(), reset_token))) {
      return false;
    }
    transform_->ProcessMessage(
        MFT_MESSAGE_SET_D3D_MANAGER,
        reinterpret_cast<ULONG_PTR>(device_manager_.get()));
    winrt::com_ptr<IMFAttributes> attributes;
    if (SUCCEEDED(transform_->GetAttributes(attributes.put()))) {
      attributes->SetUINT32(MF_SA_D3D11_AWARE, 1);
    }
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
    MFT_OUTPUT_STREAM_INFO stream_info = {};
    if (FAILED(transform_->GetOutputStreamInfo(0, &stream_info))) return false;
    output_buffer_size_ = std::max<DWORD>(stream_info.cbSize, 64 * 1024);
    output_provides_samples_ =
        (stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;
    if (converter_ == nullptr || !converter_->Configure(width, height)) {
      return false;
    }
    width_ = width;
    height_ = height;
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    configured_ = true;
    return true;
  }

  bool Drain(winrt::com_ptr<ID3D11Texture2D>* output) {
    while (true) {
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
      if (FAILED(result) || output_buffer.pSample == nullptr) return false;

      winrt::com_ptr<IMFSample> produced_sample;
      if (output_buffer.pSample == supplied_sample.get()) {
        produced_sample = std::move(supplied_sample);
      } else {
        produced_sample.attach(output_buffer.pSample);
      }
      winrt::com_ptr<IMFMediaBuffer> media_buffer;
      if (FAILED(produced_sample->ConvertToContiguousBuffer(media_buffer.put()))) {
        return false;
      }
      winrt::com_ptr<IMFDXGIBuffer> dxgi_buffer;
      if (FAILED(media_buffer->QueryInterface(IID_PPV_ARGS(dxgi_buffer.put())))) {
        return false;
      }
      winrt::com_ptr<ID3D11Texture2D> texture;
      if (FAILED(dxgi_buffer->GetResource(IID_PPV_ARGS(texture.put()))) ||
          texture == nullptr) {
        return false;
      }
      D3D11_TEXTURE2D_DESC description = {};
      texture->GetDesc(&description);
      if (description.Format != DXGI_FORMAT_NV12 || converter_ == nullptr ||
          !converter_->Convert(texture.get(), output)) {
        return false;
      }
      return true;
    }
  }

  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<IMFDXGIDeviceManager> device_manager_;
  winrt::com_ptr<IMFTransform> transform_;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  DWORD output_buffer_size_ = 0;
  bool configured_ = false;
  bool output_provides_samples_ = false;
  std::unique_ptr<Nv12ToBgraConverter> converter_;
};

struct DecoderState final {
  uint64_t owner = 0;
  H264PullCallback pull = nullptr;
  H264BufferFreeCallback free_buffer = nullptr;
  flutter::TextureRegistrar* registrar = nullptr;
  std::unique_ptr<HardwareH264Decoder> decoder;
  std::unique_ptr<flutter::TextureVariant> texture;
  std::thread worker;
  std::mutex mutex;
  std::atomic<bool> stopped{false};
  std::atomic<int> terminal_status{0};
  std::atomic<uint64_t> frames_decoded{0};
  std::atomic<uint64_t> frames_rendered{0};
  std::atomic<uint64_t> frames_dropped{0};
  winrt::com_ptr<ID3D11Texture2D> latest_texture;
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
      winrt::com_ptr<ID3D11Texture2D> decoded_texture;
      const bool decoded = decoder->Decode(metadata, payload.ptr, payload.len,
                                           &decoded_texture);
      free_buffer(payload);
      if (!decoded) {
        frames_dropped.fetch_add(1);
        terminal_status.store(kDecoderTerminalFailed);
        stopped.store(true);
        break;
      }
      if (decoded_texture == nullptr) continue;
      {
        std::lock_guard<std::mutex> lock(mutex);
        latest_texture = std::move(decoded_texture);
        width = static_cast<int>(metadata.width);
        height = static_cast<int>(metadata.height);
        frames_decoded.fetch_add(1);
      }
      if (registrar == nullptr || !registrar->MarkTextureFrameAvailable(texture_id)) {
        terminal_status.store(kDecoderTerminalFailed);
        stopped.store(true);
        break;
      }
      frames_rendered.fetch_add(1);
    }
    if (com_initialized) CoUninitialize();
  }

  void Stop() {
    stopped.store(true);
    if (worker.joinable()) worker.join();
    if (registrar != nullptr && texture_id >= 0) {
      registrar->UnregisterTexture(texture_id);
      texture_id = -1;
    }
    std::lock_guard<std::mutex> lock(mutex);
    latest_texture = nullptr;
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
    if (com_initialized) mf_initialized = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
    if (!mf_initialized) return;
    constexpr D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                            D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL selected = D3D_FEATURE_LEVEL_11_0;
    const HRESULT device_result = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels, ARRAYSIZE(levels), D3D11_SDK_VERSION, d3d_device.put(),
        &selected, d3d_context.put());
    device_ready = SUCCEEDED(device_result) && d3d_device != nullptr &&
                   d3d_context != nullptr;
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

void WindowsDecoderManager::SetNativeCallbacks(H264PullCallback pull_callback,
                                                H264BufferFreeCallback free_callback) {
  std::lock_guard<std::mutex> lock(impl_->mutex);
  impl_->pull = pull_callback;
  impl_->free_buffer = free_callback;
}

DecoderStatus WindowsDecoderManager::Attach(uint64_t owner, int64_t* surface_id) {
  if (owner == 0 || surface_id == nullptr) return DecoderStatus::kBackendFailure;
  *surface_id = -1;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  if (impl_->decoders.find(owner) != impl_->decoders.end()) {
    return DecoderStatus::kDuplicate;
  }
  if (!impl_->device_ready || !impl_->mf_initialized || impl_->registrar == nullptr ||
      impl_->pull == nullptr || impl_->free_buffer == nullptr) {
    return DecoderStatus::kDecoderUnavailable;
  }
  auto decoder = HardwareH264Decoder::Create(impl_->d3d_device.get(),
                                              impl_->d3d_context.get());
  if (decoder == nullptr) return DecoderStatus::kDecoderUnavailable;
  auto state = std::make_shared<DecoderState>();
  state->owner = owner;
  state->pull = impl_->pull;
  state->free_buffer = impl_->free_buffer;
  state->registrar = impl_->registrar;
  state->decoder = std::move(decoder);
  const std::weak_ptr<DecoderState> weak_state = state;
  state->texture = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeD3d11Texture2D,
          [weak_state](size_t width, size_t height) {
            const auto state = weak_state.lock();
            return state == nullptr ? nullptr : state->Describe(width, height);
          }));
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
  return stats->terminal_status == 0 ? DecoderStatus::kOk
                                     : DecoderStatus::kNativeFailure;
}

}  // namespace realtime_media_windows
