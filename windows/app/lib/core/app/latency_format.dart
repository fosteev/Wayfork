import 'package:wayfork/core/ipc/payloads.dart';

/// Colour band of a latency figure (docs/design/02-ux.md, "Variant C": green
/// ≤ 100 ms, amber ≤ 300 ms, red above).
enum LatencyBand {
  good,
  fair,
  poor;

  static LatencyBand of(int milliseconds) => milliseconds <= 100
      ? LatencyBand.good
      : milliseconds <= 300
      ? LatencyBand.fair
      : LatencyBand.poor;
}

/// Strings for the latency figure and its tooltip (F14).
abstract final class LatencyFormat {
  /// `62 ms`.
  static String label(int milliseconds) => '$milliseconds ms';

  /// `Measured through the tunnel every 10 s · last 2 min: min 58, max 71 ms`.
  static String tooltip(LatencySample sample) {
    var text =
        'Measured through the tunnel every ${LatencyProbe.interval.inSeconds} s';
    final values = sample.history.whereType<int>().toList();
    if (values.isNotEmpty) {
      values.sort();
      final window =
          LatencyProbe.interval.inSeconds * LatencyProbe.historyLength ~/ 60;
      text += ' · last $window min: min ${values.first}, max ${values.last} ms';
    }
    return text;
  }

  /// `No answer through the tunnel for 2 min` — since the last success, or
  /// since the first failed probe when there never was one.
  static String unreachableDetail(
    LatencySample sample, {
    required DateTime now,
  }) {
    final int seconds;
    final last = sample.lastSuccess;
    if (last != null) {
      final elapsed = now.difference(last).inSeconds;
      seconds = elapsed < 0 ? 0 : elapsed;
    } else {
      seconds = sample.failedInARow * LatencyProbe.interval.inSeconds;
    }
    return 'No answer through the tunnel for ${duration(seconds)}';
  }

  /// `30 s`, `2 min`, `1 h 05 min`.
  static String duration(int seconds) {
    if (seconds < 60) return '$seconds s';
    if (seconds < 3600) return '${seconds ~/ 60} min';
    final minutes = seconds % 3600 ~/ 60;
    return '${seconds ~/ 3600} h ${minutes.toString().padLeft(2, '0')} min';
  }
}
