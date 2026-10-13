#include "windows_video_processor.h"

#include <mfapi.h>
#include <codecapi.h>
#include <strmif.h>
#include <algorithm>
#include <mftransform.h>
#include <d3d10.h>

namespace realtime_media_windows {
std::unique_ptr<flutter::TextureVariant> MakeDecodedVideoTexture(
    NativeCodecMode mode,
    flutter::GpuSurfaceTexture::ObtainDescriptorCallback gpu,
    flutter::PixelBufferTexture::CopyBufferCallback cpu) {
  if (mode == NativeCodecMode::Cpu)
    return std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture(std::move(cpu)));
  return std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
      kFlutterDesktopGpuSurfaceTypeD3d11Texture2D, std::move(gpu)));
}
bool CreateHardwareDecoderGraphicsDevice(ID3D11Device** device,
                                         ID3D11DeviceContext** context) {
  constexpr D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                          D3D_FEATURE_LEVEL_11_0};
  D3D_FEATURE_LEVEL selected = D3D_FEATURE_LEVEL_11_0;
  return SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                     D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
                                     ARRAYSIZE(levels), D3D11_SDK_VERSION,
                                     device, &selected, context));
}
winrt::com_ptr<IMFTransform> CreateH264DecoderTransform(NativeCodecMode mode) {
  MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_H264};
  MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_NV12};
  IMFActivate** activations = nullptr;
  UINT32 count = 0;
  const HRESULT result =
      MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                (mode == NativeCodecMode::Cpu
                     ? MFT_ENUM_FLAG_SYNCMFT
                     : MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SYNCMFT) |
                    MFT_ENUM_FLAG_SORTANDFILTER,
                &input_info, &output_info, &activations, &count);
  if (FAILED(result) || activations == nullptr || count == 0) {
    if (activations != nullptr) CoTaskMemFree(activations);
    return {};
  }
  winrt::com_ptr<IMFTransform> transform;
  for (UINT32 index = 0; index < count && transform == nullptr; ++index) {
    if (activations[index] != nullptr) {
      winrt::com_ptr<IMFTransform> candidate;
      activations[index]->ActivateObject(IID_PPV_ARGS(candidate.put()));
      winrt::com_ptr<IMFAttributes> attributes;
      UINT32 aware = 0;
      if (mode == NativeCodecMode::Cpu && candidate != nullptr) {
        // No D3D manager is supplied to the synchronous software decoder.
        transform = std::move(candidate);
      } else if (candidate != nullptr &&
                 SUCCEEDED(candidate->GetAttributes(attributes.put())) &&
                 SUCCEEDED(attributes->GetUINT32(MF_SA_D3D11_AWARE, &aware)) &&
                 aware) {
        transform = std::move(candidate);
      }
    }
  }
  for (UINT32 index = 0; index < count; ++index) {
    if (activations[index] != nullptr) activations[index]->Release();
  }
  CoTaskMemFree(activations);
  if (transform == nullptr) return {};
  winrt::com_ptr<IMFAttributes> attributes;
  if (SUCCEEDED(transform->GetAttributes(attributes.put())))
    attributes->SetUINT32(CODECAPI_AVLowLatencyMode, TRUE);
  return transform;
}

