#include "windows_h264_encoder.h"

#include <codecapi.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>
#include <oleauto.h>
#include <strmif.h>
#include <winrt/base.h>

#include <algorithm>
#include <cstring>
#include <utility>

#include "windows_video_processor.h"

namespace realtime_media_windows {
namespace {

constexpr uint32_t kFrameRateNumerator = 30;
constexpr uint32_t kFrameRateDenominator = 1;
constexpr uint32_t kBitrate = 3 * 1024 * 1'000;

bool IsAnnexB(const uint8_t* data, size_t length) {
  return length >= 4 && data[0] == 0 && data[1] == 0 &&
         ((data[2] == 0 && data[3] == 1) || data[2] == 1);
}

bool ToAnnexB(const uint8_t* data, size_t length,
              std::vector<uint8_t>* output) {
  if (data == nullptr || length == 0 || output == nullptr) return false;
  if (IsAnnexB(data, length)) {
    output->assign(data, data + length);
    return true;
  }

  // Media Foundation H.264 MFTs commonly return four-byte length-prefixed
  // NAL units. Normalize those units to the Annex-B contract consumed by the
  // Phase 2 native packetizer.
  size_t offset = 0;
  output->clear();
  while (offset + sizeof(uint32_t) <= length) {
    const uint32_t nalu_length =
        (static_cast<uint32_t>(data[offset]) << 24) |
        (static_cast<uint32_t>(data[offset + 1]) << 16) |
        (static_cast<uint32_t>(data[offset + 2]) << 8) |
        static_cast<uint32_t>(data[offset + 3]);
    offset += sizeof(uint32_t);
    if (nalu_length == 0 || nalu_length > length - offset) return false;
    output->insert(output->end(), {0, 0, 0, 1});
    output->insert(output->end(), data + offset, data + offset + nalu_length);
    offset += nalu_length;
  }
  return offset == length && !output->empty();
}

}  // namespace

struct NativeH264Encoder::Impl final {
  std::unique_ptr<BgraToNv12Readback> readback;

  winrt::com_ptr<IMFTransform> transform;
  winrt::com_ptr<IMFMediaEventGenerator> events;
  uint32_t input_ready = 0;
  uint32_t output_ready = 0;
  DWORD output_flags = 0;

  uint32_t encoder_width = 0;
  uint32_t encoder_height = 0;
  DWORD output_buffer_size = 0;
  std::vector<uint8_t> snapshot_nv12;
  bool configured = false;
  bool failed = false;

  bool PollEvents() {
    if (events == nullptr) return true;
    for (int count = 0; count < 64; ++count) {
      winrt::com_ptr<IMFMediaEvent> event;
      const HRESULT result =
          events->GetEvent(MF_EVENT_FLAG_NO_WAIT, event.put());
      if (result == MF_E_NO_EVENTS_AVAILABLE) return true;
      if (FAILED(result)) return false;
      MediaEventType type = MEUnknown;
      HRESULT status = S_OK;
      if (FAILED(event->GetType(&type)) || FAILED(event->GetStatus(&status)) ||
          FAILED(status))
        return false;
      if (type == METransformNeedInput)
        input_ready = std::min<uint32_t>(input_ready + 1, 64);
      if (type == METransformHaveOutput)
        output_ready = std::min<uint32_t>(output_ready + 1, 64);
    }
    return true;
  }

