import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/ui/alert_host.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/service_banner.dart';

/// The main window of docs/design/prototype/windows.html: a left
/// `NavigationView` over the five pages, the service banner above whatever
/// page is open and the alert queue on top of everything.
///
/// The pages themselves arrive with WM3d (Dashboard, Tunnels) and WM3e (Rules,
/// General, Logs); the shell, the navigation and the two cross-page surfaces
/// are WM3c.
class AppShell extends StatelessWidget {
  const AppShell({required this.onAction, super.key});

  final void Function(AppAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final navigator = NavigationScope.of(context);
    return AlertHost(
      onAction: onAction,
      child: NavigationView(
        pane: NavigationPane(
          selected: navigator.page.index,
          onChanged: (index) => navigator.go(AppPage.values[index]),
          displayMode: PaneDisplayMode.expanded,
          items: [
            for (final page in AppPage.values)
              PaneItem(
                key: ValueKey(page),
                icon: Icon(_icons[page]),
                title: Text(page.title),
                body: _PageBody(page: page, onAction: onAction),
              ),
          ],
        ),
      ),
    );
  }

  static const _icons = <AppPage, IconData>{
    AppPage.dashboard: FluentIcons.home,
    AppPage.tunnels: FluentIcons.plug_connected,
    AppPage.rules: FluentIcons.filter,
    AppPage.general: FluentIcons.settings,
    AppPage.logs: FluentIcons.text_document,
  };
}

class _PageBody extends StatelessWidget {
  const _PageBody({required this.page, required this.onAction});

  final AppPage page;
  final void Function(AppAction action) onAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServiceBanner(
          onRepair: () => onAction(const AppAction.repairInstallation()),
        ),
        Expanded(
          child: Center(
            child: Text(
              '${page.title} — coming in WM3d/WM3e',
              style: FluentTheme.of(context).typography.body,
            ),
          ),
        ),
      ],
    );
  }
}
