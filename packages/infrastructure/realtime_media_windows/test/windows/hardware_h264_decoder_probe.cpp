#include <windows.h>
#include <d3d11.h>
#include <mfapi.h>
#include <flutter/texture_registrar.h>
#include <winrt/base.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

#include "windows_h264_decoder.h"
#include "windows_h264_encoder.h"
#include "windows_media_channel.h"

namespace {
using namespace realtime_media_windows;
struct FixtureFrame {
  NativeH264FrameMetadata metadata;
  std::vector<uint8_t> payload;
};
std::mutex fixture_mutex;
std::deque<FixtureFrame> fixture_frames;
uint32_t fixture_width = 640, fixture_height = 480;
bool cpu_mode = false;
bool automatic_mode = false;
bool defer_render = false;
bool retain_frame = false;
bool defer_unregister = false;
bool MatchesFixtureColor(const uint8_t* rgba) {
  return rgba[0] >= 20 && rgba[0] <= 44 && rgba[1] >= 100 && rgba[1] <= 124 &&
         rgba[2] >= 148 && rgba[2] <= 172 && rgba[3] == 255;
}
std::atomic<bool> owner_started{false};
uint32_t __cdecl FixtureAbi() { return 1; }
int __cdecl FixtureStatus(uint64_t) { return 0; }
int __cdecl FixtureStart(uint64_t) {
  owner_started.store(true);
  return 0;
}
int __cdecl FixtureStop(uint64_t) {
  owner_started.store(false);
  return 0;
}
int __cdecl FixtureStats(uint64_t, NativeMediaStats*) { return 0; }
int __cdecl FixtureAdapt(uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                         uint32_t) {
  return 0;
}
int __cdecl FixturePush(uint64_t, NativeH264FrameMetadata, const uint8_t*,
                        size_t) {
  return 0;
}
class FixtureResult final
    : public flutter::MethodResult<flutter::EncodableValue> {
 public:
  explicit FixtureResult(bool& success) : success_(success) {}

 protected:
  void SuccessInternal(const flutter::EncodableValue*) override {
    success_ = true;
  }
  void ErrorInternal(const std::string& code, const std::string&,
                     const flutter::EncodableValue*) override {
    std::cout << "FAIL surface_attach " << code << "\n";
  }
  void NotImplementedInternal() override {}

 private:
  bool& success_;
};

class FixtureRegistrar final : public flutter::TextureRegistrar {
 public:
  std::atomic<bool> valid_surface{false};
  flutter::TextureVariant* texture = nullptr;
  const FlutterDesktopPixelBuffer* retained_pixels = nullptr;
  std::function<void()> unregister_complete;
  int64_t RegisterTexture(flutter::TextureVariant* value) override {
    texture = value;
    return 1;
  }
  bool MarkTextureFrameAvailable(int64_t) override {
    return defer_render || RenderFixture();
  }
  bool RenderFixture() {
    if (std::holds_alternative<flutter::PixelBufferTexture>(*texture)) {
      const auto* pixels =
          std::get<flutter::PixelBufferTexture>(*texture).CopyPixelBuffer(
              fixture_width, fixture_height);
      if (!pixels) return false;
      const bool valid =
          pixels->buffer != nullptr && pixels->width == fixture_width &&
          pixels->height == fixture_height &&
          MatchesFixtureColor(pixels->buffer) &&
          MatchesFixtureColor(pixels->buffer +
                              (fixture_width * fixture_height - 1) * 4);
      if (retain_frame && retained_pixels == nullptr)
        retained_pixels = pixels;
      else
        pixels->release_callback(pixels->release_context);
      valid_surface.store(valid);
      return valid;
    }
    const auto* descriptor =
        std::get<flutter::GpuSurfaceTexture>(*texture).ObtainDescriptor(
            fixture_width, fixture_height);
    if (!descriptor) return false;
    const bool valid = descriptor->handle != nullptr &&
                       descriptor->width == fixture_width &&
                       descriptor->height == fixture_height &&
                       descriptor->format == kFlutterDesktopPixelFormatBGRA8888;
    descriptor->release_callback(descriptor->release_context);
    valid_surface.store(valid);
    return valid;
  }
  void UnregisterTexture(int64_t, std::function<void()> callback) override {
    if (defer_unregister) {
      unregister_complete = std::move(callback);
    } else if (callback) {
      callback();
    }
  }
  bool UnregisterTexture(int64_t) override { return true; }
};

int __cdecl FixturePull(uint64_t, NativeH264FrameMetadata* metadata,
                        NativeH264Buffer* payload) {
  if (!owner_started.load()) return -9;
  std::lock_guard<std::mutex> lock(fixture_mutex);
  if (fixture_frames.empty()) return 1;
  const auto& frame = fixture_frames.front();
  *metadata = frame.metadata;
  payload->ptr = new uint8_t[frame.payload.size()];
  payload->len = frame.payload.size();
  std::memcpy(payload->ptr, frame.payload.data(), payload->len);
  fixture_frames.pop_front();
  return 0;
}
void __cdecl FreeFixture(NativeH264Buffer payload) { delete[] payload.ptr; }

bool PrepareFixture() {
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  if (FAILED(D3D11CreateDevice(
          nullptr, cpu_mode ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE,
          nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
          D3D11_SDK_VERSION, device.put(), nullptr, context.put())))
    return false;
  D3D11_TEXTURE2D_DESC description{};
  description.Width = fixture_width;
  description.Height = fixture_height;
  description.MipLevels = 1;
  description.ArraySize = 1;
  description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  description.SampleDesc.Count = 1;
  std::vector<uint32_t> fixture(fixture_width * fixture_height, 0xff2070a0);
  D3D11_SUBRESOURCE_DATA initial{fixture.data(), fixture_width * 4, 0};
  winrt::com_ptr<ID3D11Texture2D> texture;
  if (FAILED(device->CreateTexture2D(&description, &initial, texture.put())))
    return false;
  auto encoder = NativeH264Encoder::Create(
      device.get(), context.get(),
      cpu_mode ? NativeCodecMode::Cpu : NativeCodecMode::Hardware);
  if (!encoder) return false;
  uint64_t sequence = 0;
  size_t payload_bytes = 0;
  for (uint64_t frame = 0; frame < 45; ++frame) {
    std::vector<EncodedAccessUnit> output;
    if (!encoder->Encode(texture.get(), frame * 3000, &output)) return false;
    for (auto& unit : output) {
      payload_bytes += unit.payload.size();
      if (fixture_frames.size() >= 90 || payload_bytes > 4 * 1024 * 1024)
        return false;
      fixture_frames.push_back(
          {{sequence++, frame * 3000, fixture_width, fixture_height,
            static_cast<uint8_t>(unit.keyframe)},
           std::move(unit.payload)});
    }
    Sleep(33);
  }
  std::cout << "PHASE fixture_access_units=" << fixture_frames.size() << "\n"
            << std::flush;
  return !fixture_frames.empty();
}
}  // namespace

