import 'package:fluent_ui/fluent_ui.dart';

/// Wayfork for Windows. WM0 scaffolding: a Fluent shell with the navigation of the
/// approved prototype (docs/design/prototype/windows.html); the pages arrive in WM3.
void main() {
  runApp(const WayforkApp());
}

class WayforkApp extends StatelessWidget {
  const WayforkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const FluentApp(
      title: 'Wayfork',
      debugShowCheckedModeBanner: false,
      home: MainWindow(),
    );
  }
}

class MainWindow extends StatefulWidget {
  const MainWindow({super.key});

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> {
  static const _pages = <({String title, IconData icon})>[
    (title: 'Dashboard', icon: FluentIcons.home),
    (title: 'Tunnels', icon: FluentIcons.plug_connected),
    (title: 'Rules', icon: FluentIcons.filter),
    (title: 'General', icon: FluentIcons.settings),
    (title: 'Logs', icon: FluentIcons.text_document),
  ];

  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    return NavigationView(
      pane: NavigationPane(
        selected: _selected,
        onChanged: (index) => setState(() => _selected = index),
        displayMode: PaneDisplayMode.expanded,
        items: [
          for (final page in _pages)
            PaneItem(
              icon: Icon(page.icon),
              title: Text(page.title),
              body: Center(child: Text('${page.title} — coming in WM3')),
            ),
        ],
      ),
    );
  }
}
