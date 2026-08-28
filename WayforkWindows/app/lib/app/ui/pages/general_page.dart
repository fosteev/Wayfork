import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wayfork/app/model/app_model.dart';
import 'package:wayfork/app/services/diagnostics_exporter.dart';
import 'package:wayfork/app/services/file_picker.dart';
import 'package:wayfork/app/services/log_center.dart';
import 'package:wayfork/app/ui/app_actions.dart';
import 'package:wayfork/app/ui/app_scope.dart';
import 'package:wayfork/app/ui/backup_dialogs.dart';
import 'package:wayfork/app/ui/widgets/components.dart';
import 'package:wayfork/core/app/import_export.dart';
import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/ipc/payloads.dart';
import 'package:wayfork/core/model/settings.dart';

/// General (docs/design/prototype/windows.html, board 6): the settings of the
/// macOS General pane retitled for Windows — "Launch at login" becomes
/// *Start at sign-in*, the helper block becomes the **service** block (which
/// runs as LocalSystem and is repaired by the installer, not by the app).
class GeneralPage extends StatefulWidget {
  const GeneralPage({
    required this.picker,
    this.diagnostics = const DiagnosticsExporter(),
    this.openFolder = openFolderInExplorer,
    this.openSettings = openInstalledApps,
    this.reveal = revealInExplorer,
    super.key,
  });

  /// The save and open dialogs of Backup and Export Diagnostics.
  final FilePicker picker;

  /// Builds the diagnostics bundle; injected in the tests, which have no
  /// `ipconfig` to run.
  final DiagnosticsExporter diagnostics;

  /// Seams for the tests: all three shell out to Explorer on Windows.
  final Future<void> Function(String path) openFolder;
  final Future<void> Function() openSettings;
  final Future<void> Function(String path) reveal;

  @override
  State<GeneralPage> createState() => _GeneralPageState();
}

class _GeneralPageState extends State<GeneralPage> {
  final _dns = TextEditingController();
  final _dnsFocus = FocusNode();
  String? _dnsError;
  bool _loaded = false;

  /// Which resolver mode the radio group shows. Kept here rather than derived
  /// from the settings: picking *Custom* has to enable the field before there
  /// are any servers to store.
  bool _customDNS = false;

