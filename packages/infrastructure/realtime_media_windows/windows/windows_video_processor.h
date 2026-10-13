#ifndef REALTIME_MEDIA_WINDOWS_VIDEO_PROCESSOR_H_
#define REALTIME_MEDIA_WINDOWS_VIDEO_PROCESSOR_H_

#include <cstdint>
#include <memory>
#include <vector>

#include <d3d11.h>

#include <winrt/base.h>
#include "windows_capture.h"
#include <flutter/texture_registrar.h>

struct IMFMediaType;
struct IMFTransform;
struct IMFDXGIDeviceManager;
struct IMFSample;

namespace realtime_media_windows {

struct DecodedVideoFrame {
  winrt::com_ptr<ID3D11Texture2D> texture;
  std::vector<uint8_t> pixels;
};
std::unique_ptr<flutter::TextureVariant> MakeDecodedVideoTexture(
    NativeCodecMode mode,
    flutter::GpuSurfaceTexture::ObtainDescriptorCallback gpu,
    flutter::PixelBufferTexture::CopyBufferCallback cpu);
struct NativePixelFrameLease {
  FlutterDesktopPixelBuffer descriptor{};
  std::shared_ptr<std::vector<uint8_t>> pixels;
  static const FlutterDesktopPixelBuffer* Retain(
      std::shared_ptr<std::vector<uint8_t>> pixels, size_t width,
      size_t height) {
    auto* lease = new NativePixelFrameLease{};
    lease->pixels = std::move(pixels);
    lease->descriptor.buffer = lease->pixels->data();
    lease->descriptor.width = width;
    lease->descriptor.height = height;
    lease->descriptor.release_context = lease;
    lease->descriptor.release_callback = [](void* value) {
      delete static_cast<NativePixelFrameLease*>(value);
    };
    return &lease->descriptor;
  }
};
winrt::com_ptr<IMFTransform> CreateH264DecoderTransform(NativeCodecMode mode);
bool CreateHardwareDecoderGraphicsDevice(ID3D11Device** device,
                                         ID3D11DeviceContext** context);
bool ConvertSoftwareDecodedSample(IMFTransform* transform, IMFSample* sample,
                                  uint32_t width, uint32_t height,
                                  std::vector<uint8_t>* pixels);

// Owns the staging texture used by native BGRA-to-NV12 readback for either
// hardware compression or explicitly selected CPU compression.
class BgraToNv12Readback final {
 public:
  BgraToNv12Readback(ID3D11Device* device, ID3D11DeviceContext* context);
  bool Read(ID3D11Texture2D* texture, std::vector<uint8_t>* output,
            uint32_t* output_width, uint32_t* output_height);

 private:
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  winrt::com_ptr<ID3D11Texture2D> staging;
  uint32_t staging_width = 0, staging_height = 0;
};

// Constructs the native media type consumed by the decoder/GPU conversion
// pipeline. Format metadata and surfaces remain native-owned.
bool SetVideoType(IMFMediaType* type, const GUID& subtype, uint32_t width,
                  uint32_t height);
uint64_t TimestampTo100Ns(uint64_t timestamp_90khz);
bool InitializeHardwareDecoderDevice(IMFTransform* transform,
                                     ID3D11Device* device,
                                     IMFDXGIDeviceManager** manager);
bool ReadDecoderOutputInfo(IMFTransform* transform, uint32_t* buffer_size,
                           bool* provides_samples);
bool RefreshDecoderOutput(IMFTransform* transform, uint32_t width,
                          uint32_t height, uint32_t* buffer_size,
                          bool* provides_samples);

// Converts the NV12 surfaces produced by hardware H.264 decoders into the
// BGRA D3D11 textures accepted by Flutter's desktop texture registrar. The
// converter owns only native GPU resources; no decoded pixels cross Dart.
class Nv12ToBgraConverter final {
 public:
  Nv12ToBgraConverter() = default;
  ~Nv12ToBgraConverter() = default;

  Nv12ToBgraConverter(const Nv12ToBgraConverter&) = delete;
  Nv12ToBgraConverter& operator=(const Nv12ToBgraConverter&) = delete;

  bool Initialize(ID3D11Device* device, ID3D11DeviceContext* context);
  bool Configure(uint32_t width, uint32_t height);
  bool Convert(ID3D11Texture2D* input, winrt::com_ptr<ID3D11Texture2D>* output,
               uint32_t array_slice = 0);

 private:
  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID3D11VideoDevice> video_device_;
  winrt::com_ptr<ID3D11VideoContext> video_context_;
  winrt::com_ptr<ID3D11VideoProcessorEnumerator> enumerator_;
  winrt::com_ptr<ID3D11VideoProcessor> processor_;
  uint32_t width_ = 0;
  uint32_t height_ = 0;
};

bool ConvertDecodedSample(IMFSample* sample, Nv12ToBgraConverter* converter,
                          winrt::com_ptr<ID3D11Texture2D>* output);

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_VIDEO_PROCESSOR_H_
