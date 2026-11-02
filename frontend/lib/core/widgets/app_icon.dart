import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/theme.dart';

/// 图标集：路径逐字取自 design/*.dc.html（24×24 视图框，圆角描边）。
/// check / close / info / sun / moon 设计稿中没有，按同一风格补充；settings 按 §12 重画。
enum AppIcons {
  devices(
    '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  ),
  control(
    '<path d="M7 6h10a5 5 0 0 1 4.9 6l-.9 4.4a2.8 2.8 0 0 1-5 1.1L14.5 16h-5L8 17.5a2.8 2.8 0 0 1-5-1.1L2.1 12A5 5 0 0 1 7 6z"/><path d="M7 10v3M5.5 11.5h3"/><circle cx="16" cy="10.5" r=".8"/><circle cx="17.8" cy="12.6" r=".8"/>',
  ),
  fleet(
    '<circle cx="12" cy="5" r="2.5"/><circle cx="5" cy="18" r="2.5"/><circle cx="19" cy="18" r="2.5"/><path d="M10.8 7.2 6.2 15.8M13.2 7.2l4.6 8.6M7.5 18h9"/>',
  ),
  sensors(
    '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/><path d="M12 12l6-6"/>',
  ),
  missions('<path d="M9 4 3 6v14l6-2 6 2 6-2V4l-6 2-6-2zM9 4v14M15 6v14"/>'),
  alerts(
    '<path d="M6 9a6 6 0 0 1 12 0c0 6 2.5 7.5 2.5 7.5h-17S6 15 6 9"/><path d="M10 20a2 2 0 0 0 4 0"/>',
  ),
  replay('<circle cx="12" cy="12" r="9"/><path d="M10 8.5v7l5.5-3.5z"/>'),
  maintenance(
    '<path d="M14.7 6.3a4 4 0 0 0 5 5l-8.4 8.4a2 2 0 0 1-2.8-2.8l8.4-8.4"/><path d="M14.7 6.3 17 4l3 3-2.3 2.3"/>',
  ),
  safety(
    '<path d="M12 3 4.5 6v6c0 4.6 3.2 7.8 7.5 9 4.3-1.2 7.5-4.4 7.5-9V6z"/>',
  ),
  lease(
    '<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M17 6l3 3M14.5 8.5l2 2"/>',
  ),
  members(
    '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0"/><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6 6 0 0 1 3.5 6"/>',
  ),
  agent('<path d="M4 5h16v11H9l-5 4z"/><path d="M9 10.5h6"/>'),
  /// 8 齿齿轮轮廓（HANDOFF.md §12：设计稿原图是放射线，和太阳分不清，已重画）。
  settings(
    '<path d="M10.43 5.18L10.50 2.52A9.6 9.6 0 0 1 13.50 2.52L13.57 5.18A7.0 7.0 0 0 1 15.71 6.06L17.64 4.23A9.6 9.6 0 0 1 19.77 6.36L17.94 8.29A7.0 7.0 0 0 1 18.82 10.43L21.48 10.50A9.6 9.6 0 0 1 21.48 13.50L18.82 13.57A7.0 7.0 0 0 1 17.94 15.71L19.77 17.64A9.6 9.6 0 0 1 17.64 19.77L15.71 17.94A7.0 7.0 0 0 1 13.57 18.82L13.50 21.48A9.6 9.6 0 0 1 10.50 21.48L10.43 18.82A7.0 7.0 0 0 1 8.29 17.94L6.36 19.77A9.6 9.6 0 0 1 4.23 17.64L6.06 15.71A7.0 7.0 0 0 1 5.18 13.57L2.52 13.50A9.6 9.6 0 0 1 2.52 10.50L5.18 10.43A7.0 7.0 0 0 1 6.06 8.29L4.23 6.36A9.6 9.6 0 0 1 6.36 4.23L8.29 6.06A7.0 7.0 0 0 1 10.43 5.18Z"/><circle cx="12" cy="12" r="3"/>',
  ),
  person('<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>'),
  search('<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>'),
  plus('<path d="M12 5v14M5 12h14"/>'),
  chevronDown('<path d="m6 9 6 6 6-6"/>'),
  chevronRight('<path d="m9 6 6 6-6 6"/>'),
  chevronLeft('<path d="m15 5-7 7 7 7"/>'),
  list('<path d="M4 6h16M4 12h16M4 18h16"/>'),
  filter('<path d="M4 7h16M7 12h10M10 17h4"/>'),
  more(
    '<circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/>',
  ),
  location(
    '<path d="M12 21s7-6 7-12a7 7 0 0 0-14 0c0 6 7 12 7 12z"/><circle cx="12" cy="9" r="2.5"/>',
  ),
  lock(
    '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  ),
  dog(
    '<rect x="3.5" y="9" width="12.5" height="5" rx="2"/><path d="M16 10.5 18.5 7H21v3l-2.5 2"/><path d="M5.5 14l-1 5M8.5 14l.5 5M12.5 14l-.5 5M15 14l1 5"/>',
  ),
  humanoid(
    '<circle cx="12" cy="4.5" r="2"/><path d="M8.5 8.5h7l-1 6.5h-5z"/><path d="M9.5 15l-1 6M14.5 15l1 6M8.5 9l-2.5 5M15.5 9l2.5 5"/>',
  ),
  stop('<path d="M8 3h8l5 5v8l-5 5H8l-5-5V8z"/><path d="M9 9l6 6M15 9l-6 6"/>'),
  stopAlert(
    '<path d="M8 3h8l5 5v8l-5 5H8l-5-5V8z"/><path d="M12 8v5M12 16h.01"/>',
  ),
  warning('<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17h.01"/>'),
  mic(
    '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  ),
  arrowUp('<path d="M12 19V5M5 12l7-7 7 7"/>'),
  fullscreen('<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>'),
  check('<path d="m5 12.5 4.5 4.5L19 7.5"/>'),
  close('<path d="M6 6l12 12M18 6 6 18"/>'),
  info('<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>'),
  play('<path d="M7 4.5v15l12-7.5z"/>', filled: true),
  pause(
    '<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>',
    filled: true,
  ),
  bolt('<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>', filled: true),
  sun(
    '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
  ),
  moon('<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>');

  const AppIcons(this.markup, {this.filled = false});

  final String markup;

  /// 填充图标（播放、暂停、闪电），其余为描边图标。
  final bool filled;
}

/// 1.8px 描边 SVG 图标。纯装饰，不进入语义树；需要语义时由外层按钮提供。
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size = AppSizes.icon,
    this.color,
    this.strokeWidth = AppSizes.iconStroke,
  });

  final AppIcons icon;
  final double size;
  final Color? color;
  final double strokeWidth;

  static final _cache = <(AppIcons, double), String>{};

  String _svg() => _cache.putIfAbsent((icon, strokeWidth), () {
    final paint = icon.filled
        ? 'fill="#000"'
        : 'fill="none" stroke="#000" stroke-width="$strokeWidth" '
              'stroke-linecap="round" stroke-linejoin="round"';
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        '$paint>${icon.markup}</svg>';
  });

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SvgPicture.string(
        _svg(),
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(
          color ?? context.colors.secondaryLabel,
          BlendMode.srcIn,
        ),
      ),
    );
  }
}
