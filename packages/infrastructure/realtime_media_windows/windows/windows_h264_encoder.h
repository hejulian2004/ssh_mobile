#ifndef REALTIME_MEDIA_WINDOWS_H264_ENCODER_H_
#define REALTIME_MEDIA_WINDOWS_H264_ENCODER_H_

#include <cstdint>
#include <memory>
#include <vector>

struct ID3D11Device;
struct ID3D11DeviceContext;
struct ID3D11Texture2D;

namespace realtime_media_windows {

struct EncodedAccessUnit {
  std::vector<uint8_t> payload;
  bool keyframe = false;
};

// Native-only Media Foundation hardware H.264 encoder. It accepts a D3D11
// capture texture and returns Annex-B access units; no byte buffer crosses the
// Flutter method channel. A null instance means that no hardware H.264 MFT is
// available and callers must fail explicitly rather than use a software or
// alternate-codec fallback.
class HardwareH264Encoder final {
 public:
  static std::unique_ptr<HardwareH264Encoder> Create(
      ID3D11Device* device,
      ID3D11DeviceContext* context);
  ~HardwareH264Encoder();

  HardwareH264Encoder(const HardwareH264Encoder&) = delete;
  HardwareH264Encoder& operator=(const HardwareH264Encoder&) = delete;

  bool Encode(ID3D11Texture2D* texture,
              uint64_t timestamp_90khz,
              std::vector<EncodedAccessUnit>* output);

  /// Applies a bounded bitrate target to the hardware MFT. Frame-rate
  /// throttling is owned by the capture state; resolution changes are
  /// intentionally rejected and require an explicit owner restart.
  bool ApplyAdaptation(uint32_t bitrate_kbps);

  /// Requests the hardware MFT to emit an IDR/keyframe on its next output.
  /// This is a native codec control; it never crosses the Dart boundary.
  bool RequestKeyframe();

 private:
  struct Impl;
  explicit HardwareH264Encoder(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

}  // namespace realtime_media_windows

#endif  // REALTIME_MEDIA_WINDOWS_H264_ENCODER_H_
