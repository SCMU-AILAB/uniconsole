import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'app_icon.dart';
import 'pressable.dart';

/// 分组列表的一行。桌面版 13 号字，移动版（[GroupedListScope.mobile]）15–16 号字、最小高 44。
class GroupedListRow extends StatelessWidget {
  const GroupedListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.value,
    this.trailing,
    this.onTap,
    this.showChevron,
    this.selected = false,
    this.titleWeight,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;

  /// 右侧灰字值（键值行，如「固件版本  v1.1.6」）。
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 默认在可点击时显示 ›。
  final bool? showChevron;
  final bool selected;
  final FontWeight? titleWeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = GroupedListScope.isMobile(context);
    final chevron = showChevron ?? onTap != null;

    Widget row(bool hovered) => Container(
      constraints: BoxConstraints(
        minHeight: mobile ? AppSizes.minTouchTarget : 0,
      ),
      color: selected
          ? c.rowSelected
          : hovered
          ? c.label.withValues(alpha: 0.04)
          : Colors.transparent,
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 14 : AppSpacing.xl,
        vertical: mobile ? AppSpacing.lg : 9,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            SizedBox(width: mobile ? AppSpacing.xl : AppSpacing.lg),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: (mobile ? t.mobileBody : t.body).copyWith(
                    color:
                        value != null &&
                            subtitle == null &&
                            leading == null &&
                            !mobile
                        ? c.secondaryLabel
                        : c.label,
                    fontWeight: titleWeight,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: (mobile ? t.mobileFootnote : t.footnote).copyWith(
                      color: c.secondaryLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: AppSpacing.lg),
            Text(
              value!,
              textAlign: TextAlign.right,
              style: (mobile ? t.mobileBody : t.body).copyWith(
                color: mobile || subtitle != null || leading != null
                    ? c.secondaryLabel
                    : c.label,
              ),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.lg),
            trailing!,
          ],
          if (chevron) ...[
            const SizedBox(width: AppSpacing.md),
            AppIcon(
              AppIcons.chevronRight,
              size: mobile ? 14 : 12,
              color: c.decorativeGray,
              strokeWidth: 2.4,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return Semantics(container: true, child: row(false));
    return Pressable(
      onTap: onTap,
      selected: selected,
      focusRadius: 0,
      builder: (context, st) => row(st.hovered),
    );
  }
}

/// 让行组件知道自己处在移动端分组里。
class GroupedListScope extends InheritedWidget {
  const GroupedListScope({
    super.key,
    required this.mobile,
    required super.child,
  });

  final bool mobile;

  static bool isMobile(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GroupedListScope>()?.mobile ??
      false;

  @override
  bool updateShouldNotify(GroupedListScope old) => old.mobile != mobile;
}

List<Widget> _withDividers(
  BuildContext context,
  List<Widget> rows, {
  double indent = 0,
}) {
  final c = context.colors;
  final out = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    out.add(rows[i]);
    if (i < rows.length - 1) {
      out.add(
        Padding(
          padding: EdgeInsets.only(left: indent),
          child: Container(height: 1, color: c.separator),
        ),
      );
    }
  }
  return out;
}

/// 桌面分组列表（检查器里的「人员与权限」「设备信息」）：
/// 12 号灰色小标题 + 灰底圆角 10 的行组。
class GroupedList extends StatelessWidget {
  const GroupedList({
    super.key,
    this.header,
    required this.children,
    this.footer,
  });

  final String? header;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GroupedListScope(
      mobile: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpacing.sm),
              child: Semantics(
                header: true,
                child: Text(
                  header!,
                  style: context.type.subheadStrong.copyWith(
                    color: c.secondaryLabel,
                  ),
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.group),
            child: ColoredBox(
              color: c.windowBackground,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _withDividers(context, children),
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, AppSpacing.sm, 4, 0),
              child: Text(
                footer!,
                style: context.type.footnote.copyWith(color: c.secondaryLabel),
              ),
            ),
        ],
      ),
    );
  }
}

/// 移动端 inset grouped 分组（iOS 设置风格）：13 号灰色小标题 + 白底圆角 12 卡片。
class InsetGroupedSection extends StatelessWidget {
  const InsetGroupedSection({
    super.key,
    this.header,
    required this.children,
    this.footer,
    this.dividerIndent = 14,
  });

  final String? header;
  final List<Widget> children;
  final String? footer;

  /// 分割线左缩进（有图标时与文字对齐）。
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GroupedListScope(
      mobile: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, AppSpacing.sm),
              child: Semantics(
                header: true,
                child: Text(
                  header!,
                  style: context.type.mobileFootnote.copyWith(
                    color: c.secondaryLabel,
                  ),
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.tile),
            child: ColoredBox(
              color: c.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _withDividers(
                  context,
                  children,
                  indent: dividerIndent,
                ),
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, AppSpacing.sm, 16, 0),
              child: Text(
                footer!,
                style: context.type.mobileFootnote.copyWith(
                  color: c.secondaryLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
