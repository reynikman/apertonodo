import 'package:flutter/material.dart';

/// Active tab index and previously visited tabs.
///
/// Lives above Navigator in app, not menu itself: tab buttons are now
/// rendered by app — otherwise mini-player could not sit above them. Menu and
/// buttons share this state and stay in sync.
class Tabs extends ChangeNotifier {
  var _current = 0;

  /// Tab is constructed on first visit: otherwise app would fetch genres
  /// and search history before user tapped anything.
  final opened = {0};

  int get current => _current;

  void open(int tab) {
    if (tab == _current) {
      return;
    }
    _current = tab;
    opened.add(tab);
    notifyListeners();
  }
}

/// Menu: Home, Browse, News, Search, My Music.
///
/// Holds only tab bodies. Bottom buttons rendered by app so mini-player
/// fits between tabs and buttons. Open tab preserves its state —
/// scroll position, query, and search results.
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key, required this.tabs, required this.state});

  /// Tabs: home, browse, news, search, my music. No server — wrapper
  /// without menu, widget is not built.
  final List<Widget> tabs;

  /// Shared state with tab buttons: active tab and previously opened tabs.
  final Tabs state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => IndexedStack(
          index: state.current,
          children: [
            for (var i = 0; i < tabs.length; i++)
              state.opened.contains(i) ? tabs[i] : const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}
