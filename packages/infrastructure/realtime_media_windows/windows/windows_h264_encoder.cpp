#include "windows_h264_encoder.h"

#include <d3d11.h>
#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>

#include <algorithm>
#include <cstring>
#include <utility>

#include <winrt/base.h>

namespace realtime_media_windows {
namespace {

constexpr uint32_t kFrameRateNumerator = 30;
constexpr uint32_t kFrameRateDenominator = 1;
constexpr uint32_t kBitrate = 4'000'000;

uint8_t ClampByte(int value) {
  return static_cast<uint8_t>(std::clamp(value, 0, 255));
}

int Luma(int red, int green, int blue) {
  return ((66 * red + 129 * green + 25 * blue + 128) >> 8) + 16;
}

int ChromaU(int red, int green, int blue) {
  return ((-38 * red - 74 * green + 112 * blue + 128) >> 8) + 128;
}

int ChromaV(int red, int green, int blue) {
  return ((112 * red - 94 * green - 18 * blue + 128) >> 8) + 128;
}

bool IsAnnexB(const uint8_t* data, size_t length) {
  return length >= 4 && data[0] == 0 && data[1] == 0 &&
         ((data[2] == 0 && data[3] == 1) || data[2] == 1);
}

bool ToAnnexB(const uint8_t* data,
             size_t length,
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

struct HardwareH264Encoder::Impl final {
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  winrt::com_ptr<IMFTransform> transform;
  winrt::com_ptr<ID3D11Texture2D> staging;
  uint32_t staging_width = 0;
  uint32_t staging_height = 0;
  uint32_t encoder_width = 0;
  uint32_t encoder_height = 0;
  DWORD output_buffer_size = 0;
  bool configured = false;
  bool failed = false;

  bool ReadbackToNv12(ID3D11Texture2D* texture,
                      std::vector<uint8_t>* output,
                      uint32_t* output_width,
                      uint32_t* output_height) {
    if (texture == nullptr || output == nullptr || output_width == nullptr ||
        output_height == nullptr || context == nullptr || device == nullptr) {
      return false;
    }
    D3D11_TEXTURE2D_DESC description = {};
    texture->GetDesc(&description);
    if (description.Width == 0 || description.Height == 0 ||
        description.Width > 16'384 || description.Height > 16'384) {
      return false;
    }
    // NV12 stores chroma in 2x2 blocks. Refuse odd capture sizes explicitly
    // instead of producing a malformed buffer that a hardware MFT may accept
    // and fail on asynchronously.
    if ((description.Width & 1u) != 0 || (description.Height & 1u) != 0) {
      return false;
    }
    if (description.Format != DXGI_FORMAT_B8G8R8A8_UNORM &&
        description.Format != DXGI_FORMAT_R8G8B8A8_UNORM) {
      return false;
    }
    if (staging == nullptr || staging_width != description.Width ||
        staging_height != description.Height) {
      D3D11_TEXTURE2D_DESC staging_description = description;
      staging_description.Usage = D3D11_USAGE_STAGING;
      staging_description.BindFlags = 0;
      staging_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      staging_description.MiscFlags = 0;
      staging = nullptr;
      if (FAILED(device->CreateTexture2D(&staging_description, nullptr,
                                         staging.put()))) {
        return false;
      }
      staging_width = description.Width;
      staging_height = description.Height;
    }

    context->CopyResource(staging.get(), texture);
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (FAILED(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      return false;
    }
    const size_t luma_size = static_cast<size_t>(staging_width) * staging_height;
    output->assign(luma_size + luma_size / 2, 0);
    const bool bgra = description.Format == DXGI_FORMAT_B8G8R8A8_UNORM;
    auto read_rgb = [&](uint32_t x, uint32_t y, int* red, int* green,
                        int* blue) {
      const auto* pixel = static_cast<const uint8_t*>(mapped.pData) +
                          static_cast<size_t>(y) * mapped.RowPitch +
                          static_cast<size_t>(x) * 4;
      if (bgra) {
        *blue = pixel[0];
        *green = pixel[1];
        *red = pixel[2];
      } else {
        *red = pixel[0];
        *green = pixel[1];
        *blue = pixel[2];
      }
    };
    for (uint32_t y = 0; y < staging_height; ++y) {
      for (uint32_t x = 0; x < staging_width; ++x) {
        int red = 0;
        int green = 0;
        int blue = 0;
        read_rgb(x, y, &red, &green, &blue);
        (*output)[static_cast<size_t>(y) * staging_width + x] =
            ClampByte(Luma(red, green, blue));
      }
    }
    const size_t chroma_offset = luma_size;
    for (uint32_t y = 0; y < staging_height; y += 2) {
      for (uint32_t x = 0; x < staging_width; x += 2) {
        int red_sum = 0;
        int green_sum = 0;
        int blue_sum = 0;
        uint32_t count = 0;
        for (uint32_t dy = 0; dy < 2 && y + dy < staging_height; ++dy) {
          for (uint32_t dx = 0; dx < 2 && x + dx < staging_width; ++dx) {
            int red = 0;
            int green = 0;
            int blue = 0;
            read_rgb(x + dx, y + dy, &red, &green, &blue);
            red_sum += red;
            green_sum += green;
            blue_sum += blue;
            ++count;
          }
        }
        const int red = red_sum / static_cast<int>(count);
        const int green = green_sum / static_cast<int>(count);
        const int blue = blue_sum / static_cast<int>(count);
        const size_t chroma_index = chroma_offset +
                                    static_cast<size_t>(y / 2) * staging_width + x;
        (*output)[chroma_index] = ClampByte(ChromaU(red, green, blue));
        if (x + 1 < staging_width) {
          (*output)[chroma_index + 1] = ClampByte(ChromaV(red, green, blue));
        }
      }
    }
    context->Unmap(staging.get(), 0);
    *output_width = staging_width;
    *output_height = staging_height;
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
             SUCCEEDED(MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1,
                                            1)) &&
             SUCCEEDED(type->SetUINT32(MF_MT_INTERLACE_MODE,
                                       MFVideoInterlace_Progressive));
    };
    if (!set_common(input_type.get(), MFVideoFormat_NV12) ||
        !set_common(output_type.get(), MFVideoFormat_H264) ||
        FAILED(output_type->SetUINT32(MF_MT_AVG_BITRATE, kBitrate)) ||
        FAILED(output_type->SetUINT32(MF_MT_MPEG2_PROFILE,
                                       eAVEncH264VProfile_Main))) {
      return false;
    }
    if (FAILED(transform->SetInputType(0, input_type.get(), 0)) ||
        FAILED(transform->SetOutputType(0, output_type.get(), 0))) {
      return false;
    }
    MFT_OUTPUT_STREAM_INFO stream_info = {};
    if (FAILED(transform->GetOutputStreamInfo(0, &stream_info))) return false;
    output_buffer_size = std::max<DWORD>(stream_info.cbSize, 64 * 1024);
    encoder_width = next_width;
    encoder_height = next_height;
    transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    configured = true;
    return true;
  }

  bool Drain(std::vector<EncodedAccessUnit>* output) {
    while (true) {
      winrt::com_ptr<IMFSample> sample;
      if (FAILED(MFCreateSample(sample.put()))) return false;
      winrt::com_ptr<IMFMediaBuffer> buffer;
      if (FAILED(MFCreateMemoryBuffer(output_buffer_size, buffer.put())) ||
          FAILED(sample->AddBuffer(buffer.get()))) {
        return false;
      }
      MFT_OUTPUT_DATA_BUFFER output_buffer = {};
      output_buffer.dwStreamID = 0;
      output_buffer.pSample = sample.get();
      DWORD status = 0;
      const HRESULT result = transform->ProcessOutput(0, 1, &output_buffer, &status);
      if (output_buffer.pEvents != nullptr) output_buffer.pEvents->Release();
      if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
      if (FAILED(result)) return false;
      winrt::com_ptr<IMFMediaBuffer> contiguous;
      if (FAILED(sample->ConvertToContiguousBuffer(contiguous.put()))) return false;
      BYTE* data = nullptr;
      DWORD max_length = 0;
      DWORD current_length = 0;
      if (FAILED(contiguous->Lock(&data, &max_length, &current_length))) return false;
      EncodedAccessUnit access_unit;
      const bool converted = ToAnnexB(data, current_length, &access_unit.payload);
      UINT32 clean_point = 0;
      sample->GetUINT32(MFSampleExtension_CleanPoint, &clean_point);
      access_unit.keyframe = clean_point != 0;
      contiguous->Unlock();
      if (!converted) return false;
      output->push_back(std::move(access_unit));
    }
  }
};

HardwareH264Encoder::HardwareH264Encoder(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

HardwareH264Encoder::~HardwareH264Encoder() {
  if (impl_ != nullptr && impl_->transform != nullptr) {
    impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
  }
}

std::unique_ptr<HardwareH264Encoder> HardwareH264Encoder::Create(
    ID3D11Device* device,
    ID3D11DeviceContext* context) {
  if (device == nullptr || context == nullptr) return nullptr;
  MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_NV12};
  MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** activations = nullptr;
  UINT32 count = 0;
  const HRESULT enum_result = MFTEnumEx(
      MFT_CATEGORY_VIDEO_ENCODER,
      MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &input_info,
      &output_info, &activations, &count);
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

  auto impl = std::make_unique<Impl>();
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(impl->device.put()))) ||
      FAILED(context->QueryInterface(IID_PPV_ARGS(impl->context.put())))) {
    return nullptr;
  }
  impl->transform = std::move(transform);
  return std::unique_ptr<HardwareH264Encoder>(
      new HardwareH264Encoder(std::move(impl)));
}

