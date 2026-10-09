import 'app/network_app_bootstrap.dart';

/// 网络传输 App 的入口。资源装配由 App Shell 负责。
// coverage:ignore-start
Future<void> main() async {
  await NetworkAppBootstrap.run();
}
// coverage:ignore-end
