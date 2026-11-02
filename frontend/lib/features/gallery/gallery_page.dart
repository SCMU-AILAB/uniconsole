import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import 'gallery_sections.dart';

/// 组件预览（第 1 阶段产物，debug 版本在侧边栏「开发」里可见）。
///
/// 急停按钮演示 §8.1：触发后出现红色提示条、运动按钮和摇杆禁用，空格键也可切换。
class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  bool _estop = false;

  void _toggleStop() => setState(() => _estop = !_estop);

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.space): _toggleStop},
      child: Focus(
        autofocus: true,
        child: AppPage(
          title: '组件预览',
          mobileTitle: '组件',
          subtitle: '第 1 阶段 · 设计规范与通用组件',
          actions: [
            EmergencyStopButton(engaged: _estop, onPressed: _toggleStop),
          ],
          mobileActions: [
            EmergencyStopButton(
              engaged: _estop,
              compact: true,
              onPressed: _toggleStop,
            ),
          ],
          gap: 36,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Presence(
                  child: _estop
                      ? const Padding(
                          padding: EdgeInsets.only(bottom: AppSpacing.x9),
                          child: AppBanner(
                            kind: BannerKind.emergency,
                            message: '已触发急停 · 所有运动按钮已禁用（再次点击急停或按空格解除）',
                          ),
                        )
                      : null,
                ),
                const ColorsSection(),
              ],
            ),
            const TypographySection(),
            const MetricsSection(),
            ButtonsSection(estop: _estop, onToggleStop: _toggleStop),
            const InputsSection(),
            const StatusSection(),
            const CardsSection(),
            const ListsSection(),
            FeedbackSection(estop: _estop),
            const TableSection(),
            const ChartsSection(),
            const TimelineSection(),
            ControlSection(estop: _estop),
            const PointCloudSection(),
            const MapSection(),
            const LogsSection(),
            const NavigationSection(),
          ],
        ),
      ),
    );
  }
}
