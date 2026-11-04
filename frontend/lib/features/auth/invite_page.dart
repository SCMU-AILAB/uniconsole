import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'auth_widgets.dart';

/// 邀请页（深链 `uniconsole://invite/<token>` → `/invite/<token>`）：
/// 先 `GET /auth/invites/{token}` 显示「为 林悦（@linyue）设置密码」，
/// 再 `accept`，成功即已登录，进入设备总览。
class InvitePage extends ConsumerStatefulWidget {
  const InvitePage({super.key, required this.token});

  final String token;

  @override
  ConsumerState<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends ConsumerState<InvitePage> {
  late final Future<InviteInfo> _info = ref
      .read(authRepositoryProvider)
      .invite(widget.token);
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _confirmFocus = FocusNode();
  final _handle = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    _confirmFocus.dispose();
    _handle.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final problem = passwordProblem(_password.text);
    if (problem != null || _password.text != _confirm.text) {
      setState(() => _error = problem ?? '两次输入的密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .acceptInvite(widget.token, _password.text);
      TextInput.finishAutofillContext();
      if (mounted) context.go(Routes.devices);
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;

    return FutureBuilder<InviteInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        if (snap.hasError) {
          final e = snap.error;
          return AuthScaffold(
            title: '邀请链接不可用',
            subtitle: '链接只能使用一次，7 天内有效',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppBanner(
                  kind: BannerKind.warning,
                  message: e is AuthException ? e.message : '无法打开邀请链接',
                ),
                const SizedBox(height: AppSpacing.x5),
                SecondaryButton(
                  label: '前往登录',
                  size: ButtonSize.large,
                  expand: true,
                  onPressed: () => context.go(Routes.login),
                ),
              ],
            ),
          );
        }
        if (info == null) {
          return AuthScaffold(
            title: '设置密码',
            subtitle: '正在读取邀请…',
            child: SizedBox(
              height: 120,
              child: Center(
                child: Semantics(
                  label: '正在读取邀请',
                  child: CircularProgressIndicator.adaptive(
                    valueColor: AlwaysStoppedAnimation(c.secondaryLabel),
                  ),
                ),
              ),
            ),
          );
        }
        _handle.text = info.handle;
        final days =
            (info.expiresAt.difference(DateTime.now()).inMinutes / (24 * 60))
                .ceil();
        return AuthScaffold(
          title: '设置密码',
          subtitle: '为 ${info.name}（${info.handle}）设置登录密码',
          footer: Text(
            days > 1 ? '邀请链接 $days 天内有效，只能使用一次。' : '邀请链接今天内有效，只能使用一次。',
            textAlign: TextAlign.center,
            style: (mobile ? t.mobileFootnote : t.footnote).copyWith(
              color: c.secondaryLabel,
            ),
          ),
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AuthField(
                  label: '账号',
                  child: AppTextField(
                    hint: info.handle,
                    semanticLabel: '账号 ${info.handle}',
                    controller: _handle,
                    mobile: mobile,
                    enabled: false,
                    autofillHints: const [AutofillHints.username],
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                AuthField(
                  label: '新密码',
                  note: '至少 8 位',
                  child: PasswordField(
                    hint: '新密码',
                    controller: _password,
                    newPassword: true,
                    autofocus: !mobile,
                    enabled: !_busy,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _confirmFocus.requestFocus(),
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                AuthField(
                  label: '再次输入',
                  child: PasswordField(
                    hint: '再次输入新密码',
                    controller: _confirm,
                    focusNode: _confirmFocus,
                    newPassword: true,
                    enabled: !_busy,
                    onSubmitted: (_) => _submit(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.x4),
                  AppBanner(kind: BannerKind.critical, message: _error!),
                ],
                const SizedBox(height: AppSpacing.x5),
                PrimaryButton(
                  label: _busy ? '正在设置…' : '设置密码并登录',
                  size: ButtonSize.large,
                  expand: true,
                  onPressed: _busy ? null : _submit,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
