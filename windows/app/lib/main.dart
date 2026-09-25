import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/services/running_apps.dart';
import 'package:wayfork/app/services/launch_at_login_registry.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/app/services/network_watcher.dart';
import 'package:wayfork/app/services/notifier.dart';
import 'package:wayfork/app/services/single_instance.dart';
import 'package:wayfork/app/services/toast_notifier.dart';
import 'package:wayfork/app/services/tray_backend.dart';
import 'package:wayfork/app/services/tray_controller.dart';
import 'package:wayfork/app/services/window_backend.dart';
import 'package:wayfork/app/services/window_controller.dart';
import 'package:wayfork/app/ui/app_actions.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/app_shell.dart';
import 'package:wayfork/core/ipc/named_pipe_transport.dart';
import 'package:wayfork/core/ipc/service_client.dart';
import 'package:wayfork/core/model/settings.dart';
import 'package:wayfork/core/secrets/dpapi_secret_store.dart';
import 'package:wayfork/core/secrets/dpapi_win32.dart';
import 'package:wayfork/core/store/store_repository.dart';
import 'package:window_manager/window_manager.dart';

/// `%LOCALAPPDATA%\Wayfork\secrets.dat` (docs/design/08-windows.md,
/// "Filesystem layout").
const secretsFileName = 'secrets.dat';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();

  // A second launch belongs to the instance that already owns the tray icon
  // and the pipe; hand it the focus and step aside.
  if (!SingleInstance.acquire()) {
    SingleInstance.activateExisting();
    exit(0);
  }

  final startHidden = arguments.contains(RegistryLaunchAtLogin.minimizedFlag);
  await windowManager.ensureInitialized();

  final directory = StoreRepository.defaultDirectory();
  final logs = LogCenter(directory: LogCenter.defaultDirectory());
  final watcher = SystemNetworkWatcher();
  final navigator = AppNavigator();
  final notifier = await ToastNotifier.start();
  final model = AppModel(
    repository: StoreRepository(directory),
    secrets: DpapiSecretStore(
      File('${directory.path}${Platform.pathSeparator}$secretsFileName'),
      DpapiProtector(),
    ),
    client: ServiceClient(connect: NamedPipeTransport.connect),
    logs: logs,
    notifier: notifier,
    launchAtLogin: RegistryLaunchAtLogin(),
    networkChanges: watcher.changes,
  );

  final window = WindowController(WindowManagerBackend());
  final actions = AppActionHandler(
    model: model,
    navigator: navigator,
    window: window,
  );
  late final TrayController tray;
  tray = TrayController(
    model: model,
    backend: TrayManagerBackend(),
    window: window,
    navigator: navigator,
    actions: actions,
    onQuit: () => _quit(
      model: model,
      tray: tray,
      window: window,
      watcher: watcher,
      actions: actions,
      notifier: notifier,
    ),
  );

  await window.start(startHidden: startHidden);
  logs.app(
    LogLevel.info,
    startHidden ? 'launched into the tray' : 'main window shown',
  );
  actions.start();
  await tray.start();
  watcher.start();

  runApp(WayforkApp(model: model, navigator: navigator, actions: actions));

  // The service handshake waits up to ten seconds; the window must not.
  unawaited(model.bootstrap());
}

/// Everything Quit has to unwind, in the order the user notices it: the icon
/// disappears, the tunnels come down, the window goes last.
Future<void> _quit({
  required AppModel model,
  required TrayController tray,
  required WindowController window,
  required SystemNetworkWatcher watcher,
  required AppActionHandler actions,
  required Notifier notifier,
}) async {
  await window.hide();
  await tray.dispose();
  await model.shutdown();
  await watcher.dispose();
  await actions.dispose();
  // Toasts this session posted must not outlive it.
  if (notifier is ToastNotifier) await notifier.dispose();
  SingleInstance.release();
  await window.quit();
}

class WayforkApp extends StatelessWidget {
  const WayforkApp({
    required this.model,
    required this.navigator,
    required this.actions,
    super.key,
  });

  final AppModel model;
  final AppNavigator navigator;
  final AppActionHandler actions;

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'Wayfork',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: FluentThemeData(brightness: Brightness.light),
      darkTheme: FluentThemeData(brightness: Brightness.dark),
      home: AppScope(
        model: model,
        child: NavigationScope(
          navigator: navigator,
          child: AppShell(
            picker: WindowsFilePicker(),
            runningApps: WindowsRunningApps(),
            onAction: (AppAction action) => unawaited(actions.handle(action)),
          ),
        ),
      ),
    );
  }
}