bool ConvertSoftwareDecodedSample(IMFTransform* transform, IMFSample* sample,
                                  uint32_t width, uint32_t height,
                                  std::vector<uint8_t>* pixels) {
  winrt::com_ptr<IMFMediaType> type;
  winrt::com_ptr<IMFMediaBuffer> buffer;
  UINT32 coded_width = 0, coded_height = 0;
  if (!sample || !pixels ||
      FAILED(transform->GetOutputCurrentType(0, type.put())) ||
      FAILED(MFGetAttributeSize(type.get(), MF_MT_FRAME_SIZE, &coded_width,
                                &coded_height)) ||
      coded_width < width || coded_height < height || coded_width > 16384 ||
      coded_height > 16384 || (coded_width & 1u) || (coded_height & 1u) ||
      (width & 1u) || (height & 1u) ||
      FAILED(sample->ConvertToContiguousBuffer(buffer.put())))
    return false;
  BYTE* data = nullptr;
  DWORD maximum = 0, length = 0;
  if (FAILED(buffer->Lock(&data, &maximum, &length))) return false;
  struct Unlock {
    IMFMediaBuffer* buffer;
    ~Unlock() { buffer->Unlock(); }
  } unlock{buffer.get()};
  const size_t luma_size = static_cast<size_t>(coded_width) * coded_height;
  if (!data || length < luma_size + luma_size / 2) return false;
  pixels->resize(static_cast<size_t>(width) * height * 4);
  for (uint32_t y = 0; y < height; ++y) {
    for (uint32_t x = 0; x < width; ++x) {
      const int luma =
          (std::max)(0, static_cast<int>(data[y * coded_width + x]) - 16);
      const size_t uv = luma_size + (y / 2) * coded_width + (x & ~1u);
      const int u = data[uv] - 128, v = data[uv + 1] - 128;
      const size_t offset = (static_cast<size_t>(y) * width + x) * 4;
      // Flutter's pixel-buffer texture consumes RGBA, unlike the GPU BGRA
      // surface.
      (*pixels)[offset] = static_cast<uint8_t>(
          std::clamp((298 * luma + 409 * v + 128) >> 8, 0, 255));
      (*pixels)[offset + 1] = static_cast<uint8_t>(
          std::clamp((298 * luma - 100 * u - 208 * v + 128) >> 8, 0, 255));
      (*pixels)[offset + 2] = static_cast<uint8_t>(
          std::clamp((298 * luma + 516 * u + 128) >> 8, 0, 255));
      (*pixels)[offset + 3] = 255;
    }
  }
  return true;
}

bool ReadDecoderOutputInfo(IMFTransform* transform, uint32_t* buffer_size,
                           bool* provides_samples) {
  MFT_OUTPUT_STREAM_INFO info{};
  if (FAILED(transform->GetOutputStreamInfo(0, &info))) return false;
  *buffer_size = info.cbSize > 64 * 1024 ? info.cbSize : 64 * 1024;
  *provides_samples = (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;
  return true;
}

bool RefreshDecoderOutput(IMFTransform* transform, uint32_t width,
                          uint32_t height, uint32_t* buffer_size,
                          bool* provides_samples) {
  // SPS can refine the output layout after the first samples. Keep the
  // negotiated dimensions and GPU NV12 format; a resize needs a new owner.
  for (DWORD index = 0; index < 16; ++index) {
    winrt::com_ptr<IMFMediaType> type;
    if (FAILED(transform->GetOutputAvailableType(0, index, type.put())))
      return false;
    GUID subtype{};
    UINT32 candidate_width = 0, candidate_height = 0;
    if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
        subtype != MFVideoFormat_NV12 ||
        FAILED(MFGetAttributeSize(type.get(), MF_MT_FRAME_SIZE,
                                  &candidate_width, &candidate_height)))
      continue;
    if (candidate_width != width || candidate_height != height) {
      MFVideoArea aperture{};
      UINT32 bytes = 0;
      if (FAILED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE,
                               reinterpret_cast<BYTE*>(&aperture),
                               sizeof(aperture), &bytes)) ||
          bytes != sizeof(aperture) ||
          aperture.Area.cx != static_cast<LONG>(width) ||
          aperture.Area.cy != static_cast<LONG>(height) ||
          aperture.OffsetX.value != 0 || aperture.OffsetX.fract != 0 ||
          aperture.OffsetY.value != 0 || aperture.OffsetY.fract != 0)
        continue;
    }
    if (FAILED(transform->SetOutputType(0, type.get(), 0))) return false;
    return ReadDecoderOutputInfo(transform, buffer_size, provides_samples);
  }
  return false;
}

