// SSH-only App 的连接列表。
//
// 列表只展示非敏感端点。点击后由 App Scope 终端能力建立直接 TCP 会话。

import 'dart:async';

import 'package:feature_connection/feature_connection.dart';
import 'package:feature_terminal/feature_terminal.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ssh_app_runtime.dart';

/// 已保存 SSH 连接的首页。
final class SshHomeScreen extends StatefulWidget {
  /// 创建连接首页。
  const SshHomeScreen({super.key});

  @override
  State<SshHomeScreen> createState() => _SshHomeScreenState();
}

class _SshHomeScreenState extends State<SshHomeScreen> {
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    // 首帧还在挂载 Provider，不能在 initState 里同步通知 ViewModel。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (!mounted) return;
    await context.read<ConnectionViewModel>().fetchConnections();
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = context.watch<ConnectionViewModel>();
    final connections = viewModel.connections;
    return Scaffold(
      appBar: AppBar(title: const Text('SSH')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(ConnectionRouteNames.add),
        icon: const Icon(Icons.add),
        label: const Text('添加连接'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : connections.isEmpty
          ? Center(
              child: Text(viewModel.errorMessage == null ? '还没有连接' : '无法读取连接'),
            )
          : ListView.separated(
              itemCount: connections.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final connection = connections[index];
                return ListTile(
                  title: Text(connection.name),
                  subtitle: Text(
                    '${connection.username}@${connection.host}:${connection.port}',
                  ),
                  onTap: () => _connect(connection),
                  trailing: IconButton(
                    tooltip: '编辑',
                    onPressed: () => _openEditor(
                      ConnectionRouteNames.edit,
                      arguments: connection.id,
                    ),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _openEditor(String route, {Object? arguments}) async {
    final result = await Navigator.pushNamed(
      context,
      route,
      arguments: arguments,
    );
    if (!mounted || result == null) return;
    await context.read<ConnectionViewModel>().fetchConnections();
  }

  Future<void> _connect(ConnectionConfig connection) async {
    final runtime = context.read<SshOnlyAppRuntime>();
    final sessionId = await runtime.terminalCapability.openSession(
      connection.id,
    );
    if (!mounted) return;
    if (sessionId == null) {
      final message =
          runtime.terminalCapability.errorMessage ?? 'SSH connection failed.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    await Navigator.pushNamed(
      context,
      TerminalRouteNames.terminal,
      arguments: <String, dynamic>{'id': connection.id, 'sessionId': sessionId},
    );
  }
}
