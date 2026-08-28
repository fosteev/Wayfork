import 'package:wayfork/core/app/status_text.dart';
import 'package:wayfork/core/ipc/payloads.dart';

/// Rate and total strings for the Dashboard (docs/design/02-ux.md, "Traffic
/// rates"): decimal units, at most three significant digits, fixed formatting so
/// the labels do not jitter — `0 B/s`, `85 KB/s`, `1.2 MB/s`, `12 MB/s`; totals
/// the same without `/s`.
abstract final class TrafficFormat {
  static const _units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

  /// Shown while no sample arrived for [staleAfter].
  static const stale = '↓ — ↑ —';
  static const staleAfter = Duration(seconds: 3);

  static String bytes(int count) {
    if (count < 0) count = 0;
    var value = count.toDouble();
    var unit = 0;
    while (value >= 999.5 && unit < _units.length - 1) {
      value /= 1000;
      unit += 1;
    }
    if (unit == 0) return '$count B';
    // One decimal below 10 (1.2 MB), none above (12 MB, 123 MB); 9.95 rounds up
    // to 10.
    final text = value < 9.95
        ? value.toStringAsFixed(1)
        : value.toStringAsFixed(0);
    return '$text ${_units[unit]}';
  }

  static String rate(double bytesPerSecond) {
    final clamped = bytesPerSecond.isFinite && bytesPerSecond > 0
        ? bytesPerSecond
        : 0.0;
    return '${bytes(clamped.round())}/s';
  }

  /// `↓ 1.2 MB/s ↑ 85 KB/s`, or the stale placeholder for null.
  static String rateLabel(TrafficCounters? counters) {
    if (counters == null) return stale;
    return '↓ ${rate(counters.downBytesPerSecond)} '
        '↑ ${rate(counters.upBytesPerSecond)}';
  }

  /// Tooltip: `Since Turn On: ↓ 1.2 GB ↑ 88 MB · 14 connections`.
  static String tooltip(TrafficCounters counters) =>
      'Since Turn On: ↓ ${bytes(counters.downTotal)} '
      '↑ ${bytes(counters.upTotal)} · '
      '${StatusText.count(counters.connections, 'connection')}';

  static final staleTooltip =
      'No traffic sample in the last ${staleAfter.inSeconds} seconds';

  /// Label of the Direct row: exceptions only when a default tunnel takes the
  /// rest (F8).
  static String directRowTitle({required bool hasDefaultTunnel}) =>
      hasDefaultTunnel ? 'Direct · exceptions' : 'Direct';
}
