import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/running_app.dart';

RunningProcess process(String path, {String? description, String? title}) =>
    RunningProcess(path: path, description: description, windowTitle: title);

void main() {
  group('RunningApps.collate', () {
    test('folds the processes of one executable into a single entry', () {
      final apps = RunningApps.collate([
        process(
          r'C:\Apps\chrome.exe',
          description: 'Google Chrome',
          title: 'A',
        ),
        process(r'C:\Apps\chrome.exe', description: 'Google Chrome'),
        process(r'c:\apps\CHROME.EXE', description: 'Google Chrome'),
      ]);

      expect(apps, hasLength(1));
      expect(apps.single.path, r'C:\Apps\chrome.exe', reason: 'the first case');
      expect(apps.single.name, 'Google Chrome');
      expect(apps.single.instances, 3);
      expect(apps.single.windowTitle, 'A');
      expect(apps.single.hasWindow, isTrue);
    });

    test('falls back to the file name when there is no description', () {
      final apps = RunningApps.collate([
        process(r'C:\Apps\weird.exe'),
        process(r'C:\Apps\blank.exe', description: '   '),
      ]);

      expect(apps.map((app) => app.name), ['blank', 'weird']);
    });

    test('windowed apps come first, then names, case-insensitively', () {
      final apps = RunningApps.collate([
        process(r'C:\b\zed.exe', title: 'Zed'),
        process(r'C:\a\updater.exe', description: 'Updater'),
        process(r'C:\b\Alpha.exe', title: 'Alpha'),
      ]);

      expect(apps.map((app) => app.name), ['Alpha', 'zed', 'Updater']);
      expect(apps.map((app) => app.hasWindow), [true, true, false]);
    });

    test('drops the excluded paths and the empty ones', () {
      final apps = RunningApps.collate(
        [
          process(r'C:\Wayfork\wayfork.exe', title: 'Wayfork'),
          process('   '),
          process(r'C:\Apps\keep.exe', title: 'Keep'),
        ],
        exclude: [r'c:\wayfork\WAYFORK.exe'],
      );

      expect(apps.map((app) => app.path), [r'C:\Apps\keep.exe']);
    });

    test('a window found later marks an already-seen process windowed', () {
      final apps = RunningApps.collate([
        process(r'C:\Apps\app.exe'),
        process(r'C:\Apps\app.exe', title: 'App'),
      ]);

      expect(apps.single.hasWindow, isTrue);
      expect(apps.single.windowTitle, 'App');
    });
  });

  group('RunningApps.search', () {
    final apps = RunningApps.collate([
      process(
        r'C:\Program Files\Chrome\chrome.exe',
        description: 'Google Chrome',
        title: 'Wayfork — GitHub',
      ),
      process(r'C:\Apps\telegram.exe', description: 'Telegram Desktop'),
    ]);

    test('an empty query keeps everything', () {
      expect(RunningApps.search(apps, '  '), hasLength(2));
    });

    test('matches the name, the path and the window title', () {
      expect(RunningApps.search(apps, 'TELEG').single.name, 'Telegram Desktop');
      expect(
        RunningApps.search(apps, 'program files').single.name,
        'Google Chrome',
      );
      expect(RunningApps.search(apps, 'github').single.name, 'Google Chrome');
      expect(RunningApps.search(apps, 'firefox'), isEmpty);
    });
  });
}
