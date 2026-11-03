import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import 'buttons.dart';
import 'controls.dart';

enum AlertActionKind { cancel, primary, destructive }

class AlertAction<T> {
  const AlertAction({
    required this.label,
    required this.value,
    this.kind = AlertActionKind.primary,
  });

  final String label;

  /// 点击后对话框返回的值。
  final T value;
  final AlertActionKind kind;
}

/// 弹出提示框（NSAlert / UIAlertController 的居中形式）。
///
/// 出现时从 104% 缩小到 100% 并淡入（系统提示框的方式），减弱动态效果时只淡入。
/// Esc 关闭（返回 null），回车触发主操作。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final c = context.colors;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: '关闭',
    barrierColor: c.shadow.withValues(alpha: 0.18),
    transitionDuration: AppMotion.highlight * 2,
    pageBuilder: (context, _, _) => builder(context),
    transitionBuilder: (context, animation, _, child) {
      final fade = FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
      if (AppMotion.reduced(context)) return fade;
      return ScaleTransition(
        scale: Tween(begin: 1.04, end: 1.0).animate(
          CurvedAnimation(
            parent: animation,
            curve: AppMotion.snappy,
            reverseCurve: Curves.easeIn,
          ),
        ),
        child: fade,
      );
    },
  );
}

/// 提示框外观：标题、说明、可选内容、按钮行。
class AppAlert<T> extends StatelessWidget {
  const AppAlert({
    super.key,
    required this.title,
    this.message,
    this.content,
    required this.actions,
    this.primaryEnabled = true,
  });

  final String title;
  final String? message;
  final Widget? content;
  final List<AlertAction<T>> actions;

  /// 主操作是否可用（如必填原因为空时禁用）。
  final bool primaryEnabled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;
    final primary = actions
        .where((a) => a.kind != AlertActionKind.cancel)
        .lastOrNull;

    Widget button(AlertAction<T> a) {
      final enabled = a.kind == AlertActionKind.cancel || primaryEnabled;
      void tap() => Navigator.of(context).pop(a.value);
      final size = mobile ? ButtonSize.large : ButtonSize.regular;
      return switch (a.kind) {
        AlertActionKind.cancel => SecondaryButton(
          label: a.label,
          onPressed: tap,
          size: size,
          expand: true,
        ),
        AlertActionKind.primary => PrimaryButton(
          label: a.label,
          onPressed: enabled ? tap : null,
          size: size,
          expand: true,
        ),
        AlertActionKind.destructive => DestructiveButton(
          label: a.label,
          onPressed: enabled ? tap : null,
          size: size,
          expand: true,
        ),
      };
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
        if (primary != null && primaryEnabled)
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              Navigator.of(context).pop(primary.value),
      },
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: mobile ? 300 : 340),
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              label: title,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.x5),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: c.separator),
                    boxShadow: [
                      BoxShadow(
                        color: c.shadow.withValues(alpha: 0.18),
                        blurRadius: 32,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: (mobile ? t.mobileHeadline : t.headline)
                              .copyWith(color: c.label),
                        ),
                      ),
                      if (message != null) ...[
                        const SizedBox(height: AppSpacing.x2),
                        Text(
                          message!,
                          textAlign: TextAlign.center,
                          style: (mobile ? t.mobileFootnote : t.subhead)
                              .copyWith(color: c.secondaryLabel),
                        ),
                      ],
                      if (content != null) ...[
                        const SizedBox(height: AppSpacing.x4),
                        content!,
                      ],
                      const SizedBox(height: AppSpacing.x5),
                      Row(
                        children: [
                          for (final (i, a) in actions.indexed) ...[
                            if (i > 0) const SizedBox(width: AppSpacing.x2),
                            Expanded(child: button(a)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 确认框：返回 true 表示确认。
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) => AppAlert<bool>(
      title: title,
      message: message,
      actions: [
        const AlertAction(
          label: '取消',
          value: false,
          kind: AlertActionKind.cancel,
        ),
        AlertAction(
          label: confirmLabel,
          value: true,
          kind: destructive
              ? AlertActionKind.destructive
              : AlertActionKind.primary,
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 带输入框的提示框：返回输入的文字，取消时为 null。[required] 为真时空输入不能确认。
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? message,
  required String hint,
  required String confirmLabel,
  String initial = '',
  bool required = true,
  bool destructive = false,
  bool multiline = false,
}) => showAppDialog<String>(
  context: context,
  builder: (context) => _PromptDialog(
    title: title,
    message: message,
    hint: hint,
    confirmLabel: confirmLabel,
    initial: initial,
    required: required,
    destructive: destructive,
    multiline: multiline,
  ),
);

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.message,
    required this.hint,
    required this.confirmLabel,
    required this.initial,
    required this.required,
    required this.destructive,
    required this.multiline,
  });

  final String title;
  final String? message;
  final String hint;
  final String confirmLabel;
  final String initial;
  final bool required;
  final bool destructive;
  final bool multiline;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _valid => !widget.required || _text.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // 每次输入都会重建，主操作的返回值即当前文字。
    return AppAlert<String?>(
      title: widget.title,
      message: widget.message,
      primaryEnabled: _valid,
      content: AppTextField(
        hint: widget.hint,
        controller: _text,
        autofocus: true,
        minLines: widget.multiline ? 3 : 1,
        mobile: LayoutSize.ofContext(context).isMobile,
        onChanged: (_) => setState(() {}),
        onSubmitted: (v) {
          if (_valid) Navigator.of(context).pop(v.trim());
        },
      ),
      actions: [
        const AlertAction<String?>(
          label: '取消',
          value: null,
          kind: AlertActionKind.cancel,
        ),
        AlertAction<String?>(
          label: widget.confirmLabel,
          value: _text.text.trim(),
          kind: widget.destructive
              ? AlertActionKind.destructive
              : AlertActionKind.primary,
        ),
      ],
    );
  }
}
