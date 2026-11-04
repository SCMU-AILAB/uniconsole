import 'package:flutter/material.dart';

import '../../core/platform/window_chrome.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';

/// 登录页与邀请页的外框：窗口背景上居中的品牌标识、标题和表单卡片。
/// 没有设计稿，沿用侧边栏品牌块与设置面板（白底、描边、圆角 14）的样式。
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.footer,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;

    final brand = Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.logo,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: AppIcon(AppIcons.sensors, size: 32, color: c.onLogo),
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: ExcludeSemantics(child: brand)),
        const SizedBox(height: AppSpacing.x4),
        Semantics(
          header: true,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: (mobile ? t.detailTitle : t.detailTitleSmall).copyWith(
              color: c.label,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.x1),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: (mobile ? t.mobileFootnote : t.subhead).copyWith(
            color: c.secondaryLabel,
          ),
        ),
        const SizedBox(height: AppSpacing.x6),
        Container(
          padding: EdgeInsets.all(mobile ? AppSpacing.x4 : AppSpacing.x5),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.separator),
          ),
          child: child,
        ),
        if (footer != null) ...[const SizedBox(height: AppSpacing.x5), footer!],
      ],
    );

    return Material(
      color: c.windowBackground,
      child: Column(
        children: [
          WindowDragArea(height: WindowChrome.titlebarHeight),
          Expanded(
            child: SafeArea(
              top: WindowChrome.titlebarHeight == 0,
              child: LayoutBuilder(
                builder: (context, box) => SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: mobile ? AppSpacing.x5 : AppSpacing.x6,
                    vertical: AppSpacing.x8,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (box.maxHeight - AppSpacing.x8 * 2).clamp(
                        0,
                        double.infinity,
                      ),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: mobile ? 440 : 360,
                        ),
                        child: column,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 表单项：上方小标题 + 输入框 + 可选说明。
class AuthField extends StatelessWidget {
  const AuthField({
    super.key,
    required this.label,
    required this.child,
    this.note,
  });

  final String label;
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;
    final small = mobile ? t.mobileFootnote : t.footnote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.half,
              bottom: AppSpacing.x1 + AppSpacing.half,
            ),
            child: Text(
              label,
              style: small.copyWith(
                color: c.secondaryLabel,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        child,
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.half,
              top: AppSpacing.x1 + AppSpacing.half,
            ),
            child: Text(note!, style: small.copyWith(color: c.secondaryLabel)),
          ),
      ],
    );
  }
}

/// 密码输入框，右侧「显示 / 隐藏」。
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.hint,
    this.focusNode,
    this.onSubmitted,
    this.newPassword = false,
    this.enabled = true,
    this.textInputAction = TextInputAction.done,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;

  /// 设置新密码（系统密码管理器会建议强密码）。
  final bool newPassword;
  final bool enabled;
  final TextInputAction textInputAction;
  final bool autofocus;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  var _visible = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mobile = LayoutSize.ofContext(context).isMobile;
    return AppTextField(
      hint: widget.hint,
      semanticLabel: widget.hint,
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mobile: mobile,
      enabled: widget.enabled,
      obscureText: !_visible,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: widget.textInputAction,
      autofillHints: [
        widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
      ],
      onSubmitted: widget.onSubmitted,
      suffix: Tooltip(
        message: _visible ? '隐藏密码' : '显示密码',
        child: Pressable(
          onTap: () => setState(() => _visible = !_visible),
          semanticLabel: _visible ? '隐藏密码' : '显示密码',
          focusRadius: AppRadius.xs,
          builder: (context, st) => Padding(
            padding: const EdgeInsets.all(AppSpacing.half),
            child: AppIcon(
              _visible ? AppIcons.eyeOff : AppIcons.eye,
              size: mobile ? 18 : 15,
              color: st.pressed ? c.label : c.secondaryLabel,
            ),
          ),
        ),
      ),
    );
  }
}
