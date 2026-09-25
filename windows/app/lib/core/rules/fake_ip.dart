import 'package:wayfork/core/rules/rule_pattern.dart';
import 'package:wayfork/core/singbox/constants.dart';
import 'package:wayfork/core/support/ipv4_prefix.dart';

/// Fake IPs are names in disguise. The index learns their names from sing-box
/// DNS log lines so pasted fake addresses can become useful domain rules.
final class FakeIPIndex {
  static final IPv4Prefix range = IPv4Prefix.parse(
    SingBoxConstants.fakeIPv4Range,
  )!;
  static const capacity = 10000;
  static final RegExp _answer = RegExp(
    r'dns: (?:exchanged|cached) A (\S+?)\.? \d+ IN A (\d{1,3}(?:\.\d{1,3}){3})\b',
  );

  final Map<String, String> _names = {};

  int get count => _names.length;

  /// Whether [text] is one host address inside the fake range.
  static bool isFakeIP(String text) {
    final prefix = IPv4Prefix.parse(text.trim());
    return prefix != null && prefix.isHost && range.contains(prefix);
  }

  /// Records a fake-IP answer. Other log lines are ignored.
  bool ingest(String message) {
    if (!message.contains(' IN A 198.1')) return false;
    final match = _answer.firstMatch(message);
    if (match == null) return false;
    final name = match.group(1)!.toLowerCase();
    final address = match.group(2)!;
    if (name.isEmpty || !isFakeIP(address)) return false;
    if (_names.length >= capacity) _names.clear();
    _names[address] = name;
    return true;
  }

  String? nameFor(String address) => _names[address.trim()];
}

sealed class FakeIPTranslation {
  const FakeIPTranslation();
  const factory FakeIPTranslation.pattern(String pattern, String name) =
      FakeIPPatternTranslation;
  const factory FakeIPTranslation.unknown(String address) =
      FakeIPUnknownTranslation;
}

final class FakeIPPatternTranslation extends FakeIPTranslation {
  const FakeIPPatternTranslation(this.pattern, this.name);
  final String pattern;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is FakeIPPatternTranslation &&
      pattern == other.pattern &&
      name == other.name;
  @override
  int get hashCode => Object.hash(pattern, name);
}

final class FakeIPUnknownTranslation extends FakeIPTranslation {
  const FakeIPUnknownTranslation(this.address);
  final String address;

  @override
  bool operator ==(Object other) =>
      other is FakeIPUnknownTranslation && address == other.address;
  @override
  int get hashCode => address.hashCode;
}

abstract final class FakeIP {
  static FakeIPTranslation? translate(String input, FakeIPIndex index) {
    final address = input.trim();
    if (!FakeIPIndex.isFakeIP(address)) return null;
    final name = index.nameFor(address);
    if (name == null) return FakeIPTranslation.unknown(address);
    return FakeIPTranslation.pattern(
      RulePattern.wildcardForSiblings(name),
      name,
    );
  }

  static String messageForUnknown(String address) =>
      '$address is a fake IP Wayfork issued to a name it has not logged yet — '
      'add the domain instead';
}
