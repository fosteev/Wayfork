import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/services/window_controller.dart';
import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/ui/app_actions.dart';
import 'package:wayfork/app/ui/app_navigation.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/main.dart';

import 'app/fakes.dart';
import 'app/lifecycle_fakes.dart';

void main() {
  testWidgets('the app builds the shell over the model', (tester) async {
    final app = Harness();
    await tester.runAsync(() async {
      app.service.status = RuntimeStatus.stopped;
      await app.start();
    });
    addTearDown(() => tester.runAsync(app.dispose));

    final navigator = AppNavigator();
    final window = WindowController(FakeWindowBackend());
    final actions = AppActionHandler(
      model: app.model,
      navigator: navigator,
      window: window,
      reveal: (_) async {},
    );
    addTearDown(actions.dispose);

    await tester.pumpWidget(
      WayforkApp(model: app.model, navigator: navigator, actions: actions),
    );
    await tester.pumpAndSettle();

    for (final page in AppPage.values) {
      expect(find.text(page.title), findsWidgets, reason: page.title);
    }
  });

  test('the diagnostics action sends General to its sheet', () async {
    final app = Harness();
    await app.start();
    addTearDown(app.dispose);
    final navigator = AppNavigator();
    final actions = AppActionHandler(
      model: app.model,
      navigator: navigator,
      window: WindowController(FakeWindowBackend()),
      reveal: (_) async {},
    );
    addTearDown(actions.dispose);

    await actions.handle(const AppAction.exportDiagnostics());
    expect(navigator.page, AppPage.general);
    expect(navigator.diagnosticsToken, 1);
  });
}