bool InitializeHardwareDecoderDevice(IMFTransform* transform,
                                     ID3D11Device* device,
                                     IMFDXGIDeviceManager** manager) {
  if (transform == nullptr || device == nullptr || manager == nullptr)
    return false;
  winrt::com_ptr<ID3D11VideoDevice> video_device;
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(video_device.put()))))
    return false;
  BOOL supported = FALSE;
  if (FAILED(video_device->CheckVideoDecoderFormat(
          &D3D11_DECODER_PROFILE_H264_VLD_NOFGT, DXGI_FORMAT_NV12,
          &supported)) ||
      !supported)
    return false;
  winrt::com_ptr<ID3D11DeviceContext> context;
  device->GetImmediateContext(context.put());
  winrt::com_ptr<ID3D10Multithread> multithread;
  if (context == nullptr ||
      FAILED(context->QueryInterface(IID_PPV_ARGS(multithread.put()))))
    return false;
  multithread->SetMultithreadProtected(TRUE);
  UINT reset_token = 0;
  winrt::com_ptr<IMFDXGIDeviceManager> device_manager;
  if (FAILED(MFCreateDXGIDeviceManager(&reset_token, device_manager.put())) ||
      FAILED(device_manager->ResetDevice(device, reset_token)) ||
      FAILED(transform->ProcessMessage(
          MFT_MESSAGE_SET_D3D_MANAGER,
          reinterpret_cast<ULONG_PTR>(device_manager.get()))))
    return false;
  *manager = device_manager.detach();
  return true;
}

uint64_t TimestampTo100Ns(uint64_t timestamp_90khz) {
  const uint64_t seconds = timestamp_90khz / 90'000ULL;
  const uint64_t remainder = timestamp_90khz % 90'000ULL;
  return seconds * 10'000'000ULL + remainder * 10'000'000ULL / 90'000ULL;
}

bool SetVideoType(IMFMediaType* type, const GUID& subtype, uint32_t width,
                  uint32_t height) {
  return type != nullptr &&
         SUCCEEDED(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video)) &&
         SUCCEEDED(type->SetGUID(MF_MT_SUBTYPE, subtype)) &&
         SUCCEEDED(MFSetAttributeSize(type, MF_MT_FRAME_SIZE, width, height)) &&
         SUCCEEDED(MFSetAttributeRatio(type, MF_MT_FRAME_RATE, 30, 1)) &&
         SUCCEEDED(MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1)) &&
         SUCCEEDED(type->SetUINT32(MF_MT_INTERLACE_MODE,
                                   MFVideoInterlace_Progressive));
}

bool Nv12ToBgraConverter::Initialize(ID3D11Device* device,
                                     ID3D11DeviceContext* context) {
  if (device == nullptr || context == nullptr ||
      FAILED(device->QueryInterface(IID_PPV_ARGS(device_.put()))) ||
      FAILED(context->QueryInterface(IID_PPV_ARGS(context_.put()))) ||
      FAILED(device->QueryInterface(IID_PPV_ARGS(video_device_.put()))) ||
      FAILED(context->QueryInterface(IID_PPV_ARGS(video_context_.put())))) {
    return false;
  }
  return true;
}

bool Nv12ToBgraConverter::Configure(uint32_t width, uint32_t height) {
  if (width == 0 || height == 0 || video_device_ == nullptr) return false;
  if (processor_ != nullptr && width_ == width && height_ == height) {
    return true;
  }

  D3D11_VIDEO_PROCESSOR_CONTENT_DESC content = {};
  content.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  content.InputFrameRate.Numerator = 30;
  content.InputFrameRate.Denominator = 1;
  content.InputWidth = width;
  content.InputHeight = height;
  content.OutputFrameRate.Numerator = 30;
  content.OutputFrameRate.Denominator = 1;
  content.OutputWidth = width;
  content.OutputHeight = height;

  winrt::com_ptr<ID3D11VideoProcessorEnumerator> enumerator;
  if (FAILED(video_device_->CreateVideoProcessorEnumerator(&content,
                                                           enumerator.put()))) {
    return false;
  }
  winrt::com_ptr<ID3D11VideoProcessor> processor;
  if (FAILED(video_device_->CreateVideoProcessor(enumerator.get(), 0,
                                                 processor.put()))) {
    return false;
  }
  enumerator_ = std::move(enumerator);
  processor_ = std::move(processor);
  width_ = width;
  height_ = height;
  return true;
}