  /// The last `AppNavigator.diagnosticsToken` this page acted on: the tray and
  /// the alert button land here and expect the sheet to be open.
  int _diagnosticsToken = 0;
  bool _exporting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final token = NavigationScope.of(context).diagnosticsToken;
    if (token != _diagnosticsToken) {
      _diagnosticsToken = token;
      if (token != 0) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_exportDiagnostics()),
        );
      }
    }
    if (_loaded) return;
    _loaded = true;
    final directDNS = AppScope.of(context).settings.directDNS;
    if (directDNS case DirectDNSCustom(:final servers)) {
      _customDNS = true;
      _dns.text = servers.join(', ');
    }
    _dnsFocus.addListener(() {
      if (!_dnsFocus.hasFocus) _commitDNS();
    });
  }

  @override
  void dispose() {
    _dns.dispose();
    _dnsFocus.dispose();
    super.dispose();
  }

  AppModel get _model => AppScope.of(context);

  Future<void> _set(Settings Function(Settings settings) mutate) =>
      _model.updateSettings(mutate);

  void _commitDNS() {
    // The field also commits when it loses focus, which is exactly what
    // switching back to System does — that blur must not undo the switch.
    if (!_customDNS) return;
    final servers = _dns.text
        .split(RegExp('[, ]'))
        .map((server) => server.trim())
        .where((server) => server.isNotEmpty)
        .toList();
    if (servers.isEmpty ||
        servers.any((server) => InternetAddress.tryParse(server) == null)) {
      setState(() {
        _dnsError = servers.isEmpty
            ? 'Enter at least one resolver address'
            : 'Not an IP address';
      });
      return;
    }
    setState(() => _dnsError = null);
    unawaited(
      _set(
        (settings) => settings.copyWith(directDNS: DirectDNSCustom(servers)),
      ),
    );
  }

  void _setCustomDNS(bool custom) {
    setState(() {
      _customDNS = custom;
      _dnsError = null;
    });
    if (custom) {
      _commitDNS();
    } else {
      unawaited(
        _set(
          (settings) => settings.copyWith(directDNS: const DirectDNSSystem()),
        ),
      );
    }
  }

  /// Backup › Export…: the options sheet, the save dialog, the write.
  Future<void> _exportStore() async {
    final model = _model;
    final includeSecrets = await showExportDialog(
      context,
      tunnels: model.store.tunnels.length,
      rules: model.store.rules.length,
    );
    if (includeSecrets == null) return;
    final path = await widget.picker.saveFile(
      label: 'Wayfork export',
      extensions: const ['json'],
      suggestedName: AppModelImportExport.exportFileName,
      confirmButtonText: 'Export',
    );
    if (path == null) return;
    await model.exportStoreTo(path, includeSecrets: includeSecrets);
  }

  /// Backup › Import…: the open dialog, the summary, Replace all / Merge.
  Future<void> _importStore() async {
    final model = _model;
    final path = await widget.picker.openFile(
      label: 'Wayfork export',
      extensions: const ['json'],
      confirmButtonText: 'Import',
    );
    if (path == null) return;
    final document = await model.readImport(path);
    if (document == null || !mounted) return;
    final mode = await showImportDialog(
      context,
      StoreImporter.preview(document),
    );
    if (mode == null) return;
    await model.performImport(document, mode);
  }

  /// "Export Diagnostics…", from the button and from the failed-card action.
  Future<void> _exportDiagnostics() async {
    if (_exporting || !mounted) return;
    _exporting = true;
    try {
      final model = _model;
      final includeServers = await showDiagnosticsDialog(context);
      if (includeServers == null) return;
      final path = await widget.picker.saveFile(
        label: 'Diagnostics archive',
        extensions: const ['zip'],
        suggestedName: widget.diagnostics.suggestedFileName(),
        confirmButtonText: 'Export',
      );
      if (path == null) return;
      final written = await widget.diagnostics.export(
        model,
        path: path,
        includeServerAddresses: includeServers,
      );
      if (written) await widget.reveal(path);
    } finally {
      _exporting = false;
    }
  }

  /// The counterpart of the macOS "Reinstall helper": on Windows the service
  /// belongs to the installer, so the app can only point at it.
  Future<void> _repair() async {
    final confirmed = await showQuestionDialog(
      context,
      title: 'Repair the Wayfork service',
      message:
          'The Wayfork service is installed by the Wayfork installer and runs '
          'as LocalSystem. To reinstall it, open Installed apps, pick Wayfork '
          'and choose Modify → Repair, then reopen Wayfork.',
      confirm: 'Open Installed Apps',
    );
    if (confirmed) await widget.openSettings();
  }

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final settings = model.settings;
    final isCustomDNS = _customDNS;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageTitle('General'),
          const SizedBox(height: 14),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Section(
                    title: 'Startup',
                    children: [
                      _SettingRow(
                        label: 'Start Wayfork at sign-in',
                        child: ToggleSwitch(
                          checked: settings.launchAtLogin,
                          onChanged: (on) => unawaited(
                            _set(
                              (settings) =>
                                  settings.copyWith(launchAtLogin: on),
                            ),
                          ),
                        ),
                      ),
                      _SettingRow(
                        label: 'Connect on launch',
                        child: ToggleSwitch(
                          checked: settings.connectOnLaunch,
                          onChanged: (on) => unawaited(
                            _set(
                              (settings) =>
                                  settings.copyWith(connectOnLaunch: on),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Reliability',
                    children: [
                      _SettingRow(
                        label: 'Reconnect tunnels automatically',
                        child: ToggleSwitch(
                          checked: settings.autoReconnect,
                          onChanged: (on) => unawaited(
                            _set(
                              (settings) =>
                                  settings.copyWith(autoReconnect: on),
                            ),
                          ),
                        ),
                      ),
                      _SettingRow(
                        label: 'Notify when a tunnel fails',
                        child: ToggleSwitch(
                          checked: settings.notifyOnTunnelFailure,
                          onChanged: (on) => unawaited(
                            _set(
                              (settings) =>
                                  settings.copyWith(notifyOnTunnelFailure: on),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'DNS',
                    children: [
                      _SettingRow(
                        label: 'Use Wayfork as the system resolver while On',
                        hint:
                            'Points the adapters at Wayfork so a router or a '
                            'stale resolver cannot route around the rules.',
                        child: ToggleSwitch(
                          checked: settings.overrideSystemDNS,
                          onChanged: (on) => unawaited(
                            _set(
                              (settings) =>
                                  settings.copyWith(overrideSystemDNS: on),
                            ),
                          ),
                        ),
                      ),
                      _SettingRow(
                        label: 'Direct traffic resolver',
                        child: Row(
                          children: [
                            RadioGroup<bool>(
                              groupValue: isCustomDNS,
                              onChanged: (custom) =>
                                  _setCustomDNS(custom ?? false),
                              child: const Row(
                                children: [
                                  RadioButton(
                                    value: false,
                                    content: Text('System'),
                                  ),
                                  SizedBox(width: 14),
                                  RadioButton(
                                    value: true,
                                    content: Text('Custom'),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 190,
                              child: FieldWithError(
                                error: _dnsError,
                                child: TextBox(
                                  controller: _dns,
                                  focusNode: _dnsFocus,
                                  enabled: isCustomDNS,
                                  placeholder: '1.1.1.1, 9.9.9.9',
                                  onSubmitted: (_) => _commitDNS(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Logs',
                    children: [
                      _SettingRow(
                        label: 'Level',
                        hint: settings.logLevel == LogLevel.debug
                            ? 'Debug logs may include hostnames.'
                            : null,
                        child: SizedBox(
                          width: 130,
                          child: ComboBox<LogLevel>(
                            isExpanded: true,
                            value: settings.logLevel,
                            items: [
                              for (final level in LogLevel.values)
                                ComboBoxItem(
                                  value: level,
                                  child: Text(_levelTitle(level)),
                                ),
                            ],
                            onChanged: (level) => unawaited(
                              _set(
                                (settings) =>
                                    settings.copyWith(logLevel: level),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _SettingRow(
                        label: 'Keep logs for',
                        child: Row(
                          children: [
                            SizedBox(
                              width: 110,
                              child: NumberBox<int>(
                                value: settings.logRetentionDays,
                                min: 1,
                                max: 365,
                                clearButton: false,
                                mode: SpinButtonPlacementMode.inline,
                                onChanged: (days) => unawaited(
                                  _set(
                                    (settings) => settings.copyWith(
                                      logRetentionDays: days?.clamp(1, 365),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SecondaryText('days'),
                            const SizedBox(width: 14),
                            Button(
                              onPressed: () => unawaited(
                                widget.openFolder(
                                  model.logs.directory?.path ??
                                      LogCenter.defaultDirectory().path,
                                ),
                              ),
                              child: const Text('Open Logs Folder'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Service & About',
                    children: [
                      _ServiceRow(onRepair: () => unawaited(_repair())),
                      _SettingRow(
                        label: 'Wayfork ${model.appVersion}',
                        hint: _binaryVersions(model.serviceInfo),
                        child: Button(
                          onPressed: () => unawaited(_exportDiagnostics()),
                          child: const Text('Export Diagnostics…'),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Backup',
                    children: [
                      _SettingRow(
                        label: 'Tunnels and rules',
                        hint:
                            'wayfork-export.json carries tunnels, rules and '
                            'settings between machines.',
                        child: Row(
                          children: [
                            Button(
                              onPressed: () => unawaited(_exportStore()),
                              child: const Text('Export…'),
                            ),
                            const SizedBox(width: 8),
                            Button(
                              onPressed: () => unawaited(_importStore()),
                              child: const Text('Import…'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The pinned binaries the service reports (the prototype's About line).
  static String _binaryVersions(DaemonInfo? info) {
    if (info == null) return 'service not connected';
    final singBox = info.singBoxVersion.isEmpty
        ? 'sing-box ?'
        : 'sing-box ${info.singBoxVersion}';
    final openVPN = info.openVPNVersion.isEmpty
        ? 'OpenVPN ?'
        : 'OpenVPN ${info.openVPNVersion}';
    return '$singBox · $openVPN';
  }
}

/// Glyph, state and version of the Windows service, with the repair the
/// installer owns.
class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.onRepair});

  final VoidCallback onRepair;

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final issue = model.serviceIssue;
    final info = model.serviceInfo;
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          StatusGlyphView(
            glyph: switch (issue?.needsRepair) {
              null => StatusGlyph.up,
              true => StatusGlyph.failed,
              false => StatusGlyph.transitioning,
            },
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              issue?.message ?? 'Wayfork service running',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: issue?.needsRepair ?? false
                    ? theme.resources.systemFillColorCritical
                    : null,
              ),
            ),
          ),
          if (issue == null && info != null) ...[
            const SizedBox(width: 6),
            SecondaryText('· v${info.version} · LocalSystem'),
          ],
          const Spacer(),
          Button(onPressed: onRepair, child: const Text('Repair…')),
        ],
      ),
    );
  }
}

/// A titled group of setting rows.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: SecondaryText(title),
        ),
        GroupCard(children: children),
      ],
    ),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.child, this.hint});

  final String label;
  final String? hint;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (hint case final hint?) ...[
                const SizedBox(height: 2),
                SecondaryText(hint, maxLines: 2, overflow: TextOverflow.clip),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        child,
      ],
    ),
  );
}

String _levelTitle(LogLevel level) => switch (level) {
  LogLevel.error => 'Error',
  LogLevel.warning => 'Warning',
  LogLevel.info => 'Info',
  LogLevel.debug => 'Debug',
};
