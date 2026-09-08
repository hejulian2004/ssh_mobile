#ifndef REALTIME_MEDIA_WINDOWS_VIDEO_PROCESSOR_H_
#define REALTIME_MEDIA_WINDOWS_VIDEO_PROCESSOR_H_

#include <cstdint>
#include <memory>

#include <d3d11.h>

#include <winrt/base.h>

namespace realtime_media_windows {

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
  bool Convert(ID3D11Texture2D* input,
               winrt::com_ptr<ID3D11Texture2D>* output);

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

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_VIDEO_PROCESSOR_H_
