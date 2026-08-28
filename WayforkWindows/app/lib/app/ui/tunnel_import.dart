import 'dart:io';

import 'package:wayfork/app/model/app_alert.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/core/openvpn/openvpn_config_parser.dart';

/// Asks whether to look for [missing] in another folder; the macOS
/// "Referenced files not found" alert with its two buttons. True means the
/// folder picker follows.
typedef FolderConfirmation = Future<bool> Function(List<String> missing);

/// The `.ovpn` half of tunnel management (F1) that cannot live in the model:
/// the file dialogs, the retry loop for configs whose `ca`/`cert`/`key` files
/// sit next to them, and the error alerts. The model takes the parsed result
/// (`AppModelTunnels.addOpenVPN`).
final class TunnelImporter {
  const TunnelImporter({
    required this.model,
    required this.picker,
    required this.confirmFolder,
  });

  static const fileExtension = 'ovpn';

  final AppModel model;
  final FilePicker picker;
  final FolderConfirmation confirmFolder;

  /// "Add ▾ › Import OpenVPN Config…".
  Future<void> importFromPicker() async {
    final path = await picker.openFile(
      label: 'OpenVPN profile',
      extensions: const [fileExtension],
      confirmButtonText: 'Import',
    );
    if (path == null) return;
    await importFile(path);
  }

  /// Adds one profile; the tunnel is named after the file, as on macOS.
  Future<void> importFile(String path) async {
    final result = await _parse(path);
    if (result == null) return;
    await model.addOpenVPN(result, name: _tunnelName(path));
  }

  /// The expanded row's "Replace…": a new profile for an existing tunnel,
  /// keeping its name, rules and DNS choice.
  Future<void> replaceConfig(String tunnelID) async {
    final path = await picker.openFile(
      label: 'OpenVPN profile',
      extensions: const [fileExtension],
      confirmButtonText: 'Replace',
    );
    if (path == null) return;
    final result = await _parse(path);
    if (result == null) return;
    final error = await model.replaceOpenVPNConfig(tunnelID, result);
    if (error != null) _alert('Cannot replace the config', error);
  }

  /// A drop anywhere in the window: every `.ovpn` in it, in order. Anything
  /// else is ignored — the window is not a general drop target.
  Future<void> importDropped(Iterable<String> paths) async {
    for (final path in paths) {
      if (!path.toLowerCase().endsWith('.$fileExtension')) continue;
      await importFile(path);
    }
  }

  /// Reads and parses, asking for the folder that holds the referenced files
  /// while the parser keeps missing them.
  Future<OpenVPNImportResult?> _parse(String path) async {
    final String text;
    try {
      text = await File(path).readAsString();
    } on Object catch (error) {
      _alert('Cannot read file', '$error');
      return null;
    }
    var directory = _directoryOf(path);
    while (true) {
      try {
        return OpenVPNConfigParser.parse(
          text,
          baseDirectory: directory == null ? null : Directory(directory),
        );
      } on OpenVPNImportException catch (error) {
        switch (error.kind) {
          case OpenVPNImportError.missingFiles:
            if (!await confirmFolder(error.files)) return null;
            final folder = await picker.chooseDirectory(
              confirmButtonText: 'Use Folder',
            );
            if (folder == null) return null;
            directory = folder;
          case OpenVPNImportError.unsupported:
            _alert('Unsupported config', '${error.reason} is not supported.');
            return null;
          case OpenVPNImportError.noRemote:
            _alert('Invalid config', 'The profile has no `remote` directive.');
            return null;
          case OpenVPNImportError.malformed:
            _alert('Invalid config', 'Line ${error.line}: ${error.reason}');
            return null;
        }
      } on Object catch (error) {
        _alert('Invalid config', '$error');
        return null;
      }
    }
  }

  void _alert(String title, String message) =>
      model.showAlert(AppAlert(title: title, message: message));

  /// `C:\profiles\work.ovpn` → `work`.
  static String _tunnelName(String path) {
    final file = path.substring(_separator(path) + 1);
    final dot = file.lastIndexOf('.');
    return dot <= 0 ? file : file.substring(0, dot);
  }

  /// Null when the path has no directory part at all.
  static String? _directoryOf(String path) {
    final index = _separator(path);
    return index < 0 ? null : path.substring(0, index == 0 ? 1 : index);
  }

  /// Both separators: a path dropped from Explorer uses `\`, one typed in a
  /// test or arriving from a shell may use `/`.
  static int _separator(String path) {
    final backslash = path.lastIndexOf(r'\');
    final slash = path.lastIndexOf('/');
    return backslash > slash ? backslash : slash;
  }
}
