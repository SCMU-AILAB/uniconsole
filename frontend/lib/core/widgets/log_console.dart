import 'package:flutter/material.dart';

import '../theme/theme.dart';

enum LogLevel { normal, info, success, warning, error }

class LogLine {
  const LogLine(
    this.message, {
    this.time,
    this.level = LogLevel.normal,
    this.prompt,
    this.source,
  });

  /// 终端命令行：`prompt` 形如 `unitree@go2-01:~`，[message] 为命令。
  const LogLine.command(this.prompt, this.message)
    : time = null,
      level = LogLevel.normal,
      source = null;

  final String message;
  final String? time;
  final LogLevel level;
  final String? prompt;

  /// 来源设备（多设备日志）。
  final String? source;
}

/// 等宽日志 / 指令记录（Control.dc.html「指令日志」），
/// [terminal] 为深色远程终端样式（Maintenance.dc.html）。
class LogConsole extends StatelessWidget {
  const LogConsole({
    super.key,
    required this.lines,
    this.terminal = false,
    this.showCursor = false,
    this.maxHeight,
    this.tabs = const [],
    this.selectedTab = 0,
    this.headerNote,
    this.semanticLabel = '日志',
  });

  final List<LogLine> lines;
  final bool terminal;

  /// 终端末尾显示光标行（使用最后一个命令行的提示符）。
  final bool showCursor;
  final double? maxHeight;

  /// 终端顶部会话标签。
  final List<String> tabs;
  final int selectedTab;
  final String? headerNote;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final tc = c.terminal;
    final t = context.type;
    final base = terminal ? t.monoLarge.copyWith(height: 1.5) : t.mono;

    Color levelColor(LogLevel l) => switch (l) {
      LogLevel.normal => terminal ? tc.text : c.tertiaryLabel,
      LogLevel.info => terminal ? tc.path : s.busy.fg,
      LogLevel.success => terminal ? tc.prompt : s.online.fg,
      LogLevel.warning => terminal ? tc.warning : s.warning.fg,
      LogLevel.error => terminal ? tc.error : s.critical.fg,
    };

    TextSpan promptSpan(String p) {
      final i = p.indexOf(':');
      final host = i < 0 ? p : p.substring(0, i);
      final path = i < 0 ? '' : p.substring(i + 1);
      return TextSpan(
        children: [
          TextSpan(
            text: host,
            style: TextStyle(color: tc.prompt),
          ),
          TextSpan(
            text: ':',
            style: TextStyle(color: tc.cursor),
          ),
          TextSpan(
            text: path,
            style: TextStyle(color: tc.path),
          ),
          TextSpan(
            text: r'$ ',
            style: TextStyle(color: tc.cursor),
          ),
        ],
      );
    }

    final rows = <Widget>[
      for (final l in lines)
        if (terminal)
          Text.rich(
            TextSpan(
              children: [
                if (l.prompt != null) promptSpan(l.prompt!),
                TextSpan(
                  text: l.message,
                  style: TextStyle(
                    color: l.prompt != null ? tc.cursor : levelColor(l.level),
                  ),
                ),
              ],
            ),
            style: base,
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (l.time != null) ...[
                Text(l.time!, style: base.copyWith(color: c.secondaryLabel)),
                const SizedBox(width: AppSpacing.x2),
              ],
              if (l.source != null) ...[
                Text(
                  l.source!,
                  style: base.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
              ],
              Expanded(
                child: Text(
                  l.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(color: levelColor(l.level)),
                ),
              ),
            ],
          ),
      if (terminal && showCursor)
        Text.rich(
          TextSpan(
            children: [
              promptSpan(
                lines
                    .lastWhere(
                      (l) => l.prompt != null,
                      orElse: () => const LogLine.command('~', ''),
                    )
                    .prompt!,
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(width: 8, height: 14, color: tc.cursor),
              ),
            ],
          ),
          style: base,
        ),
    ];

    Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.x1),
          rows[i],
        ],
      ],
    );
    if (maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight!),
        child: SingleChildScrollView(reverse: true, child: body),
      );
    }
    body = Semantics(
      label: semanticLabel,
      container: true,
      child: SelectionArea(child: body),
    );
    if (!terminal) return body;

    return Container(
      // 深色模式下终端底色与窗口相同，加描边区分。
      foregroundDecoration: c.isDark
          ? BoxDecoration(
              border: Border.all(color: c.separator),
              borderRadius: BorderRadius.circular(AppRadius.card),
            )
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: ColoredBox(
          color: tc.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tabs.isNotEmpty || headerNote != null)
                Container(
                  color: tc.header,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x3,
                    vertical: AppSpacing.x2,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var i = 0; i < tabs.length; i++) ...[
                                if (i > 0) const SizedBox(width: AppSpacing.x2),
                                Container(
                                  height: 26,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.x3,
                                  ),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: i == selectedTab
                                        ? tc.tabSelected
                                        : null,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.xs,
                                    ),
                                  ),
                                  child: Text(
                                    tabs[i],
                                    style: t.subhead.copyWith(
                                      color: i == selectedTab
                                          ? tc.cursor
                                          : tc.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (headerNote != null) ...[
                        const SizedBox(width: AppSpacing.x2),
                        Text(
                          headerNote!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.caption.copyWith(color: tc.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x4,
                  vertical: AppSpacing.x3,
                ),
                child: body,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
