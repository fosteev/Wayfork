import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/model/rule.dart';
import 'package:wayfork/core/model/store.dart';
import 'package:wayfork/core/rules/app_files.dart';
import 'package:wayfork/core/rules/versioned_app_path.dart';

/// An in-memory [AppFiles] for [VersionedAppPath.heal] tests.
final class FakeAppFiles implements AppFiles {
  final Map<String, DateTime> _files = {};
  final Map<String, List<String>> _directories = {};

  void addFile(String path, DateTime modified) => _files[path] = modified;

  void addDirectory(String parentPath, String name) =>
      (_directories[parentPath] ??= []).add(name);

  @override
  bool exists(String filePath) => _files.containsKey(filePath);

  @override
  List<String> listDirectories(String parentPath) =>
      List.of(_directories[parentPath] ?? const []);

  @override
  DateTime? modified(String filePath) => _files[filePath];
}

void main() {
  group('isVersionedComponent', () {
    test('recognizes Squirrel version folders', () {
      expect(VersionedAppPath.isVersionedComponent('app-1.0.9255'), isTrue);
      expect(VersionedAppPath.isVersionedComponent('app-1.0.9259'), isTrue);
      expect(VersionedAppPath.isVersionedComponent('APP-2.0.1-beta'), isTrue);
    });

    test('recognizes MSIX package folders', () {
      expect(
        VersionedAppPath.isVersionedComponent(
          'Contoso.App_1.2.3.0_x64__8wekyb3d8bbwe',
        ),
        isTrue,
      );
      expect(
        VersionedAppPath.isVersionedComponent(
          'Contoso.App_1.3.0.0_x64__8wekyb3d8bbwe',
        ),
        isTrue,
      );
    });

    test('rejects components that only look versioned', () {
      expect(VersionedAppPath.isVersionedComponent('my-app-1.0'), isFalse);
      expect(VersionedAppPath.isVersionedComponent('app-'), isFalse);
      expect(VersionedAppPath.isVersionedComponent('Update.exe'), isFalse);
      expect(VersionedAppPath.isVersionedComponent('Discord'), isFalse);
      expect(VersionedAppPath.isVersionedComponent('DiscordPTB'), isFalse);
    });
  });

  group('VersionedAppPath.regex', () {
    // Callers wrap the middle in `(?i)^...$`; do the same here so the tests
    // exercise exactly what ships.
    RegExp widened(String path) =>
        RegExp('^${VersionedAppPath.regex(path)}\$', caseSensitive: false);

    test('a Squirrel install folder matches any sibling version', () {
      const original =
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9255\Discord.exe';
      final pattern = widened(original);
      expect(pattern.hasMatch(original), isTrue);
      expect(
        pattern.hasMatch(
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9259\Discord.exe',
        ),
        isTrue,
      );
      expect(
        pattern.hasMatch(
          r'C:\Users\Alex\AppData\Local\Discord\APP-2.0.1-beta\Discord.exe',
        ),
        isTrue,
      );
      // Not a sibling: no version folder at all.
      expect(
        pattern.hasMatch(r'C:\Users\Alex\AppData\Local\Discord\Update.exe'),
        isFalse,
      );
      // Not a sibling: a different app (Discord PTB) that also has a
      // version folder.
      expect(
        pattern.hasMatch(
          r'C:\Users\Alex\AppData\Local\DiscordPTB\app-1.0.9255\Discord.exe',
        ),
        isFalse,
      );
      // Unrelated short literal fragment.
      expect(pattern.hasMatch(r'app-\Discord.exe'), isFalse);
    });

    test('an MSIX package folder matches any sibling version, not another '
        'arch or publisher', () {
      const original =
          r'C:\Program Files\WindowsApps\Contoso.App_1.2.3.0_x64__8wekyb3d8bbwe\App.exe';
      final pattern = widened(original);
      expect(pattern.hasMatch(original), isTrue);
      expect(
        pattern.hasMatch(
          r'C:\Program Files\WindowsApps\Contoso.App_1.3.0.0_x64__8wekyb3d8bbwe\App.exe',
        ),
        isTrue,
      );
      // Another arch.
      expect(
        pattern.hasMatch(
          r'C:\Program Files\WindowsApps\Contoso.App_1.2.3.0_arm64__8wekyb3d8bbwe\App.exe',
        ),
        isFalse,
      );
      // Another publisher hash.
      expect(
        pattern.hasMatch(
          r'C:\Program Files\WindowsApps\Contoso.App_1.2.3.0_x64__abcdef1234567\App.exe',
        ),
        isFalse,
      );
    });

    test('a path with no versioned folder stays literal', () {
      expect(
        VersionedAppPath.regex(r'C:\my-app-1.0\x.exe'),
        r'C:\\my-app-1\.0\\x\.exe',
      );
      // The last component is the .exe name, never widened even when it
      // happens to look like a Squirrel folder.
      expect(VersionedAppPath.regex(r'C:\app-1.0.exe'), r'C:\\app-1\.0\.exe');
    });

    test('RE2 compatibility: no lookarounds or backreferences', () {
      const path =
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9255\Discord.exe';
      final regex = VersionedAppPath.regex(path);
      expect(regex, isNot(contains('(?=')));
      expect(regex, isNot(contains('(?!')));
      expect(regex, isNot(contains('(?<')));
      expect(regex, isNot(matches(RegExp(r'\\[1-9]'))));
    });
  });

  group('VersionedAppPath.key', () {
    test('two versions of the same Squirrel install compare equal', () {
      expect(
        VersionedAppPath.key(
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9255\Discord.exe',
        ),
        VersionedAppPath.key(
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9259\Discord.exe',
        ),
      );
    });

    test('two versions of the same MSIX package compare equal', () {
      expect(
        VersionedAppPath.key(
          r'C:\Program Files\WindowsApps\Contoso.App_1.2.3.0_x64__8wekyb3d8bbwe\App.exe',
        ),
        VersionedAppPath.key(
          r'C:\Program Files\WindowsApps\Contoso.App_1.3.0.0_x64__8wekyb3d8bbwe\App.exe',
        ),
      );
    });

    test('a different app, arch or publisher does not compare equal', () {
      final discord = VersionedAppPath.key(
        r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9255\Discord.exe',
      );
      expect(
        VersionedAppPath.key(
          r'C:\Users\Alex\AppData\Local\DiscordPTB\app-1.0.9255\Discord.exe',
        ),
        isNot(discord),
      );
      final msix = VersionedAppPath.key(
        r'C:\Program Files\WindowsApps\Contoso.App_1.2.3.0_x64__8wekyb3d8bbwe\App.exe',
      );
      expect(
        VersionedAppPath.key(
          r'C:\Program Files\WindowsApps\Contoso.App_1.2.3.0_arm64__8wekyb3d8bbwe\App.exe',
        ),
        isNot(msix),
      );
      expect(
        VersionedAppPath.key(
          r'C:\Program Files\WindowsApps\Contoso.App_1.2.3.0_x64__abcdef1234567\App.exe',
        ),
        isNot(msix),
      );
    });

    test('is case-insensitive', () {
      expect(
        VersionedAppPath.key(
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9255\Discord.exe',
        ),
        VersionedAppPath.key(
          r'c:\users\alex\appdata\local\discord\APP-1.0.9259\discord.exe',
        ),
      );
    });

    test('a path with no versioned folder stays literal', () {
      expect(
        VersionedAppPath.key(r'C:\my-app-1.0\x.exe'),
        r'c:\my-app-1.0\x.exe',
      );
    });
  });

  group('VersionedAppPath.heal', () {
    const parent = r'C:\Users\Alex\AppData\Local\Discord';
    const missing =
        r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9255\Discord.exe';

    test('picks the newest by mtime among three siblings, not the highest '
        'version', () {
      final files = FakeAppFiles()
        ..addDirectory(parent, 'app-1.0.9255')
        ..addDirectory(parent, 'app-1.0.9258')
        ..addDirectory(parent, 'app-1.0.9259')
        // The higher version number is not the most recently written one.
        ..addFile(
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9258\Discord.exe',
          DateTime(2024, 1, 3),
        )
        ..addFile(
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9259\Discord.exe',
          DateTime(2024, 1, 2),
        );
      final store = Store(
        rules: [
          Rule(
            pattern: missing,
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
          ),
        ],
      );
      final healed = VersionedAppPath.heal(store, files);
      expect(healed.rules.single.pattern, contains('app-1.0.9258'));
    });

    test('leaves a non-versioned missing path alone', () {
      const pattern = r'C:\Program Files\OldApp\App.exe';
      final store = Store(
        rules: [
          Rule(
            pattern: pattern,
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
          ),
        ],
      );
      final healed = VersionedAppPath.heal(store, FakeAppFiles());
      expect(identical(healed, store), isTrue);
    });

    test('moves off an older build that is still on disk', () {
      // Squirrel keeps the previous app-<ver> after an update.
      final files = FakeAppFiles()
        ..addDirectory(parent, 'app-1.0.9255')
        ..addDirectory(parent, 'app-1.0.9259')
        ..addFile(missing, DateTime(2024, 1, 1))
        ..addFile(
          r'C:\Users\Alex\AppData\Local\Discord\app-1.0.9259\Discord.exe',
          DateTime(2024, 1, 2),
        );
      final store = Store(
        rules: [
          Rule(
            pattern: missing,
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
          ),
        ],
      );
      final healed = VersionedAppPath.heal(store, files);
      expect(healed.rules.single.pattern, contains('app-1.0.9259'));
    });

    test('leaves the newest existing build alone', () {
      final files = FakeAppFiles()
        ..addDirectory(parent, 'app-1.0.9255')
        ..addFile(missing, DateTime(2024, 1, 1));
      final store = Store(
        rules: [
          Rule(
            pattern: missing,
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
          ),
        ],
      );
      final healed = VersionedAppPath.heal(store, files);
      expect(identical(healed, store), isTrue);
    });

    test('returns the same Store instance when no sibling is found', () {
      final files = FakeAppFiles()..addDirectory(parent, 'app-1.0.9255');
      final store = Store(
        rules: [
          Rule(
            pattern: missing,
            match: RuleMatch.app,
            target: const RuleTargetDirect(),
          ),
        ],
      );
      final healed = VersionedAppPath.heal(store, files);
      expect(identical(healed, store), isTrue);
    });
  });
}