int main(int argc, char** argv) {
  if (CodecModeArgument({}) != NativeCodecMode::Automatic ||
      CodecModeArgument({{flutter::EncodableValue("codec_mode"),
                          flutter::EncodableValue("automatic")}}) !=
          NativeCodecMode::Automatic ||
      CodecModeArgument({{flutter::EncodableValue("codec_mode"),
                          flutter::EncodableValue("unknown")}}).has_value()) {
    std::cout << "FAIL codec_policy_validation\n";
    return 1;
  }
  for (int index = 1; index < argc; ++index) {
    if (std::string(argv[index]) == "--cpu") cpu_mode = true;
    if (std::string(argv[index]) == "--automatic") {
      automatic_mode = true;
      cpu_mode = true;  // Fixture encoding is independent of receiver policy.
    }
    if (std::string(argv[index]) == "--defer-render") defer_render = true;
    if (std::string(argv[index]) == "--retain-frame") retain_frame = true;
    if (std::string(argv[index]) == "--defer-unregister") defer_unregister = true;
    if (std::string(argv[index]) == "--portrait") {
      fixture_width = 1080;
      fixture_height = 2424;
    }
    if (std::string(argv[index]) == "--cropped") {
      fixture_width = 638;
      fixture_height = 478;
    }
  }
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(20));
    std::cerr << "FAIL fixture_timeout\n";
    std::quick_exit(1);
  }).detach();
  // Match Flutter's STA. The receiver consumes deterministic pre-encoded
  // fixtures, so it needs no test-only hooks or another codec in its worker.
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  if (FAILED(MFStartup(MF_VERSION))) return 2;
  if (!PrepareFixture()) {
    std::cout << "GAP fixture_encoder_unavailable\n";
    return 2;
  }
  FixtureRegistrar registrar;
  WindowsDecoderManager manager(&registrar);
  manager.SetNativeCallbacks(&FixturePull, &FreeFixture);
  NativeMediaApi api;
  api.abi_version = &FixtureAbi;
  api.validate_owner = api.close_owner = api.attach_renderer =
      api.detach_renderer = api.request_keyframe = api.reset_decoder =
          &FixtureStatus;
  api.start_owner = &FixtureStart;
  api.stop_owner = &FixtureStop;
  api.read_stats = &FixtureStats;
  api.apply_adaptation = &FixtureAdapt;
  api.push_h264 = &FixturePush;
  api.pull_h264 = &FixturePull;
  api.free_buffer = &FreeFixture;
  bool attached = false;
  AttachMediaSurface(
      {{flutter::EncodableValue("owner_token"), flutter::EncodableValue("1")},
       {flutter::EncodableValue("direction"),
        flutter::EncodableValue("receive")},
       {flutter::EncodableValue("codec_mode"),
        flutter::EncodableValue(automatic_mode ? "automatic"
                                             : (cpu_mode ? "cpu" : "hardware"))}},
      std::make_unique<FixtureResult>(attached), api, manager);
  if (!owner_started.load()) {
    std::cout << "FAIL native_owner_not_started_before_decoder\n";
    return 1;
  }
  if (!attached) {
    std::cout << "FAIL decoder_attach_in_existing_apartment\n";
    return 1;
  }
  bool rendered = false;
  for (unsigned attempt = 0; attempt < 180; ++attempt) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    Sleep(10);
    DecoderStats stats;
    manager.ReadStats(1, &stats);
    if (defer_render && stats.frames_decoded > 0 &&
        !registrar.valid_surface.load()) {
      if (stats.frames_rendered != 0) {
        std::cout << "FAIL notified_frame_counted_as_rendered\n";
        return 1;
      }
      registrar.RenderFixture();
      continue;
    }
    if (stats.terminal_status != 0) {
      std::cout << "FAIL fixture_decode terminal=" << stats.terminal_status
                << "\n";
      return 1;
    }
    if (stats.frames_decoded > 0 && stats.frames_rendered > 0 &&
        registrar.valid_surface.load()) {
      std::cout << "PHASE rendered_before_release\n" << std::flush;
      rendered = true;
      break;
    }
  }
  if (!rendered) {
    std::cout << "FAIL fixture_not_rendered remaining=" << fixture_frames.size()
              << "\n"
              << std::flush;
    return 1;
  }
  if (manager.Release(1) != DecoderStatus::kOk) {
    std::cout << "FAIL decoder_release\n";
    return 1;
  }
  if (retain_frame) {
    const auto* pixels = registrar.retained_pixels;
    if (!pixels || !MatchesFixtureColor(pixels->buffer)) {
      std::cout << "FAIL pixel_lease_invalidated_by_owner_release\n";
      return 1;
    }
    pixels->release_callback(pixels->release_context);
  }
  if (defer_unregister) {
    if (!registrar.unregister_complete) {
      std::cout << "FAIL texture_release_has_no_completion_lease\n";
      return 1;
    }
    // Flutter may invoke the registered callback until unregister completes.
    // The callback must still be callable after its decoder owner is released.
    const bool stopped =
        std::holds_alternative<flutter::PixelBufferTexture>(*registrar.texture)
        ? std::get<flutter::PixelBufferTexture>(*registrar.texture)
                  .CopyPixelBuffer(fixture_width, fixture_height) == nullptr
        : std::get<flutter::GpuSurfaceTexture>(*registrar.texture)
                  .ObtainDescriptor(fixture_width, fixture_height) == nullptr;
    if (!stopped) {
      std::cout << "FAIL released_owner_still_produces_frames\n";
      return 1;
    }
    registrar.unregister_complete();
    registrar.unregister_complete = nullptr;
  }
  std::cout << "PASS "
            << (automatic_mode ? "automatic" : (cpu_mode ? "cpu" : "hardware"))
            << "_fixture_decoded_and_rendered_in_existing_apartment\n";
  return 0;
}
