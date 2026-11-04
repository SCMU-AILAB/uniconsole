import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';

/// 退出登录（`POST /auth/logout`）：确认后吊销当前会话，路由守卫回到登录页。
Future<void> confirmSignOut(BuildContext context, WidgetRef ref) async {
  final me = ref.read(currentUserProvider).value;
  final release =
      ref.read(safetyProvider).value?.policies.disconnectRelease.inSeconds ??
      60;
  final ok = await confirmAction(
    context,
    title: '退出登录？',
    message:
        '${me == null ? '' : '${me.name}（${me.handle}）'}退出后需要重新输入账号和密码。'
        '持有的控制权会在断开 $release 秒后自动释放。',
    confirmLabel: '退出登录',
    destructive: true,
  );
  if (ok) await ref.read(authRepositoryProvider).logout();
}
