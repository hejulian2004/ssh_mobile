#include <d3d11.h>
#include <mfapi.h>
#include <windows.h>
#include <winrt/base.h>

#include <fstream>
#include <iostream>
#include <vector>

#include "windows_capture.h"
#include "windows_h264_encoder.h"
#include "windows_video_processor.h"

int main(int argc, char** argv) {
  bool cpu = false, odd = false, export_fixture = false, repeat = false;
  for (int index = 1; index < argc; ++index) {
    cpu |= std::string(argv[index]) == "--cpu";
    odd |= std::string(argv[index]) == "--odd";
    export_fixture |= std::string(argv[index]) == "--export";
    repeat |= std::string(argv[index]) == "--repeat";
  }
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  if (FAILED(MFStartup(MF_VERSION))) return 2;
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  if (FAILED(D3D11CreateDevice(
          nullptr, cpu ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
          nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
          D3D11_SDK_VERSION, device.put(), nullptr, context.put())))
    return 2;
  D3D11_TEXTURE2D_DESC description{};
  description.Width = odd ? 641 : 640;
  description.Height = odd ? 479 : 480;
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  description.SampleDesc.Count = 1;
  description.Usage = D3D11_USAGE_DEFAULT;
  std::vector<uint32_t> fixture(description.Width * description.Height,
                                0xff2070a0);
  D3D11_SUBRESOURCE_DATA initial{fixture.data(), description.Width * 4, 0};
  winrt::com_ptr<ID3D11Texture2D> texture;
  if (FAILED(device->CreateTexture2D(&description, &initial, texture.put())))
    return 2;
  realtime_media_windows::BgraToNv12Readback readback(device.get(),
                                                      context.get());
  std::vector<uint8_t> nv12;
  uint32_t width = 0, height = 0;
  if (!readback.Read(texture.get(), &nv12, &width, &height) ||
      width != ((description.Width + 1u) & ~1u) ||
      height != ((description.Height + 1u) & ~1u) ||
      nv12.size() != static_cast<size_t>(width) * height * 3 / 2) {
    std::cout << "FAIL padded_nv12_layout\n";
    return 1;
  }
  const size_t luma = static_cast<size_t>(width) * height;
  for (size_t index = 0; index < nv12.size(); ++index) {
    const uint8_t expected =
        index < luma ? 96 : ((index - luma) % 2 ? 90 : 161);
    if (nv12[index] != expected) {
      std::cout << "FAIL padded_nv12_pixels\n";
      return 1;
    }
  }
  auto encoder = realtime_media_windows::NativeH264Encoder::Create(
      device.get(), context.get(),
      cpu ? realtime_media_windows::NativeCodecMode::Cpu
          : realtime_media_windows::NativeCodecMode::Hardware);
  if (!encoder) {
    std::cout << "GAP hardware_encoder_unavailable\n";
    return 2;
  }
  size_t units = 0;
  bool recovery_requested = false;
  if (repeat) {
    std::vector<realtime_media_windows::EncodedAccessUnit> empty;
    if (!encoder->RepeatFrame(0, &empty) || !empty.empty()) {
      std::cout << "FAIL uncaptured_repeat\n";
      return 1;
    }
  }
  for (uint64_t frame = 0; frame < 90; ++frame) {
    std::vector<realtime_media_windows::EncodedAccessUnit> output;
    const bool encoded =
        repeat && frame > 0
            ? encoder->RepeatFrame(frame * 3000, &output)
            : encoder->Encode(texture.get(), frame * 3000, &output);
    if (!encoded) {
      std::cout << "FAIL encoding\n";
      return 1;
    }
    units += output.size();
    if (cpu && frame >= 3 && units == 0) {
      std::cout << "FAIL cpu_startup_frame_latency\n";
      return 1;
    }
    for (const auto& unit : output) {
      if (unit.width != width || unit.height != height) {
        std::cout << "FAIL encoded_dimensions\n";
        return 1;
      }
      bool sps = false, pps = false, idr = false;
      for (size_t index = 0; index + 4 < unit.payload.size(); ++index) {
        const auto& bytes = unit.payload;
        if (bytes[index] != 0 || bytes[index + 1] != 0) continue;
        size_t header = index + 2;
        if (bytes[header] == 0) ++header;
        if (bytes[header] != 1 || header + 1 >= bytes.size()) continue;
        const auto type = bytes[header + 1] & 31;
        sps |= type == 7;
        pps |= type == 8;
        idr |= type == 5;
      }
      if (unit.keyframe && sps && pps && idr) {
        if (export_fixture) {
          std::ofstream fixture_file("single-frame-fixture.h264",
                                     std::ios::binary);
          fixture_file.write(reinterpret_cast<const char*>(unit.payload.data()),
                             static_cast<std::streamsize>(unit.payload.size()));
          if (!fixture_file) return 1;
          std::cout << "PASS exported_synthetic_fixture\n";
          return 0;
        }
        if (recovery_requested) {
          std::cout << "PASS recovered_encoded_fixture\n";
          return 0;
        }
        if (!encoder->RequestKeyframe()) {
          std::cout << "FAIL recovery_request\n";
          return 1;
        }
        recovery_requested = true;
        continue;
      }
      if (idr) {
        std::cout << "FAIL incomplete_recovery sps=" << sps << " pps=" << pps
                  << " keyframe=" << unit.keyframe << "\n";
        return 1;
      }
    }
    Sleep(33);
  }
  std::cout << "FAIL no_encoded_fixture\n";
  return 1;
}
