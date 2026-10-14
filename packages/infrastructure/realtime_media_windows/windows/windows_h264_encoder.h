#ifndef REALTIME_MEDIA_WINDOWS_H264_ENCODER_H_
#define REALTIME_MEDIA_WINDOWS_H264_ENCODER_H_

#include <cstdint>
#include <memory>
#include <vector>

#include "windows_capture.h"

struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;

namespace realtime_media_windows {

struct EncodedAccessUnit {
  std::vector<uint8_t> payload;
  bool keyframe = false;
  uint32_t width = 0;
  uint32_t height = 0;
};

// Native-only Media Foundation H.264 encoder. It accepts a D3D11
// capture texture and returns Annex-B access units; no byte buffer crosses the
// Flutter method channel. Hardware is the default; CPU uses a selected software
// MFT. A missing selected codec fails explicitly, without an implicit fallback.
class NativeH264Encoder final {
 public:
  static std::unique_ptr<NativeH264Encoder> Create(
      ID3D11Device* device, ID3D11DeviceContext* context,
      NativeCodecMode mode = NativeCodecMode::Hardware);
  ~NativeH264Encoder();

  NativeH264Encoder(const NativeH264Encoder&) = delete;
  NativeH264Encoder& operator=(const NativeH264Encoder&) = delete;

  bool Encode(ID3D11Texture2D* texture, uint64_t timestamp_90khz,
              std::vector<EncodedAccessUnit>* output);

  // Resamples the last real source snapshot while an unchanged window has no
  // WGC damage event. Empty capture history never synthesizes a frame.
  bool RepeatFrame(uint64_t timestamp_90khz,
                   std::vector<EncodedAccessUnit>* output);

  /// Applies a bounded bitrate target to the selected MFT. Frame-rate
  /// throttling is owned by the capture state; resolution changes are
  /// intentionally rejected and require an explicit owner restart.
  bool ApplyAdaptation(uint32_t bitrate_kbps);

  /// Requests the selected MFT to emit an IDR/keyframe on its next output.
  /// This is a native codec control; it never crosses the Dart boundary.
  bool RequestKeyframe();

 private:
  struct Impl;
  explicit NativeH264Encoder(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_H264_ENCODER_H_
