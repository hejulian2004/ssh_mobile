#ifndef RUNNER_WINDOW_FULLSCREEN_H_
#define RUNNER_WINDOW_FULLSCREEN_H_

#include <windows.h>

#include <cstdint>
#include <optional>

// App window owner: a lease snapshots placement/style once and restores it.
class WindowFullscreenLease {
 public:
  explicit WindowFullscreenLease(HWND window) : window_(window) {}
  ~WindowFullscreenLease();
  WindowFullscreenLease(const WindowFullscreenLease&) = delete;
  WindowFullscreenLease& operator=(const WindowFullscreenLease&) = delete;
  bool SetFullscreen(int64_t lease_id, bool enabled);
  bool Refresh();

 private:
  struct Snapshot {
    LONG_PTR style;
    LONG_PTR exstyle;
    WINDOWPLACEMENT placement;
  };
  bool Restore();
  HWND window_;
  int64_t lease_id_ = 0;
  bool restoring_ = false;
  std::optional<Snapshot> snapshot_;
};

#endif  // RUNNER_WINDOW_FULLSCREEN_H_
