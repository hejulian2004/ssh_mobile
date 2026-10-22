// 把 SDK 网络结果映射成页面结果。页面不导入 network_sdk。

import 'package:network_sdk/network_sdk.dart';

import '../../../domain/lan_page_outcome.dart';
import '../../../services/lan_share/lan_share_models.dart';

export '../../../domain/lan_page_outcome.dart';

/// 丢弃成功载荷，只把失败交给页面。
Future<LanUiOutcome<void>> lanUiIgnored<T>(
  Future<NetworkResult<T>> future,
) async {
  final result = await future;
  if (result is NetworkSuccess<T>) {
    return const LanUiOutcome<void>.success();
  }
  return LanUiOutcome<void>.failure(
    lanUiFailureFrom((result as NetworkFailure<T>).error),
  );
}

/// 保留成功载荷，供页面读取本领域进度。
Future<LanUiOutcome<T>> lanUiOf<T>(Future<NetworkResult<T>> future) async {
  final result = await future;
  if (result is NetworkSuccess<T>) {
    return LanUiOutcome<T>.success(result.data);
  }
  return LanUiOutcome<T>.failure(
    lanUiFailureFrom((result as NetworkFailure<T>).error),
  );
}

/// 映射一个可展示的网络失败。
LanUiFailure lanUiFailureFrom(NetworkError error) {
  return LanUiFailure(
    kind: switch (error.code) {
      NetworkErrorCode.authenticationFailed =>
        LanUiFailureKind.authenticationFailed,
      NetworkErrorCode.identityConflict => LanUiFailureKind.identityConflict,
      NetworkErrorCode.timeout => LanUiFailureKind.timeout,
      NetworkErrorCode.noRoute ||
      NetworkErrorCode.peerOffline => LanUiFailureKind.unreachable,
      NetworkErrorCode.cancelled => LanUiFailureKind.cancelled,
      NetworkErrorCode.invalidArgument => LanUiFailureKind.invalidArgument,
      NetworkErrorCode.resourceLimit => LanUiFailureKind.resourceLimit,
      _ => LanUiFailureKind.other,
    },
    message: error.message,
    retryable: isRetryableNetworkError(error.code),
    detail: error.toString(),
  );
}
