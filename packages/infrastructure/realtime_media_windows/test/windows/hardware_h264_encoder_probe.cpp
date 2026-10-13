#include <d3d11.h>
#include <mfapi.h>
#include <windows.h>
#include <winrt/base.h>

#include <iostream>
#include <vector>

#include "windows_h264_encoder.h"

int main() {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  if (FAILED(MFStartup(MF_VERSION))) return 2;
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                               D3D11_SDK_VERSION, device.put(), nullptr,
                               context.put())))
    return 2;
  D3D11_TEXTURE2D_DESC description{};
  description.Width = 640;
  description.Height = 480;
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
  auto encoder = realtime_media_windows::HardwareH264Encoder::Create(
      device.get(), context.get());
  if (!encoder) {
    std::cout << "GAP hardware_encoder_unavailable\n";
    return 2;
  }
  size_t units = 0;
  bool recovery_requested = false;
  for (uint64_t frame = 0; frame < 90; ++frame) {
    std::vector<realtime_media_windows::EncodedAccessUnit> output;
    if (!encoder->Encode(texture.get(), frame * 3000, &output)) {
      std::cout << "FAIL encoding\n";
      return 1;
    }
    units += output.size();
    for (const auto &unit : output) {
      bool sps = false, pps = false, idr = false;
      for (size_t index = 0; index + 4 < unit.payload.size(); ++index) {
        const auto &bytes = unit.payload;
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
