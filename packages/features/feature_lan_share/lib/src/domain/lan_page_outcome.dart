// 页面对一次局域网操作的结果。不含 SDK 传输对象。

/// 页面需要区分的失败类别。
enum LanUiFailureKind {
  authenticationFailed,
  identityConflict,
  timeout,
  unreachable,
  cancelled,
  invalidArgument,
  resourceLimit,
  other,
}

/// 可展示给页面的失败信息。
final class LanUiFailure {
  /// 创建页面失败。
  const LanUiFailure({
    required this.kind,
    required this.message,
    required this.retryable,
    required this.detail,
  });

  final LanUiFailureKind kind;
  final String message;
  final bool retryable;

  /// 日志用的非敏感描述。
  final String detail;
}

/// 页面消费的成功或失败。
final class LanUiOutcome<T> {
  /// 创建成功结果。[value] 对不携带载荷的操作可以为空。
  const LanUiOutcome.success([this.value]) : failure = null;

  /// 创建失败结果。
  const LanUiOutcome.failure(this.failure) : value = null;

  final T? value;
  final LanUiFailure? failure;

  /// 操作是否成功。
  bool get succeeded => failure == null;
}

/// 传入传输审批在页面上需要的字段和回调。
final class LanPageIncomingOffer {
  /// 创建页面传入申请。
  const LanPageIncomingOffer({
    required this.transferId,
    required this.peerId,
    required this.fileName,
    required this.fileSize,
    required this.accept,
    required this.reject,
  });

  final String transferId;
  final String peerId;
  final String fileName;
  final int fileSize;
  final Future<LanUiOutcome<void>> Function() accept;
  final Future<LanUiOutcome<void>> Function() reject;
}
