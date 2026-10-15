#include "../../windows/runner/window_fullscreen.h"

#include <iostream>
#include <type_traits>

static_assert(!std::is_copy_constructible_v<WindowFullscreenLease>);
static_assert(!std::is_copy_assignable_v<WindowFullscreenLease>);

namespace {
bool SameRect(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}
bool Check(bool value, const char* message) {
  if (!value) std::cerr << message << '\n';
  return value;
}
}  // namespace

int main() {
  const HWND window = CreateWindowExW(
      WS_EX_CLIENTEDGE, L"STATIC", L"", WS_OVERLAPPEDWINDOW, 50, 60, 601, 433,
      nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!window) return 1;
  const LONG_PTR original_style = GetWindowLongPtrW(window, GWL_STYLE);
  const LONG_PTR original_exstyle = GetWindowLongPtrW(window, GWL_EXSTYLE);
  RECT original{};
  GetWindowRect(window, &original);
  bool ok = true;
  {
    WindowFullscreenLease lease(window);
    ok &= Check(!lease.SetFullscreen(0, true), "invalid lease accepted");
    ok &= Check(lease.SetFullscreen(1, true), "enter failed");
    ok &= Check(lease.SetFullscreen(1, true), "same lease is not idempotent");
    ok &= Check(!lease.SetFullscreen(2, true),
                "another lease replaced current owner");
    ok &= Check(lease.SetFullscreen(2, false), "stale release failed");
    ok &=
        Check((GetWindowLongPtrW(window, GWL_STYLE) & WS_OVERLAPPEDWINDOW) == 0,
              "stale release restored another lease");
    RECT fullscreen{};
    GetWindowRect(window, &fullscreen);
    MONITORINFO monitor{sizeof(MONITORINFO)};
    GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                    &monitor);
    ok &= Check(SameRect(fullscreen, monitor.rcMonitor),
                "not monitor fullscreen");
    ok &= Check(!IsWindowVisible(window), "hidden fixture became visible");
    ok &= Check(lease.SetFullscreen(1, false), "restore failed");
    RECT restored{};
    GetWindowRect(window, &restored);
    ok &=
        Check(SameRect(restored, original), "original rectangle not restored");
    ok &= Check(GetWindowLongPtrW(window, GWL_STYLE) == original_style,
                "original style not restored");
    ok &= Check(GetWindowLongPtrW(window, GWL_EXSTYLE) == original_exstyle,
                "original extended style not restored");
    ok &= Check(lease.SetFullscreen(1, false), "repeated release failed");
    ok &= Check(lease.SetFullscreen(3, true), "later lease failed");
  }
  RECT restored{};
  GetWindowRect(window, &restored);
  ok &= Check(SameRect(restored, original),
              "destruction did not restore placement");
  DestroyWindow(window);
  WindowFullscreenLease destroyed(window);
  ok &= Check(!destroyed.SetFullscreen(4, true),
              "destroyed window entered fullscreen");
  ok &= Check(destroyed.SetFullscreen(4, false),
              "destroyed window cleanup failed");
  if (ok) std::cout << "Window fullscreen lifecycle passed.\n";
  return ok ? 0 : 1;
}
