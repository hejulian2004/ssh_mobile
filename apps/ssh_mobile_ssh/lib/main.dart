import 'app/ssh_app_bootstrap.dart';

/// SSH-only App 的入口。资源装配由 App Shell 负责。
// coverage:ignore-start
Future<void> main() async {
  await SshAppBootstrap.run();
}
// coverage:ignore-end
