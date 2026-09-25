import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/app/services/window_controller.dart';

import 'lifecycle_fakes.dart';

void main() {
  test('closing the window hides it instead of quitting', () async {
    final backend = FakeWindowBackend();
    final window = WindowController(backend);
    await window.start();
    expect(backend.visible, isTrue);

    backend.close();
    await Future<void>.delayed(Duration.zero);
    expect(backend.visible, isFalse);
    expect(backend.destroyed, isFalse);
  });

  test('launch at login starts into the tray', () async {
    final backend = FakeWindowBackend();
    await WindowController(backend).start(startHidden: true);
    expect(backend.visible, isFalse);
  });

  test(
    'the tray click toggles, and raises a window that is not in front',
    () async {
      final backend = FakeWindowBackend();
      final window = WindowController(backend);
      await window.start();

      await window.toggle();
      expect(backend.visible, isFalse);

      await window.toggle();
      expect(backend.visible, isTrue);
      expect(backend.focused, isTrue);

      // Visible but buried: come forward rather than disappear.
      backend.focused = false;
      await window.toggle();
      expect(backend.visible, isTrue);
      expect(backend.focused, isTrue);
    },
  );

  test('quit destroys the window', () async {
    final backend = FakeWindowBackend();
    final window = WindowController(backend);
    await window.start();
    await window.quit();
    expect(backend.destroyed, isTrue);
    await window.dispose();
    expect(backend.disposals, 1);
  });
}
