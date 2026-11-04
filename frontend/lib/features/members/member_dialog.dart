import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'member_widgets.dart';

/// 有效期选项。[keep] 表示保留成员当前的有效期。
enum _Expiry { keep, forever, today, week, month }

/// 编辑结果：保存或其他操作。
sealed class _Result {
  const _Result();
}

class _Save extends _Result {
  const _Save({
    required this.name,
    required this.handle,
    required this.role,
    required this.expiry,
    required this.granted,
    required this.videoOnly,
  });

  final String name;
  final String handle;
  final MemberRole role;
  final _Expiry expiry;
  final List<String> granted;
  final bool videoOnly;
}

class _ToggleDisabled extends _Result {
  const _ToggleDisabled();
}

class _Remove extends _Result {
  const _Remove();
}

DateTime? _expiryDate(_Expiry e, DateTime now) => switch (e) {
  _Expiry.keep || _Expiry.forever => null,
  _Expiry.today =>
    now.hour < 18
        ? DateTime(now.year, now.month, now.day, 18)
        : DateTime(now.year, now.month, now.day + 1, 18),
  _Expiry.week => DateTime(now.year, now.month, now.day + 7, 23, 59),
  _Expiry.month => DateTime(now.year, now.month, now.day + 30, 23, 59),
};

/// 邀请成员（[member] 为空）或编辑成员。
Future<void> showMemberDialog(
  BuildContext context,
  WidgetRef ref, {
  Member? member,
}) async {
  final result = await showAppDialog<_Result?>(
    context: context,
    builder: (context) => _MemberDialog(member: member),
  );
  if (result == null || !context.mounted) return;
  final now = DateTime.now();
  switch (result) {
    case _Save s when member == null:
      await runMemberAction(
        ref,
        (repo) => repo.invite(
          MemberDraft(
            name: s.name,
            handle: s.handle,
            role: s.role,
            expiresAt: _expiryDate(s.expiry, now),
            grantedDeviceIds: s.granted,
            videoOnly: s.videoOnly,
          ),
        ),
        success: '已邀请 ${s.name}，对方首次登录时设置密码',
      );
    case _Save s:
      await runMemberAction(
        ref,
        (repo) => repo.update(
          member.id,
          role: s.role == member.role ? null : s.role,
          expiresAt: _expiryDate(s.expiry, now),
          clearExpiry: s.expiry == _Expiry.forever,
          grantedDeviceIds: s.granted,
          videoOnly: s.videoOnly,
        ),
        success: '已保存 ${member!.name} 的权限',
      );
    case _ToggleDisabled():
      await runMemberAction(
        ref,
        (repo) => repo.update(member.id, disabled: !member.disabled),
        success: member!.disabled ? '已恢复 ${member.name}' : '已停用 ${member.name}',
      );
    case _Remove():
      final ok = await confirmAction(
        context,
        title: member!.guestLink ? '撤销访客链接？' : '移除 ${member.name}？',
        message: member.guestLink
            ? '链接立即失效，正在观看的画面会断开。'
            : '对方将无法登录，持有的控制权会被收回。审计日志保留。',
        confirmLabel: member.guestLink ? '撤销' : '移除',
        destructive: true,
      );
      if (!ok) return;
      await runMemberAction(
        ref,
        (repo) => repo.remove(member.id),
        success: member.guestLink ? '已撤销访客链接' : '已移除 ${member.name}',
      );
  }
}

class _MemberDialog extends ConsumerStatefulWidget {
  const _MemberDialog({this.member});

  final Member? member;

  @override
  ConsumerState<_MemberDialog> createState() => _MemberDialogState();
}

class _MemberDialogState extends ConsumerState<_MemberDialog> {
  final _name = TextEditingController();
  final _handle = TextEditingController();
  late MemberRole _role = widget.member?.role ?? MemberRole.user;
  late _Expiry _expiry = widget.member == null ? _Expiry.forever : _Expiry.keep;
  late final Set<String> _granted = {...?widget.member?.grantedDeviceIds};
  late bool _videoOnly = widget.member?.videoOnly ?? false;

  bool get _invite => widget.member == null;

  @override
  void dispose() {
    _name.dispose();
    _handle.dispose();
    super.dispose();
  }