  bool Configure(uint32_t next_width, uint32_t next_height) {
    if (transform == nullptr || next_width == 0 || next_height == 0) {
      return false;
    }
    if (configured && encoder_width == next_width &&
        encoder_height == next_height) {
      return true;
    }
    if (configured) {
      transform->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
      transform->SetInputType(0, nullptr, 0);
      transform->SetOutputType(0, nullptr, 0);
      configured = false;
    }

    winrt::com_ptr<IMFMediaType> input_type;
    winrt::com_ptr<IMFMediaType> output_type;
    if (FAILED(MFCreateMediaType(input_type.put())) ||
        FAILED(MFCreateMediaType(output_type.put()))) {
      return false;
    }
    const auto set_common = [&](IMFMediaType* type, const GUID& subtype) {
      return SUCCEEDED(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video)) &&
             SUCCEEDED(type->SetGUID(MF_MT_SUBTYPE, subtype)) &&
             SUCCEEDED(MFSetAttributeSize(type, MF_MT_FRAME_SIZE, next_width,
                                          next_height)) &&
             SUCCEEDED(MFSetAttributeRatio(type, MF_MT_FRAME_RATE,
                                           kFrameRateNumerator,
                                           kFrameRateDenominator)) &&
             SUCCEEDED(
                 MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1)) &&
             SUCCEEDED(type->SetUINT32(MF_MT_INTERLACE_MODE,
                                       MFVideoInterlace_Progressive));
    };
    if (!set_common(input_type.get(), MFVideoFormat_NV12) ||
        !set_common(output_type.get(), MFVideoFormat_H264) ||
        FAILED(output_type->SetUINT32(MF_MT_AVG_BITRATE, kBitrate)) ||
        FAILED(output_type->SetUINT32(MF_MT_MPEG2_PROFILE,
                                      eAVEncH264VProfile_Base))) {
      return false;
    }
    if (FAILED(transform->SetOutputType(0, output_type.get(), 0)) ||
        FAILED(transform->SetInputType(0, input_type.get(), 0))) {
      return false;
    }
    MFT_OUTPUT_STREAM_INFO stream_info = {};
    if (FAILED(transform->GetOutputStreamInfo(0, &stream_info))) return false;
    output_buffer_size = std::max<DWORD>(stream_info.cbSize, 64 * 1024);
    output_flags = stream_info.dwFlags;
    encoder_width = next_width;
    encoder_height = next_height;
    transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    configured = true;
    return true;
  }

  bool Drain(std::vector<EncodedAccessUnit>* output) {
    if (!PollEvents()) return false;
    while (true) {
      if (events != nullptr && output_ready == 0) return true;
      winrt::com_ptr<IMFSample> sample;
      winrt::com_ptr<IMFMediaBuffer> buffer;
      if (!(output_flags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) &&
          (FAILED(MFCreateSample(sample.put())) ||
           FAILED(MFCreateMemoryBuffer(output_buffer_size, buffer.put())) ||
           FAILED(sample->AddBuffer(buffer.get())))) {
        return false;
      }
      MFT_OUTPUT_DATA_BUFFER output_buffer = {};
      output_buffer.dwStreamID = 0;
      output_buffer.pSample = sample.get();
      DWORD status = 0;
      const HRESULT result =
          transform->ProcessOutput(0, 1, &output_buffer, &status);
      if (events != nullptr) --output_ready;
      if (output_buffer.pEvents != nullptr) output_buffer.pEvents->Release();
      if (sample == nullptr) sample.attach(output_buffer.pSample);
      if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
      if (FAILED(result)) return false;
      if (sample == nullptr) return false;
      winrt::com_ptr<IMFMediaBuffer> contiguous;
      if (FAILED(sample->ConvertToContiguousBuffer(contiguous.put())))
        return false;
      BYTE* data = nullptr;
      DWORD max_length = 0;
      DWORD current_length = 0;
      if (FAILED(contiguous->Lock(&data, &max_length, &current_length)))
        return false;
      EncodedAccessUnit access_unit;
      access_unit.width = encoder_width;
      access_unit.height = encoder_height;
      const bool converted =
          ToAnnexB(data, current_length, &access_unit.payload);
      UINT32 clean_point = 0;
      sample->GetUINT32(MFSampleExtension_CleanPoint, &clean_point);
      access_unit.keyframe = clean_point != 0;
      contiguous->Unlock();
      if (!converted) return false;
      output->push_back(std::move(access_unit));
    }
  }
  bool Submit(uint64_t timestamp_90khz,
              std::vector<EncodedAccessUnit>* output) {
    if (!Drain(output)) {
      failed = true;
      return false;
    }
    if (events != nullptr && input_ready == 0) return true;
    winrt::com_ptr<IMFMediaBuffer> buffer;
    winrt::com_ptr<IMFSample> sample;
    if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(snapshot_nv12.size()),
                                    buffer.put())) ||
        FAILED(MFCreateSample(sample.put()))) {
      failed = true;
      return false;
    }
    BYTE* destination = nullptr;
    DWORD max_length = 0;
    DWORD current_length = 0;
    if (FAILED(buffer->Lock(&destination, &max_length, &current_length)) ||
        max_length < snapshot_nv12.size()) {
      if (destination != nullptr) buffer->Unlock();
      failed = true;
      return false;
    }
    std::memcpy(destination, snapshot_nv12.data(), snapshot_nv12.size());
    buffer->Unlock();
    buffer->SetCurrentLength(static_cast<DWORD>(snapshot_nv12.size()));
    if (FAILED(sample->AddBuffer(buffer.get()))) {
      failed = true;
      return false;
    }
    const uint64_t whole_seconds = timestamp_90khz / 90'000ULL;
    const uint64_t remainder = timestamp_90khz % 90'000ULL;
    const uint64_t sample_time_ticks =
        whole_seconds * 10'000'000ULL + remainder * 10'000'000ULL / 90'000ULL;
    const LONGLONG sample_time = static_cast<LONGLONG>(sample_time_ticks);
    sample->SetSampleTime(sample_time);
    sample->SetSampleDuration(10'000'000 / kFrameRateNumerator);
    if (timestamp_90khz == 0)
      sample->SetUINT32(MFSampleExtension_CleanPoint, 1);
    if (events != nullptr) --input_ready;
    if (FAILED(transform->ProcessInput(0, sample.get(), 0)) || !Drain(output)) {
      failed = true;
      return false;
    }
    return true;
  }
};

