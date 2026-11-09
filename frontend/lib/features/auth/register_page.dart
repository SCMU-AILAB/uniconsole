import 'dart:async';

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

/// 邮箱注册（API `POST /auth/register/code` → `POST /auth/register`）。没有设计稿，样式同登录页。
///
/// 两步：服务器 + 邮箱 → 发验证码；再填验证码、名字、账号、密码，注册成功即登录。
/// 新账号是观察者（只能看），由管理员在「成员与权限」里调整角色。
class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  late final _server = TextEditingController(
    text: ref.read(authRepositoryProvider).lastServer,
  );
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _handle = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _emailFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _nameFocus = FocusNode();
  final _handleFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();

  var _busy = false;

  /// 验证码已发出，进入第二步。
  var _codeSent = false;
  String? _error;
  DateTime? _resendAt;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    for (final c in [
      _server,
      _email,
      _code,
      _name,
      _handle,
      _password,
      _confirm,
    ]) {
      c.dispose();
    }
    for (final f in [
      _emailFocus,
      _codeFocus,
      _nameFocus,
      _handleFocus,
      _passwordFocus,
      _confirmFocus,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  int get _resendSeconds {
    final at = _resendAt;
    if (at == null) return 0;
    final left = at.difference(DateTime.now());
    return left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  void _countdown(Duration d) {
    _resendAt = DateTime.now().add(d);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_resendSeconds == 0) t.cancel();
      setState(() {});
    });
  }

  void _focusLater(FocusNode node) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) node.requestFocus();
      });

  Future<void> _sendCode() async {
    if (_busy || _resendSeconds > 0) return;
    final problem = _server.text.trim().isEmpty
        ? '请填写服务器地址'
        : emailProblem(_email.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wait = await ref
          .read(authRepositoryProvider)
          .requestRegisterCode(server: _server.text, email: _email.text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (!_codeSent) _focusLater(_codeFocus);
        _codeSent = true;
      });
      _countdown(wait);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
      if (e.retryAfter case final d?) _countdown(d);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final String? problem;
    if (_code.text.trim().length != 6) {
      problem = '请输入邮件里的 6 位验证码';
    } else if (_name.text.trim().isEmpty) {
      problem = '请填写名字';
    } else {
      problem =
          handleProblem(_handle.text) ??
          passwordProblem(_password.text) ??
          (_password.text != _confirm.text ? '两次输入的密码不一致' : null);
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .register(
            server: _server.text,
            draft: RegisterDraft(
              email: _email.text,
              code: _code.text,
              handle: _handle.text,
              name: _name.text,
              password: _password.text,
            ),
          );
      TextInput.finishAutofillContext();
      if (mounted) context.go(Routes.devices);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
        if (e.message.contains('验证码')) {
          _code.clear();
          _focusLater(_codeFocus);
        } else if (e.message.contains('账号')) {
          _focusLater(_handleFocus);
        }
      });
    }
  }

  void _back() => setState(() {
    _codeSent = false;
    _error = null;
    _code.clear();
    _focusLater(_emailFocus);
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;
    const size = ButtonSize.large;
    final resend = _resendSeconds;

    final fields = _codeSent
        ? <Widget>[
            Text(
              '验证码已发送到 ${_email.text.trim()}，10 分钟内有效。',
              style: (mobile ? t.mobileBody : t.body).copyWith(color: c.label),
            ),
            const SizedBox(height: AppSpacing.x4),
            AuthField(
              label: '验证码',
              child: Row(
                children: [
                  Expanded(
                    child: AppTextField(
                      hint: '6 位数字',
                      semanticLabel: '邮箱验证码',
                      controller: _code,
                      focusNode: _codeFocus,
                      mobile: mobile,
                      monospace: true,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => _nameFocus.requestFocus(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  SecondaryButton(
                    label: resend > 0 ? '$resend 秒后重发' : '重新发送',
                    onPressed: _busy || resend > 0 ? null : _sendCode,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            AuthField(
              label: '名字',
              child: AppTextField(
                hint: '其他成员看到的名字',
                semanticLabel: '名字',
                controller: _name,
                focusNode: _nameFocus,
                mobile: mobile,
                enabled: !_busy,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _handleFocus.requestFocus(),
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            AuthField(
              label: '账号',
              note: '小写字母、数字、_ . -',
              child: AppTextField(
                hint: '@账号',
                semanticLabel: '账号',
                controller: _handle,
                focusNode: _handleFocus,
                mobile: mobile,
                enabled: !_busy,
                autofillHints: const [AutofillHints.newUsername],
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            AuthField(
              label: '密码',
              note: '至少 8 位',
              child: PasswordField(
                hint: '密码',
                controller: _password,
                focusNode: _passwordFocus,
                newPassword: true,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _confirmFocus.requestFocus(),
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            AuthField(
              label: '再次输入',
              child: PasswordField(
                hint: '再次输入密码',
                controller: _confirm,
                focusNode: _confirmFocus,
                newPassword: true,
                enabled: !_busy,
                onSubmitted: (_) => _submit(),
              ),
            ),
          ]
        : <Widget>[
            AuthField(
              label: '服务器',
              child: AppTextField(
                hint: 'console.example.com',
                semanticLabel: '服务器地址',
                controller: _server,
                mobile: mobile,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autofillHints: const [AutofillHints.url],
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _emailFocus.requestFocus(),
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            AuthField(
              label: '邮箱',
              child: AppTextField(
                hint: 'name@example.com',
                semanticLabel: '邮箱',
                controller: _email,
                focusNode: _emailFocus,
                autofocus: !mobile,
                mobile: mobile,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                onSubmitted: (_) => _sendCode(),
              ),
            ),
          ];

    final String label;
    if (_codeSent) {
      label = _busy ? '正在注册…' : '注册并登录';
    } else if (resend > 0) {
      label = '$resend 秒后可重新获取';
    } else {
      label = _busy ? '正在发送…' : '发送验证码';
    }

    return AuthScaffold(
      title: '注册 UniConsole',
      subtitle: '用邮箱注册，注册后为观察者',
      footer: Column(
        children: [
          Text(
            '观察者可以查看设备和画面，不能操控。\n需要更多权限请联系平台管理员。',
            textAlign: TextAlign.center,
            style: (mobile ? t.mobileFootnote : t.footnote).copyWith(
              color: c.secondaryLabel,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          AuthLink(
            label: '已有账号？登录',
            onTap: _busy ? null : () => context.go(Routes.login),
          ),
        ],
      ),
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedSwitcher(
              duration: AppMotion.appearance,
              switchInCurve: AppMotion.smooth,
              child: Column(
                key: ValueKey(_codeSent),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: fields,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.x4),
              AppBanner(kind: BannerKind.critical, message: _error!),
            ],
            const SizedBox(height: AppSpacing.x5),
            PrimaryButton(
              label: label,
              size: size,
              expand: true,
              onPressed: _busy || (!_codeSent && resend > 0)
                  ? null
                  : (_codeSent ? _submit : _sendCode),
            ),
            if (_codeSent) ...[
              const SizedBox(height: AppSpacing.x2),
              SecondaryButton(
                label: '修改邮箱',
                size: size,
                expand: true,
                onPressed: _busy ? null : _back,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