  bool get _valid =>
      !_invite ||
      (_name.text.trim().isNotEmpty && _handle.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;
    final m = widget.member;
    final me = ref.watch(currentUserProvider).value;
    final self = m != null && m.id == me?.id;
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final now = DateTime.now();

    Widget field(String label, Widget child, {String? note}) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: t.subheadStrong.copyWith(color: c.secondaryLabel)),
          const SizedBox(height: AppSpacing.x1),
          child,
          if (note != null) ...[
            const SizedBox(height: AppSpacing.x1),
            Text(note, style: t.footnote.copyWith(color: c.secondaryLabel)),
          ],
        ],
      ),
    );

    final expiryOptions = [
      if (!_invite)
        MenuOption(_Expiry.keep, '不变（${expiryText(m!.expiresAt, now)}）'),
      const MenuOption(_Expiry.forever, '长期'),
      MenuOption(_Expiry.today, now.hour < 18 ? '今天 18:00 失效' : '明天 18:00 失效'),
      const MenuOption(_Expiry.week, '7 天'),
      const MenuOption(_Expiry.month, '30 天'),
    ];

    final managed = [
      for (final d in devices)
        if (m != null && d.ownerId == m.id) d.id,
    ];

    return AppAlert<_Result?>(
      title: _invite ? '邀请成员' : '编辑 ${m!.name}',
      message: _invite ? null : '${m!.handle} · ${lastSeenText(m, now)}',
      maxWidth: mobile ? 340 : 440,
      primaryEnabled: _valid,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_invite) ...[
            field(
              '姓名',
              AppTextField(
                hint: '如「王五」',
                controller: _name,
                autofocus: true,
                mobile: mobile,
                onChanged: (_) => setState(() {}),
              ),
            ),
            field(
              '账号',
              AppTextField(
                hint: '@handle',
                semanticLabel: '账号',
                controller: _handle,
                mobile: mobile,
                onChanged: (_) => setState(() {}),
              ),
              note: '对方首次登录时设置密码',
            ),
          ],
          field(
            '角色',
            SegmentedControl<MemberRole>(
              semanticLabel: '角色',
              expand: true,
              size: mobile ? SegmentedSize.mobile : SegmentedSize.small,
              options: [
                for (final r in MemberRole.values)
                  SegmentOption(r, r.shortLabel),
              ],
              value: _role,
              onChanged: self ? (_) {} : (v) => setState(() => _role = v),
            ),
            note: self ? '不能修改自己的角色' : _roleNote(_role),
          ),
          if (_role != MemberRole.admin)
            field(
              '可访问设备',
              Wrap(
                spacing: AppSpacing.x4,
                runSpacing: AppSpacing.x2,
                children: [
                  for (final d in devices)
                    SizedBox(
                      width: 120,
                      child: AppCheckbox(
                        label: managed.contains(d.id)
                            ? '${d.name}（管理）'
                            : d.name,
                        value:
                            managed.contains(d.id) || _granted.contains(d.id),
                        onChanged: managed.contains(d.id)
                            ? null
                            : (v) => setState(
                                () => v
                                    ? _granted.add(d.id)
                                    : _granted.remove(d.id),
                              ),
                      ),
                    ),
                ],
              ),
              note: managed.isEmpty ? null : '自己管理的设备由设备归属决定，在设备详情里修改',
            ),
          if (_role == MemberRole.viewer)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x3),
              child: AppCheckbox(
                label: '仅视频（不显示传感器与日志）',
                value: _videoOnly,
                onChanged: (v) => setState(() => _videoOnly = v),
              ),
            ),
          field(
            '有效期',
            AppMenu<_Expiry>(
              options: expiryOptions,
              selected: _expiry,
              onSelected: (v) => setState(() => _expiry = v),
              anchor: (context, toggle) => SecondaryButton(
                label: expiryOptions
                    .firstWhere((o) => o.value == _expiry)
                    .label,
                trailingIcon: AppIcons.chevronDown,
                onPressed: toggle,
              ),
            ),
          ),
          if (!_invite && !self)
            Wrap(
              spacing: AppSpacing.x2,
              runSpacing: AppSpacing.x2,
              children: [
                SecondaryButton(
                  label: m!.disabled ? '恢复账号' : '停用账号',
                  onPressed: () =>
                      Navigator.of(context).pop(const _ToggleDisabled()),
                ),
                DestructiveButton(
                  label: m.guestLink ? '撤销链接' : '移除成员',
                  onPressed: () => Navigator.of(context).pop(const _Remove()),
                ),
              ],
            ),
        ],
      ),
      actions: [
        const AlertAction<_Result?>(
          label: '取消',
          value: null,
          kind: AlertActionKind.cancel,
        ),
        AlertAction<_Result?>(
          label: _invite ? '邀请' : '保存',
          value: _Save(
            name: _name.text.trim(),
            handle: _handle.text.trim(),
            role: _role,
            expiry: _expiry,
            granted: [
              for (final d in devices)
                if (_granted.contains(d.id) && !managed.contains(d.id)) d.id,
            ],
            videoOnly: _role == MemberRole.viewer && _videoOnly,
          ),
        ),
      ],
    );
  }

  static String _roleNote(MemberRole r) => switch (r) {
    MemberRole.admin => '可访问全部设备，管理成员与角色',
    MemberRole.owner => '管理自己名下的设备，可分配使用者',
    MemberRole.user => '可申请被授权设备的控制权',
    MemberRole.viewer => '只能查看被授权设备，不能操控',
  };
}
