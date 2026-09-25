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
  int _diagnosticsToken = 0;
  String? _logSource;

  /// F20: the Logs page should open on the Connections view.
  bool _openConnections = false;

  AppPage get page => _page;

  /// Bumped every time the quick-add field is asked for, so a repeated
  /// request re-focuses it instead of being swallowed as "no change".
  int get quickAddToken => _quickAddToken;

  /// Bumped when General should open its Export Diagnostics sheet — the
  /// alert button and the ✎ of a card that failed on a bad configuration.
  int get diagnosticsToken => _diagnosticsToken;

  /// Source to preselect on the Logs page, if any.
  String? get logSource => _logSource;

  /// Reads the preselected source and forgets it, so the next visit to Logs
  /// keeps whatever filter the user picked there. Deliberately silent: the
  /// page calls it while it builds.
  String? takeLogSource() {
    final source = _logSource;
    _logSource = null;
    return source;
  }

  /// Reads whether Logs should open on Connections and forgets it, so the
  /// next visit keeps whatever view the user picked there.
  bool takeOpenConnections() {
    final open = _openConnections;
    _openConnections = false;
    return open;
  }

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

  /// General with the Export Diagnostics sheet open.
  void exportDiagnostics() {
    _page = AppPage.general;
    _diagnosticsToken++;
    notifyListeners();
  }

  void showLogs({String? source}) {
    _page = AppPage.logs;
    _logSource = source;
    notifyListeners();
  }

  /// Logs on the Connections view (F20): the tray's "Connections" entry.
  void showConnections() {
    _page = AppPage.logs;
    _openConnections = true;
    notifyListeners();
  }
}