bool HardwareH264Encoder::Encode(ID3D11Texture2D* texture,
                                 uint64_t timestamp_90khz,
                                 std::vector<EncodedAccessUnit>* output) {
  if (impl_ == nullptr || impl_->failed || output == nullptr) return false;
  output->clear();
  std::vector<uint8_t> nv12;
  uint32_t frame_width = 0;
  uint32_t frame_height = 0;
  if (!impl_->ReadbackToNv12(texture, &nv12, &frame_width, &frame_height) ||
      !impl_->Configure(frame_width, frame_height)) {
    impl_->failed = true;
    return false;
  }
  winrt::com_ptr<IMFMediaBuffer> buffer;
  winrt::com_ptr<IMFSample> sample;
  if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(nv12.size()), buffer.put())) ||
      FAILED(MFCreateSample(sample.put()))) {
    impl_->failed = true;
    return false;
  }
  BYTE* destination = nullptr;
  DWORD max_length = 0;
  DWORD current_length = 0;
  if (FAILED(buffer->Lock(&destination, &max_length, &current_length)) ||
      max_length < nv12.size()) {
    if (destination != nullptr) buffer->Unlock();
    impl_->failed = true;
    return false;
  }
  std::memcpy(destination, nv12.data(), nv12.size());
  buffer->Unlock();
  buffer->SetCurrentLength(static_cast<DWORD>(nv12.size()));
  if (FAILED(sample->AddBuffer(buffer.get()))) {
    impl_->failed = true;
    return false;
  }
  const uint64_t whole_seconds = timestamp_90khz / 90'000ULL;
  const uint64_t remainder = timestamp_90khz % 90'000ULL;
  const uint64_t sample_time_ticks =
      whole_seconds * 10'000'000ULL + remainder * 10'000'000ULL / 90'000ULL;
  const LONGLONG sample_time = static_cast<LONGLONG>(sample_time_ticks);
  sample->SetSampleTime(sample_time);
  sample->SetSampleDuration(10'000'000 / kFrameRateNumerator);
  if (timestamp_90khz == 0) sample->SetUINT32(MFSampleExtension_CleanPoint, 1);
  if (FAILED(impl_->transform->ProcessInput(0, sample.get(), 0)) ||
      !impl_->Drain(output)) {
    impl_->failed = true;
    return false;
  }
  return true;
}

}  // namespace realtime_media_windows
