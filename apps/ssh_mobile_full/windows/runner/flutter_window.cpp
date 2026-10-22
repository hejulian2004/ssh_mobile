#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  fullscreen_ = std::make_unique<WindowFullscreenLease>(GetHandle());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "ssh_mobile/window_presentation",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setFullscreen") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            call.arguments()
                ? std::get_if<flutter::EncodableMap>(call.arguments())
                : nullptr;
        int64_t lease = 0;
        const bool* enabled = nullptr;
        if (args) {
          const auto id = args->find(flutter::EncodableValue("lease_id"));
          const auto flag = args->find(flutter::EncodableValue("enabled"));
          if (id != args->end()) {
            if (const auto* value = std::get_if<int64_t>(&id->second))
              lease = *value;
            else if (const auto* narrow_value =
                         std::get_if<int32_t>(&id->second))
              lease = *narrow_value;
          }
          if (flag != args->end()) enabled = std::get_if<bool>(&flag->second);
        }
        if (lease <= 0 || !enabled) {
          result->Error("invalid_argument",
                        "A window lease and intent are required.");
        } else if (!fullscreen_->SetFullscreen(lease, *enabled)) {
          result->Error("window_presentation_failed",
                        "Window presentation failed.");
        } else {
          result->Success(flutter::EncodableValue(true));
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) window_channel_->SetMethodCallHandler(nullptr);
  window_channel_.reset();
  fullscreen_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      if ((message == WM_DISPLAYCHANGE || message == WM_DPICHANGED) &&
          fullscreen_) {
        fullscreen_->Refresh();
      }
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  const auto result =
      Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  if ((message == WM_DISPLAYCHANGE || message == WM_DPICHANGED) &&
      fullscreen_) {
    fullscreen_->Refresh();
  }
  return result;
}
