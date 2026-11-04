import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/platform/window_chrome.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// 新告警推送横幅（MobileAlerts.dc.html 顶部通知）。
///
/// 告警流里出现新的未处理告警时弹出：点按打开详情，按住快速确认或远程趴下，
/// 上滑或 6 秒后收起。按「设置 › 通知」的方式过滤（关闭的级别不弹），静默中的不弹。
/// 系统级推送（APNs / FCM）需要服务端支持，这里是应用在前台时的横幅。
class AlertPushOverlay extends ConsumerStatefulWidget {
  const AlertPushOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AlertPushOverlay> createState() => _AlertPushOverlayState();
}

class _AlertPushOverlayState extends ConsumerState<AlertPushOverlay> {
  Set<String>? _seen;
  Alert? _shown;
  Timer? _hide;

  static const showFor = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    ref.listenManual(alertsProvider, (_, next) {
      if (next.value case final alerts?) _onAlerts(alerts);
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  bool _wanted(Alert a) {
    if (a.state != AlertState.open) return false;
    if (a.silencedAt(DateTime.now())) return false;
    final p = ref.read(preferencesProvider);
    return switch (a.severity) {
      AlertSeverity.critical => p.notifyCritical != NotifyStyle.off,
      AlertSeverity.warning => p.notifyWarning != NotifyStyle.off,
      AlertSeverity.info => false,
    };
  }

  void _onAlerts(List<Alert> alerts) {
    final ids = {for (final a in alerts) a.id};
    final seen = _seen;
    _seen = ids;
    // 第一次拿到的列表是已有告警，不弹。
    if (seen == null) return;
    final fresh = alerts.where((a) => !seen.contains(a.id) && _wanted(a));
    if (fresh.isEmpty) return;
    setState(() => _shown = fresh.first);
    _hide?.cancel();
    _hide = Timer(showFor, _dismiss);
  }

  void _dismiss() {
    _hide?.cancel();
    if (mounted) setState(() => _shown = null);
  }

  void _open(Alert a) {
    _dismiss();
    final router = GoRouter.of(context);
    final mobile = LayoutSize.ofContext(context).isMobile;
    if (mobile) {
      router.push(Routes.alert(a.id), extra: NavIntent.push);
    } else {
      router.go(Routes.alert(a.id));
    }
  }

  Future<void> _quickActions(Alert a) async {
    _hide?.cancel();
    final v = await showAppDialog<int?>(
      context: context,
      builder: (context) => AppAlert<int?>(
        title: '${alertDeviceName(ref, a)} ${a.title}',
        message: a.events.firstOrNull?.message,
        actions: const [
          AlertAction(label: '取消', value: null, kind: AlertActionKind.cancel),
          AlertAction(
            label: '远程趴下',
            value: 1,
            kind: AlertActionKind.destructive,
          ),
          AlertAction(label: '确认处理', value: 0),
        ],
      ),
    );
    _dismiss();
    if (v == null || !mounted) return;
    final repo = ref.read(alertRepositoryProvider);
    if (v == 0) {
      await repo.acknowledge(a.id);
    } else {
      await repo.remoteDown(a.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile = LayoutSize.ofContext(context).isMobile;
    final top = MediaQuery.paddingOf(context).top;
    final a = _shown;

    final banner = a == null
        ? null
        : _Banner(
            key: ValueKey(a.id),
            alert: a,
            mobile: mobile,
            onTap: () => _open(a),
            onLongPress: () => _quickActions(a),
            onDismiss: _dismiss,
          );

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: (mobile ? top : WindowChrome.titlebarHeight) + AppSpacing.x2,
          left: mobile ? AppSpacing.x2 : null,
          right: AppSpacing.x2 + (mobile ? 0 : AppSpacing.x2),
          width: mobile ? null : 380,
          child: AnimatedSwitcher(
            duration: AppMotion.appearance,
            switchInCurve: AppMotion.smooth,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, -0.4),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: banner == null
                ? const SizedBox.shrink()
                : Material(
                    key: banner.key,
                    type: MaterialType.transparency,
                    child: banner,
                  ),
          ),
        ),
      ],
    );
  }
}

String alertDeviceName(WidgetRef ref, Alert a) =>
    ref.read(deviceProvider(a.deviceId))?.name ?? a.deviceId;

class _Banner extends ConsumerWidget {
  const _Banner({
    super.key,
    required this.alert,
    required this.mobile,
    required this.onTap,
    required this.onLongPress,
    required this.onDismiss,
  });

  final Alert alert;
  final bool mobile;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final name =
        ref.watch(deviceProvider(alert.deviceId))?.name ?? alert.deviceId;
    final auto = alert.events
        .where((e) => e.message.startsWith('自动执行'))
        .isNotEmpty;
    final body = [
      ?alert.events.firstOrNull?.message,
      if (auto) '已自动降速',
    ].join('，');
    final hint = mobile ? '按住可快速确认或远程趴下。' : '右键或按住可快速确认或远程趴下。';
    final title = '$name ${alert.title}';

    return Semantics(
      container: true,
      liveRegion: true,
      label: '新告警：${alert.severity.label}，$title',
      child: GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < 0) onDismiss();
        },
        onSecondaryTap: onLongPress,
        child: Pressable(
          onTap: onTap,
          semanticLabel: '打开告警：$title',
          focusRadius: 22,
          builder: (context, st) => GestureDetector(
            onLongPress: onLongPress,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4 - AppSpacing.half,
                vertical: AppSpacing.x3,
              ),
              decoration: BoxDecoration(
                color: c.windowBackground.withValues(alpha: 0.97),
                borderRadius: BorderRadius.circular(22),
                border: c.isDark ? Border.all(color: c.separator) : null,
                boxShadow: [
                  BoxShadow(
                    color: c.shadow.withValues(alpha: 0.18),
                    blurRadius: 28,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.logo,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                    ),
                    child: AppIcon(AppIcons.sensors, size: 22, color: c.onLogo),
                  ),
                  const SizedBox(width: AppSpacing.x2 + AppSpacing.half),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'UNICONSOLE · ${alert.severity.label}告警',
                                style: t.mobileFootnote.copyWith(
                                  color: c.secondaryLabel,
                                ),
                              ),
                            ),
                            Text(
                              '现在',
                              style: t.mobileFootnote.copyWith(
                                color: c.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.half),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.headline.copyWith(color: c.label),
                        ),
                        const SizedBox(height: AppSpacing.half),
                        Text(
                          '$body。$hint',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.mobileFootnote.copyWith(
                            color: c.tertiaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
