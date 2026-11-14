import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';

/// Floating tab island. Unlabeled names are announced by TalkBack.
class ApertonoNavBar extends StatelessWidget {
  const ApertonoNavBar({
    super.key,
    required this.current,
    required this.onOpen,
    this.showNews = true,
  });

  final int current;
  final ValueChanged<int> onOpen;

  /// When false — no news button, others share width; tab numbers remain unchanged.
  final bool showNews;

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final tabs = [
      (
        name: 'home',
        label: text.navHome,
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
      ),
      (
        name: 'browse',
        label: text.navBrowse,
        icon: Icons.grid_view_outlined,
        selectedIcon: Icons.grid_view,
      ),
      (
        name: 'news',
        label: text.navNews,
        icon: Icons.article_outlined,
        selectedIcon: Icons.article,
      ),
      (
        name: 'search',
        label: text.navSearch,
        icon: Icons.search,
        selectedIcon: Icons.search,
      ),
      (
        name: 'library',
        label: text.navLibrary,
        icon: Icons.library_music_outlined,
        selectedIcon: Icons.library_music,
      ),
    ];
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: RepaintBoundary(
          child: Container(
            key: const Key('nav-bar'),
            height: 66,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              gradient: ApertonoColors.navGradient,
              border: Border.all(color: ApertonoColors.border),
              borderRadius: BorderRadius.circular(ApertonoRadii.xLarge),
              boxShadow: const [
                BoxShadow(
                  color: ApertonoColors.shadow,
                  offset: Offset(0, 8),
                  blurRadius: 30,
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, tab) in tabs.indexed)
                  if (showNews || tab.name != 'news')
                    Expanded(
                      child: Semantics(
                        label: tab.label,
                        button: true,
                        selected: current == index,
                        child: GestureDetector(
                          key: Key('tab-${tab.name}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onOpen(index),
                          child: Center(
                            child: OverflowBox(
                              maxWidth: 68,
                              maxHeight: 44,
                              child: Container(
                                key: current == index
                                    ? const Key('tab-capsule')
                                    : null,
                                width: 68,
                                height: 44,
                                decoration: current == index
                                    ? BoxDecoration(
                                        color: ApertonoColors.navItemActive,
                                        borderRadius: BorderRadius.circular(
                                          ApertonoRadii.capsule,
                                        ),
                                      )
                                    : null,
                                child: Icon(
                                  current == index
                                      ? tab.selectedIcon
                                      : tab.icon,
                                  color: current == index
                                      ? ApertonoColors.accent
                                      : ApertonoColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
