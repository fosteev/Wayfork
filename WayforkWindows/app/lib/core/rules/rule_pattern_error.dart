/// `rule.invalid` reasons (docs/design/02-ux.md, error catalogue).
enum RulePatternError {
  empty,
  invalidHostname,
  tooLong,
  wildcardNotAllowed,
  wildcardRequired,
  notAnApplication,
  invalidIP,
  looksLikeIP,
  reservedRange,
}

final class RulePatternException implements Exception {
  const RulePatternException(this.kind, {this.label});

  final RulePatternError kind;
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is RulePatternException &&
      kind == other.kind &&
      label == other.label;

  @override
  int get hashCode => Object.hash(kind, label);

  @override
  String toString() => label == null ? '$kind' : '$kind: $label';
}