NativeH264Encoder::NativeH264Encoder(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

NativeH264Encoder::~NativeH264Encoder() {
  if (impl_ != nullptr && impl_->transform != nullptr) {
    impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
  }
}

std::unique_ptr<NativeH264Encoder> NativeH264Encoder::Create(
    ID3D11Device* device, ID3D11DeviceContext* context, NativeCodecMode mode) {
  if (device == nullptr || context == nullptr) return nullptr;
  MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_NV12};
  MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** activations = nullptr;
  UINT32 count = 0;
  const HRESULT enum_result =
      MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                (mode == NativeCodecMode::Cpu ? MFT_ENUM_FLAG_SYNCMFT
                                              : MFT_ENUM_FLAG_HARDWARE) |
                    MFT_ENUM_FLAG_SORTANDFILTER,
                &input_info, &output_info, &activations, &count);
  if (FAILED(enum_result) || activations == nullptr || count == 0) {
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
  winrt::com_ptr<IMFAttributes> attributes;
  uint32_t asynchronous = 0;
  if (FAILED(transform->GetAttributes(attributes.put()))) return nullptr;
  attributes->GetUINT32(MF_TRANSFORM_ASYNC, &asynchronous);
  if (asynchronous &&
      FAILED(attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE)))
    return nullptr;
  if (mode == NativeCodecMode::Cpu) {
    winrt::com_ptr<ICodecAPI> codec;
    VARIANT low_latency{};
    low_latency.vt = VT_BOOL;
    low_latency.boolVal = VARIANT_TRUE;
    if (FAILED(transform->QueryInterface(IID_PPV_ARGS(codec.put()))) ||
        FAILED(codec->SetValue(&CODECAPI_AVLowLatencyMode, &low_latency)))
      return nullptr;
  }

  auto impl = std::make_unique<Impl>();
  if (asynchronous &&
      FAILED(transform->QueryInterface(IID_PPV_ARGS(impl->events.put()))))
    return nullptr;
  impl->readback = std::make_unique<BgraToNv12Readback>(device, context);
  impl->transform = std::move(transform);
  return std::unique_ptr<NativeH264Encoder>(
      new NativeH264Encoder(std::move(impl)));
}

bool NativeH264Encoder::Encode(ID3D11Texture2D* texture,
                               uint64_t timestamp_90khz,
                               std::vector<EncodedAccessUnit>* output) {
  if (impl_ == nullptr || impl_->failed || output == nullptr) return false;
  output->clear();
  std::vector<uint8_t> nv12;
  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  if (!impl_->readback->Read(texture, &nv12, &frame_width, &frame_height) ||
      !impl_->Configure(frame_width, frame_height)) {
    impl_->failed = true;
    return false;
  }
  impl_->snapshot_nv12 = std::move(nv12);
  return impl_->Submit(timestamp_90khz, output);
}

bool NativeH264Encoder::ApplyAdaptation(uint32_t bitrate_kbps) {
  if (impl_ == nullptr || impl_->failed || impl_->transform == nullptr ||
      bitrate_kbps < 256 || bitrate_kbps > 3 * 1024) {
    return false;
  }
  winrt::com_ptr<ICodecAPI> codec_api;
  if (FAILED(impl_->transform->QueryInterface(IID_PPV_ARGS(codec_api.put()))) ||
      codec_api == nullptr) {
    return false;
  }
  VARIANT value;
  VariantInit(&value);
  value.vt = VT_UI4;
  value.ulVal = bitrate_kbps * 1'000;
  const HRESULT result =
      codec_api->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &value);
  VariantClear(&value);
  if (FAILED(result)) {
    impl_->failed = true;
    return false;
  }
  return true;
}

bool NativeH264Encoder::RepeatFrame(uint64_t timestamp_90khz,
                                    std::vector<EncodedAccessUnit>* output) {
  if (impl_ == nullptr || impl_->failed || output == nullptr) return false;
  output->clear();
  if (impl_->snapshot_nv12.empty()) return true;
  return impl_->Submit(timestamp_90khz, output);
}

bool NativeH264Encoder::RequestKeyframe() {
  if (impl_ == nullptr || impl_->failed || impl_->transform == nullptr) {
    return false;
  }
  winrt::com_ptr<ICodecAPI> codec_api;
  if (FAILED(impl_->transform->QueryInterface(IID_PPV_ARGS(codec_api.put()))) ||
      codec_api == nullptr) {
    return false;
  }
  VARIANT value;
  VariantInit(&value);
  value.vt = VT_UI4;
  value.ulVal = 1;
  const HRESULT result =
      codec_api->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &value);
  VariantClear(&value);
  if (FAILED(result)) {
    impl_->failed = true;
    return false;
  }
  return true;
}

}  // namespace realtime_media_windows
