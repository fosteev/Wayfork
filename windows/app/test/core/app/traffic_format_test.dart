import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/traffic_format.dart';
import 'package:wayfork/core/ipc/payloads.dart';

void main() {
  test('bytes use decimal units with fixed digits', () {
    expect(TrafficFormat.bytes(0), '0 B');
    expect(TrafficFormat.bytes(999), '999 B');
    expect(TrafficFormat.bytes(1000), '1.0 KB');
    expect(TrafficFormat.bytes(1234), '1.2 KB');
    expect(TrafficFormat.bytes(9949), '9.9 KB');
    expect(TrafficFormat.bytes(9950), '10 KB');
    expect(TrafficFormat.bytes(85000), '85 KB');
    expect(TrafficFormat.bytes(123456), '123 KB');
    expect(TrafficFormat.bytes(999400), '999 KB');
    expect(TrafficFormat.bytes(999500), '1.0 MB');
    expect(TrafficFormat.bytes(1200000), '1.2 MB');
    expect(TrafficFormat.bytes(12000000), '12 MB');
    expect(TrafficFormat.bytes(88000000), '88 MB');
    expect(TrafficFormat.bytes(1200000000), '1.2 GB');
    expect(TrafficFormat.bytes(3500000000000), '3.5 TB');
    // Units stop at PB; a negative count reads as zero.
    expect(TrafficFormat.bytes(9223372036854775807), '9223 PB');
    expect(TrafficFormat.bytes(-1), '0 B');
  });

  test('rate and labels', () {
    expect(TrafficFormat.rate(0), '0 B/s');
    expect(TrafficFormat.rate(1234.4), '1.2 KB/s');
    expect(TrafficFormat.rate(-5), '0 B/s');
    expect(TrafficFormat.rate(double.nan), '0 B/s');
    expect(TrafficFormat.rate(double.infinity), '0 B/s');
    const counters = TrafficCounters(
      downBytesPerSecond: 1200000,
      upBytesPerSecond: 85000,
      downTotal: 1200000000,
      upTotal: 88000000,
      connections: 14,
    );
    expect(TrafficFormat.rateLabel(counters), '↓ 1.2 MB/s ↑ 85 KB/s');
    expect(TrafficFormat.rateLabel(null), '↓ — ↑ —');
    expect(
      TrafficFormat.tooltip(counters),
      'Since Turn On: ↓ 1.2 GB ↑ 88 MB · 14 connections',
    );
    expect(
      TrafficFormat.tooltip(const TrafficCounters(connections: 1)),
      'Since Turn On: ↓ 0 B ↑ 0 B · 1 connection',
    );
    expect(TrafficFormat.directRowTitle(hasDefaultTunnel: false), 'Direct');
    expect(
      TrafficFormat.directRowTitle(hasDefaultTunnel: true),
      'Direct · exceptions',
    );
    expect(
      TrafficFormat.staleTooltip,
      'No traffic sample in the last 3 seconds',
    );
    expect(
      TrafficFormat.oneWayUDPHint(1),
      '1 UDP connection sent data but received nothing for 10 s — the server '
      'may be dropping UDP',
    );
    expect(TrafficFormat.oneWayUDPHint(3), startsWith('3 UDP connections '));
    expect(TrafficCounters.zero.isIdle, isTrue);
    expect(counters.isIdle, isFalse);
  });
}
