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

/// 登录（API `POST /auth/login`）。没有设计稿，样式沿用应用的表单与卡片。
///
/// 两步：服务器 + 账号 + 密码；账号开启了二次验证时服务端返回
/// `two_factor_required`，再输入 6 位验证码。登录成功后由路由守卫回到原页面。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  late final _server = TextEditingController(
    text: ref.read(authRepositoryProvider).lastServer,
  );
  final _handle = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _handleFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _codeFocus = FocusNode();

  var _busy = false;
  var _needsCode = false;
  String? _error;
  DateTime? _lockedUntil;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    for (final c in [_server, _handle, _password, _code]) {
      c.dispose();
    }
    for (final f in [_handleFocus, _passwordFocus, _codeFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  int get _lockSeconds {
    final until = _lockedUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now());
    return left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  void _lock(Duration d) {
    _lockedUntil = DateTime.now().add(d);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_lockSeconds == 0) {
        t.cancel();
        setState(() {
          _lockedUntil = null;
          _error = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  void _focusLater(FocusNode node) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) node.requestFocus();
      });

  Future<void> _submit() async {
    if (_busy || _lockSeconds > 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .login(
            server: _server.text,
            handle: _handle.text,
            password: _password.text,
            code: _needsCode ? _code.text : null,
          );
      TextInput.finishAutofillContext();
      if (mounted) setState(() => _busy = false);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (e.code) {
          case 'two_factor_required':
            _needsCode = true;
            _focusLater(_codeFocus);
          case 'two_factor_invalid':
            _error = e.message;
            _code.clear();
            _focusLater(_codeFocus);
          case 'unauthorized':
            _error = e.message;
            _focusLater(_passwordFocus);
          default:
            _error = e.message;
            if (e.retryAfter case final d?) _lock(d);
        }
      });
    }
  }

  void _back() => setState(() {
    _needsCode = false;
    _error = null;
    _code.clear();
    _focusLater(_passwordFocus);
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;
    final size = ButtonSize.large;
    final locked = _lockSeconds;

    final String label;
    if (locked > 0) {
      label = '$locked 秒后可重试';
    } else if (_busy) {
      label = _needsCode ? '正在验证…' : '正在登录…';
    } else {
      label = _needsCode ? '验证' : '登录';
    }

    final fields = _needsCode
        ? <Widget>[
            Text(
              '${_handle.text.trim()} 开启了二次验证。打开验证器 App，输入其中的 6 位验证码。',
              style: (mobile ? t.mobileBody : t.body).copyWith(color: c.label),
            ),
            const SizedBox(height: AppSpacing.x4),
            AuthField(
              label: '验证码',
              child: AppTextField(
                hint: '6 位数字',
                semanticLabel: '二次验证码',
                controller: _code,
                focusNode: _codeFocus,
                mobile: mobile,
                monospace: true,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                onChanged: (v) {
                  if (v.trim().length == 6) _submit();
                },
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
                onSubmitted: (_) => _handleFocus.requestFocus(),
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            AuthField(
              label: '账号',
              child: AppTextField(
                hint: '@账号或邮箱',
                semanticLabel: '账号',
                controller: _handle,
                focusNode: _handleFocus,
                autofocus: !mobile,
                mobile: mobile,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
            ),
            const SizedBox(height: AppSpacing.x3),
            AuthField(
              label: '密码',
              child: PasswordField(
                hint: '密码',
                controller: _password,
                focusNode: _passwordFocus,
                enabled: !_busy,
                onSubmitted: (_) => _submit(),
              ),
            ),
          ];

    return AuthScaffold(
      title: '登录 UniConsole',
      subtitle: '机器人管理与联控平台',
      footer: Column(
        children: [
          Text(
            '收到邀请链接时，直接打开链接设置密码。\n忘记密码请联系平台管理员。',
            textAlign: TextAlign.center,
            style: (mobile ? t.mobileFootnote : t.footnote).copyWith(
              color: c.secondaryLabel,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          AuthLink(
            label: '没有账号？用邮箱注册',
            onTap: _busy ? null : () => context.go(Routes.register),
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
                key: ValueKey(_needsCode),
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
              onPressed: _busy || locked > 0 ? null : _submit,
            ),
            if (_needsCode) ...[
              const SizedBox(height: AppSpacing.x2),
              SecondaryButton(
                label: '返回',
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
