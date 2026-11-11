import 'dart:convert';
import 'dart:io';

/// Local presentation state, deliberately outside portable routing/export data.
final class RuleListPreferences {
  RuleListPreferences({this.file}) {
    try {
      final data = jsonDecode(file?.readAsStringSync() ?? '{}');
      if (data is! Map<String, dynamic>) return;
      lastUsed = data['lastUsed'] as String?;
      initialized = data['initialized'] == true;
      for (final entry in (data['switched'] as Map? ?? {}).entries) {
        final at = DateTime.tryParse('${entry.value}');
        if (at != null) switched['${entry.key}'] = at;
      }
      expanded.addAll((data['expanded'] as List? ?? []).whereType<String>());
    } on Object {
      // Presentation preferences cannot prevent the routing store from loading.
    }
  }

  final File? file;
  String? lastUsed;
  bool initialized = false;
  final switched = <String, DateTime>{};
  final expanded = <String>{};

  void save() {
    final target = file;
    if (target == null) return;
    try {
      target.parent.createSync(recursive: true);
      final pending = File('${target.path}.tmp');
      pending.writeAsStringSync(
        jsonEncode({
          'lastUsed': lastUsed,
          'initialized': initialized,
          'switched': switched.map(
            (id, at) => MapEntry(id, at.toIso8601String()),
          ),
          'expanded': expanded.toList(),
        }),
        flush: true,
      );
      pending.renameSync(target.path);
    } on Object {
      // Losing local UI preferences must not undo a successful routing edit.
    }
  }
}
