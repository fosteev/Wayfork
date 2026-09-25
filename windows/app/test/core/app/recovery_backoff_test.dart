import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/app/recovery_backoff.dart';

void main() {
  test('slows down, caps and never gives up', () {
    final backoff = RecoveryBackoff();
    expect(backoff.isRecovering, isFalse);
    final delays = [for (var i = 0; i < 8; i++) backoff.nextDelay().inSeconds];
    expect(delays, [5, 15, 30, 60, 120, 300, 300, 300]);
    expect(backoff.failures, 8);
    expect(backoff.isRecovering, isTrue);
  });

  test('a reset starts the streak over', () {
    final backoff = RecoveryBackoff();
    backoff.nextDelay();
    backoff.nextDelay();
    backoff.reset();
    expect(backoff.isRecovering, isFalse);
    expect(backoff.nextDelay(), const Duration(seconds: 5));
  });

  test('takes the delays the tests need', () {
    final backoff = RecoveryBackoff(
      delays: const [Duration(milliseconds: 10), Duration(milliseconds: 20)],
    );
    expect(backoff.nextDelay(), const Duration(milliseconds: 10));
    expect(backoff.nextDelay(), const Duration(milliseconds: 20));
    expect(backoff.nextDelay(), const Duration(milliseconds: 20));
  });
}
