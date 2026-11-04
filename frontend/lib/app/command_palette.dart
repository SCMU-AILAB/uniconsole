import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/theme.dart';
import '../core/widgets/widgets.dart';
import '../data/providers.dart';
import 'destinations.dart';
import 'shell.dart';

/// 命令面板（⌘K，Settings.dc.html 快捷键）：搜索页面与设备，回车打开第一项，
/// ↑ ↓ 选择，Esc 关闭。
Future<void> showCommandPalette(BuildContext context) => showAppDialog<void>(
  context: context,
  builder: (context) => const _CommandPalette(),
);

class _Item {
  const _Item(this.title, this.detail, this.icon, this.location);

  final String title;
  final String detail;
  final AppIcons icon;
  final String location;
}

class _CommandPalette extends ConsumerStatefulWidget {
  const _CommandPalette();

  @override
  ConsumerState<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends ConsumerState<_CommandPalette> {
  final _query = TextEditingController();
  var _index = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<_Item> _items() {
    final q = _query.text.trim().toLowerCase();
    final devices = ref.watch(devicesProvider).value ?? const [];
    final pages = [
      for (final e in [...workbench, ...operations, ...management])
        if (locationFor(e.id, ref) case final loc?)
          _Item(e.label, '页面', e.icon, loc),
    ];
    final items = [
      ...pages,
      for (final d in devices)
        _Item(
          d.name,
          '${d.code} · ${d.status.label} · ${d.location}',
          d.kind.name == 'humanoid' ? AppIcons.humanoid : AppIcons.dog,
          Routes.device(d.id),
        ),
    ];
    if (q.isEmpty) return items.take(9).toList();
    return [
      for (final i in items)
        if (i.title.toLowerCase().contains(q) ||
            i.detail.toLowerCase().contains(q))
          i,
    ];
  }

  void _open(_Item item) {
    Navigator.of(context).pop();
    GoRouter.of(context).go(item.location);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final items = _items();
    final index = items.isEmpty ? 0 : _index.clamp(0, items.length - 1);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(
          () => _index = (index + 1) % (items.isEmpty ? 1 : items.length),
        ),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(
          () => _index = (index - 1) < 0 ? items.length - 1 : index - 1,
        ),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Align(
        alignment: const Alignment(0, -0.5),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              label: '命令面板',
              explicitChildNodes: true,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
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
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.x4,
                          vertical: AppSpacing.x3,
                        ),
                        child: Row(
                          children: [
                            AppIcon(
                              AppIcons.search,
                              size: 16,
                              color: c.secondaryLabel,
                            ),
                            const SizedBox(width: AppSpacing.x3),
                            Expanded(
                              child: TextField(
                                controller: _query,
                                autofocus: true,
                                onChanged: (_) => setState(() => _index = 0),
                                onSubmitted: (_) {
                                  if (items.isNotEmpty) _open(items[index]);
                                },
                                style: t.headline.copyWith(
                                  color: c.label,
                                  fontWeight: FontWeight.w400,
                                ),
                                cursorColor: c.accent,
                                decoration: InputDecoration.collapsed(
                                  hintText: '搜索页面或设备',
                                  hintStyle: t.headline.copyWith(
                                    color: c.secondaryLabel,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(height: 1, color: c.separator),
                      Flexible(
                        child: items.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(AppSpacing.x6),
                                child: Text(
                                  '没有匹配的页面或设备',
                                  textAlign: TextAlign.center,
                                  style: t.body.copyWith(
                                    color: c.secondaryLabel,
                                  ),
                                ),
                              )
                            : ListView(
                                shrinkWrap: true,
                                padding: const EdgeInsets.all(AppSpacing.x2),
                                children: [
                                  for (final (i, item) in items.indexed)
                                    Pressable(
                                      onTap: () => _open(item),
                                      selected: i == index,
                                      semanticLabel:
                                          '${item.title}，${item.detail}',
                                      focusRadius: AppRadius.md,
                                      builder: (context, st) => Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: AppSpacing.x3,
                                          vertical: AppSpacing.x2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: i == index
                                              ? c.accentFill
                                              : st.pressed
                                              ? c.fillSecondary
                                              : null,
                                          borderRadius: BorderRadius.circular(
                                            AppRadius.md,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            AppIcon(
                                              item.icon,
                                              color: i == index
                                                  ? c.onAccent
                                                  : c.secondaryLabel,
                                            ),
                                            const SizedBox(
                                              width: AppSpacing.x3,
                                            ),
                                            Expanded(
                                              child: Text(
                                                item.title,
                                                style: t.body.copyWith(
                                                  color: i == index
                                                      ? c.onAccent
                                                      : c.label,
                                                ),
                                              ),
                                            ),
                                            Flexible(
                                              child: Text(
                                                item.detail,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.end,
                                                style: t.footnote.copyWith(
                                                  color: i == index
                                                      ? c.onAccent
                                                      : c.secondaryLabel,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
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
        ),
      ),
    );
  }
}