bool Nv12ToBgraConverter::Convert(ID3D11Texture2D* input,
                                  winrt::com_ptr<ID3D11Texture2D>* output,
                                  uint32_t array_slice) {
  if (input == nullptr || output == nullptr || enumerator_ == nullptr ||
      processor_ == nullptr || video_context_ == nullptr) {
    return false;
  }

  D3D11_TEXTURE2D_DESC output_description = {};
  output_description.Width = width_;
  output_description.Height = height_;
  output_description.MipLevels = 1;
  output_description.ArraySize = 1;
  output_description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  output_description.SampleDesc.Count = 1;
  output_description.Usage = D3D11_USAGE_DEFAULT;
  output_description.BindFlags = D3D11_BIND_RENDER_TARGET;
  winrt::com_ptr<ID3D11Texture2D> output_texture;
  if (FAILED(device_->CreateTexture2D(&output_description, nullptr,
                                      output_texture.put()))) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC input_description = {};
  input_description.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  input_description.Texture2D.MipSlice = 0;
  input_description.Texture2D.ArraySlice = array_slice;
  winrt::com_ptr<ID3D11VideoProcessorInputView> input_view;
  if (FAILED(video_device_->CreateVideoProcessorInputView(
          input, enumerator_.get(), &input_description, input_view.put()))) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC output_view_description = {};
  output_view_description.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  output_view_description.Texture2D.MipSlice = 0;
  winrt::com_ptr<ID3D11VideoProcessorOutputView> output_view;
  if (FAILED(video_device_->CreateVideoProcessorOutputView(
          output_texture.get(), enumerator_.get(), &output_view_description,
          output_view.put()))) {
    return false;
  }

  D3D11_VIDEO_PROCESSOR_STREAM stream = {};
  stream.Enable = TRUE;
  stream.pInputSurface = input_view.get();
  video_context_->VideoProcessorSetStreamFrameFormat(
      processor_.get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
  const RECT visible{0, 0, static_cast<LONG>(width_),
                     static_cast<LONG>(height_)};
  video_context_->VideoProcessorSetStreamSourceRect(processor_.get(), 0, TRUE,
                                                    &visible);
  if (FAILED(video_context_->VideoProcessorBlt(
          processor_.get(), output_view.get(), 0, 1, &stream))) {
    return false;
  }
  *output = std::move(output_texture);
  return true;
}

bool ConvertDecodedSample(IMFSample* sample, Nv12ToBgraConverter* converter,
                          winrt::com_ptr<ID3D11Texture2D>* output) {
  if (sample == nullptr || converter == nullptr || output == nullptr)
    return false;
  winrt::com_ptr<IMFMediaBuffer> buffer;
  winrt::com_ptr<IMFDXGIBuffer> dxgi;
  winrt::com_ptr<ID3D11Texture2D> texture;
  UINT slice = 0;
  if (FAILED(sample->GetBufferByIndex(0, buffer.put())) ||
      FAILED(buffer->QueryInterface(IID_PPV_ARGS(dxgi.put()))) ||
      FAILED(dxgi->GetResource(IID_PPV_ARGS(texture.put()))) ||
      FAILED(dxgi->GetSubresourceIndex(&slice)))
    return false;
  D3D11_TEXTURE2D_DESC description{};
  texture->GetDesc(&description);
  return description.Format == DXGI_FORMAT_NV12 &&
         converter->Convert(texture.get(), output, slice);
}

namespace {
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

}  // namespace

BgraToNv12Readback::BgraToNv12Readback(ID3D11Device* input_device,
                                       ID3D11DeviceContext* input_context) {
  if (input_device != nullptr)
    input_device->QueryInterface(IID_PPV_ARGS(device.put()));
  if (input_context != nullptr)
    input_context->QueryInterface(IID_PPV_ARGS(context.put()));
}

bool BgraToNv12Readback::Read(ID3D11Texture2D* texture,
                              std::vector<uint8_t>* output,
                              uint32_t* output_width, uint32_t* output_height) {
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
  auto read_rgb = [&](uint32_t x, uint32_t y, int* red, int* green, int* blue) {
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
      const size_t chroma_index =
          chroma_offset + static_cast<size_t>(y / 2) * staging_width + x;
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

}  // namespace realtime_media_windows
