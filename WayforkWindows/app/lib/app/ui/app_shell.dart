import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/services/running_apps.dart';
import 'package:wayfork/app/ui/alert_host.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/pages/dashboard_page.dart';
import 'package:wayfork/app/ui/pages/general_page.dart';
import 'package:wayfork/app/ui/pages/logs_page.dart';
import 'package:wayfork/app/ui/pages/rules_page.dart';
import 'package:wayfork/app/ui/pages/tunnels_page.dart';
import 'package:wayfork/app/ui/service_banner.dart';
import 'package:wayfork/app/ui/tunnel_import.dart';
import 'package:wayfork/app/ui/widgets/components.dart';

/// The main window of docs/design/prototype/windows.html: a left
/// `NavigationView` over the five pages, the service banner above whatever
/// page is open and the alert queue on top of everything. A `.ovpn` dropped
/// anywhere in the window is imported (board 4).
class AppShell extends StatelessWidget {
  const AppShell({
    required this.onAction,
    required this.picker,
    required this.runningApps,
    super.key,
  });

  final void Function(AppAction action) onAction;

  /// The common dialogs of the `.ovpn` import.
  final FilePicker picker;

  /// What the Rules page's "Application…" picker lists (F10).
  final RunningAppSource runningApps;

  @override
  Widget build(BuildContext context) {
    final navigator = NavigationScope.of(context);
    final importer = TunnelImporter(
      model: AppScope.of(context),
      picker: picker,
      confirmFolder: (missing) => showQuestionDialog(
        context,
        title: 'Referenced files not found',
        message:
            '${missing.join(', ')} referenced but not found next to the '
            '.ovpn. Choose the folder that contains them.',
        confirm: 'Choose Folder…',
      ),
    );
    return DropTarget(
      onDragDone: (details) {
        navigator.go(AppPage.tunnels);
        unawaited(
          importer.importDropped(details.files.map((file) => file.path)),
        );
      },
      child: AlertHost(
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
                  body: _PageBody(
                    page: page,
                    onAction: onAction,
                    importer: importer,
                    picker: picker,
                    runningApps: runningApps,
                  ),
                ),
            ],
          ),
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
  const _PageBody({
    required this.page,
    required this.onAction,
    required this.importer,
    required this.picker,
    required this.runningApps,
  });

  final AppPage page;
  final void Function(AppAction action) onAction;
  final TunnelImporter importer;
  final FilePicker picker;
  final RunningAppSource runningApps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ServiceBanner(
          onRepair: () => onAction(const AppAction.repairInstallation()),
        ),
        Expanded(
          child: switch (page) {
            AppPage.dashboard => const DashboardPage(),
            AppPage.tunnels => TunnelsPage(importer: importer),
            AppPage.rules => RulesPage(
              picker: picker,
              runningApps: runningApps,
              onAction: onAction,
            ),
            AppPage.general => GeneralPage(picker: picker),
            AppPage.logs => const LogsPage(),
          },
        ),
      ],
    );
  }
}
