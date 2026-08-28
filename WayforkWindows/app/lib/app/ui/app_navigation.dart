import 'package:flutter/foundation.dart';

/// The pages of the main window's `NavigationView`
/// (docs/design/prototype/windows.html, boards 3-7).
enum AppPage {
  dashboard('Dashboard'),
  tunnels('Tunnels'),
  rules('Rules'),
  general('General'),
  logs('Logs');

  const AppPage(this.title);

  final String title;
}

/// Which page the window shows and what it should focus when it gets there.
/// The tray, the alerts and the model's `actions` stream all steer through
/// this instead of reaching into the widget tree.
final class AppNavigator extends ChangeNotifier {
  AppPage _page = AppPage.dashboard;
  int _quickAddToken = 0;
  String? _logSource;

  AppPage get page => _page;

  /// Bumped every time the quick-add field is asked for, so a repeated
  /// request re-focuses it instead of being swallowed as "no change".
  int get quickAddToken => _quickAddToken;

  /// Source to preselect on the Logs page, if any.
  String? get logSource => _logSource;

  void go(AppPage page) {
    if (_page == page) return;
    _page = page;
    notifyListeners();
  }

  /// Dashboard with the "Route domain…" field focused (the tray's
  /// "Route a domain…").
  void quickAdd() {
    _page = AppPage.dashboard;
    _quickAddToken++;
    notifyListeners();
  }

  void showLogs({String? source}) {
    _page = AppPage.logs;
    _logSource = source;
    notifyListeners();
  }
}
