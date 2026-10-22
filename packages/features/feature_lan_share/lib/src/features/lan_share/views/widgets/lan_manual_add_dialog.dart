// LAN Control Protocol V2 手动连接目标设备对话框。

import 'package:flutter/material.dart';

/// 手动输入设备 IP、端口或快传网页链接的对话框。
///
/// 拥有自己的 [TextEditingController] 生命周期，避免在对话框退出动画期间
/// 控制器过早 dispose 导致 `A TextEditingController was used after being disposed` 异常。
class LanManualAddDialog extends StatefulWidget {
  final String title;
  final String description;
  final String hint;
  final String cancelLabel;
  final String confirmLabel;

  const LanManualAddDialog({
    super.key,
    required this.title,
    required this.description,
    required this.hint,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  /// 便捷展示手动添加设备对话框并返回用户输入的地址。
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String description,
    required String hint,
    required String cancelLabel,
    required String confirmLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => LanManualAddDialog(
        title: title,
        description: description,
        hint: hint,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
      ),
    );
  }

  @override
  State<LanManualAddDialog> createState() => _LanManualAddDialogState();
}

class _LanManualAddDialogState extends State<LanManualAddDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) {
    Navigator.pop(context, value.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: widget.hint,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: _submit,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        TextButton(
          onPressed: () => _submit(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
