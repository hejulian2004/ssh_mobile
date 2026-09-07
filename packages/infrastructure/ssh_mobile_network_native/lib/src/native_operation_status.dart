// Native network status 的 Dart 类型化表示。
//
// C ABI 仍使用整数返回值，但整数只在本文件的转换边界出现，
// package 公共 API 和 Flutter 业务代码只接触此枚举。

/// 描述一次原生网络操作的安全结果状态。
enum NativeOperationStatus {
  success,
  invalidArgument,
  unknownSession,
  staleGeneration,
  staleEndpoint,
  directionMismatch,
  duplicateEndpoint,
  driverUnavailable,
  peerMismatch,
  frameRejected,
  stopped,
  failure;

  /// 将 C ABI 整数状态转换为 Dart 类型。
  static NativeOperationStatus fromNativeCode(int value) => switch (value) {
    0 => success,
    -1 || -2 => invalidArgument,
    -4 => stopped,
    _ => failure,
  };

  /// Converts the media-bridge ABI status space. The general command ABI
  /// keeps its historical `-2 == invalidArgument` mapping; media lifecycle
  /// calls use this typed translation so stale/ownership failures survive the
  /// Dart/native boundary.
  static NativeOperationStatus fromRealtimeMediaCode(int value) =>
      switch (value) {
        0 => success,
        -1 => invalidArgument,
        -2 => unknownSession,
        -3 => failure,
        -4 => stopped,
        -5 => staleGeneration,
        -6 => staleEndpoint,
        -7 => directionMismatch,
        -8 => duplicateEndpoint,
        -9 => driverUnavailable,
        -10 => peerMismatch,
        -11 => frameRejected,
        _ => failure,
      };

  /// 返回当前状态是否表示操作已成功完成。
  bool get isSuccess => this == success;
}
