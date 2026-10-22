#include "window_fullscreen.h"

namespace {
bool SetStyle(HWND window, int index, LONG_PTR style) {
  SetLastError(0);
  return SetWindowLongPtrW(window, index, style) != 0 || GetLastError() == 0;
}
}  // namespace

WindowFullscreenLease::~WindowFullscreenLease() { Restore(); }

bool WindowFullscreenLease::SetFullscreen(int64_t lease_id, bool enabled) {
  if (lease_id <= 0) return false;
  if (!enabled) {
    // A late route disposal may never restore a newer route's snapshot.
    return !snapshot_ || lease_id != lease_id_ || Restore();
  }
  if (snapshot_) return lease_id == lease_id_;
  if (!IsWindow(window_)) return false;
  Snapshot snapshot{};
  snapshot.style = GetWindowLongPtrW(window_, GWL_STYLE);
  snapshot.exstyle = GetWindowLongPtrW(window_, GWL_EXSTYLE);
  snapshot.placement.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(window_, &snapshot.placement)) return false;
  snapshot_ = snapshot;
  lease_id_ = lease_id;
  if (!SetStyle(window_, GWL_STYLE, snapshot.style & ~WS_OVERLAPPEDWINDOW) ||
      !SetStyle(window_, GWL_EXSTYLE,
                snapshot.exstyle & ~(WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE)) ||
      !Refresh()) {
    Restore();
    return false;
  }
  return true;
}

bool WindowFullscreenLease::Refresh() {
  if (!snapshot_ || restoring_) return true;
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfoW(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST),
                       &monitor))
    return false;
  return SetWindowPos(window_, HWND_TOP, monitor.rcMonitor.left,
                      monitor.rcMonitor.top,
                      monitor.rcMonitor.right - monitor.rcMonitor.left,
                      monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                      SWP_FRAMECHANGED | SWP_NOACTIVATE) != FALSE;
}

bool WindowFullscreenLease::Restore() {
  if (!snapshot_) return true;
  if (!IsWindow(window_)) {
    snapshot_.reset();
    lease_id_ = 0;
    return true;
  }
  restoring_ = true;
  bool restored = SetStyle(window_, GWL_STYLE, snapshot_->style);
  restored = SetStyle(window_, GWL_EXSTYLE, snapshot_->exstyle) && restored;
  auto placement = snapshot_->placement;
  if (!(snapshot_->style & WS_VISIBLE)) placement.showCmd = SW_HIDE;
  restored = SetWindowPlacement(window_, &placement) != FALSE && restored;
  restored = SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                          SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                              SWP_NOACTIVATE | SWP_FRAMECHANGED) != FALSE &&
             restored;
  if (restored) {
    snapshot_.reset();
    lease_id_ = 0;
  }
  restoring_ = false;
  return restored;
}
