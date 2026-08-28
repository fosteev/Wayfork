part of 'app_model.dart';

// Import / export of `wayfork-export.json` (F7, docs/design/01-data-model.md).
// The file dialogs and the on-disk write arrive with WM3f; the model builds
// and applies documents.

extension AppModelImportExport on AppModel {
  static const exportFileName = 'wayfork-export.json';

  /// The document to save; `includeSecrets` comes from the sheet checkbox.
  Future<ExportDocument> exportDocument({required bool includeSecrets}) async {
    final document = await StoreExporter.document(
      store: _store,
      secretStore: _secrets,
      includeSecrets: includeSecrets,
    );
    logs.app(
      LogLevel.info,
      'exported ${document.tunnels.length} tunnels, ${document.rules.length} '
      'rules${includeSecrets ? ' with secrets' : ''}',
    );
    return document;
  }

  /// Decodes a picked file; null when it is not a Wayfork export (an alert
  /// was queued).
  ExportDocument? decodeImport(String text) {
    try {
      return ExportDocument.decode(text);
    } on ExportDocumentException catch (error) {
      switch (error.kind) {
        case ExportDocumentError.unknownFormat:
          _alert(
            AppAlert(
              title: 'Not a Wayfork export',
              message:
                  'The file\'s format is "${error.format}", expected '
                  '"${ExportDocument.formatName}".',
            ),
          );
        case ExportDocumentError.newerVersion:
          _alert(
            AppAlert(
              title: 'Export from a newer Wayfork',
              message:
                  'The file uses export format version ${error.version}; '
                  'update Wayfork.',
            ),
          );
      }
    } on Object catch (error) {
      _alert(AppAlert(title: 'Cannot import', message: '$error'));
    }
    return null;
  }

  Future<ImportOutcome> performImport(
    ExportDocument document,
    ImportMode mode,
  ) async {
    final outcome = StoreImporter.apply(document, to: _store, mode: mode);
    var secretErrors = 0;
    for (final MapEntry(:key, :value) in outcome.secrets.entries) {
      try {
        await _secrets.write(value, key);
      } on Object catch (error) {
        secretErrors += 1;
        logs.app(
          LogLevel.error,
          'cannot store imported secret ${key.account}: $error',
        );
      }
    }
    await update((_) => outcome.store);
    if (mode == ImportMode.replace) {
      try {
        await _secrets.removeOrphans(_store);
      } on Object catch (error) {
        logs.app(LogLevel.warning, 'cannot prune orphaned secrets: $error');
      }
      await recomputeMissingSecrets();
      try {
        _launchAtLogin.setEnabled(_store.settings.launchAtLogin);
      } on Object catch (error) {
        logs.app(LogLevel.warning, 'launch at login: $error');
      }
    }
    for (final warning in outcome.warnings) {
      logs.app(LogLevel.warning, 'import: $warning');
    }
    logs.app(
      LogLevel.info,
      'import (${mode.name}): +${outcome.tunnelsAdded}/~'
      '${outcome.tunnelsUpdated} tunnels, +${outcome.rulesAdded}/~'
      '${outcome.rulesUpdated} rules, ${outcome.rulesSkipped} skipped',
    );
    if (outcome.warnings.isNotEmpty || secretErrors > 0) {
      final lines = [...outcome.warnings];
      if (secretErrors > 0) {
        lines.add('$secretErrors secrets could not be stored.');
      }
      _alert(
        AppAlert(
          title: 'Import finished with warnings',
          message: lines.take(12).join('\n'),
        ),
      );
    }
    return outcome;
  }
}
