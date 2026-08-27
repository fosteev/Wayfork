/// RFC 3492 Punycode encoder, used to turn IDN labels into their `xn--` form.
abstract final class Punycode {
  static const _base = 36;
  static const _tMin = 1;
  static const _tMax = 26;
  static const _skew = 38;
  static const _damp = 700;
  static const _initialBias = 72;
  static const _initialN = 128;
  static const _maxInt64 = 0x7fffffffffffffff;

  /// Encodes one label. Returns null on overflow (labels far beyond DNS limits).
  static String? encode(String label) {
    final input = label.runes.toList();
    final output = <int>[...input.where((value) => value < 0x80)];
    final basicCount = output.length;
    var handled = basicCount;
    if (basicCount > 0) output.add(0x2d);

    var n = _initialN;
    var delta = 0;
    var bias = _initialBias;
    while (handled < input.length) {
      int? m;
      for (final value in input) {
        if (value >= n && (m == null || value < m)) m = value;
      }
      if (m == null) return null;
      final difference = m - n;
      if (difference > _maxInt64 ~/ (handled + 1)) return null;
      final product = difference * (handled + 1);
      if (delta > _maxInt64 - product) return null;
      delta += product;
      n = m;
      for (final value in input) {
        if (value < n) {
          if (delta == _maxInt64) return null;
          delta++;
        }
        if (value != n) continue;
        var q = delta;
        var k = _base;
        while (true) {
          final t = k <= bias ? _tMin : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) break;
          output.add(_digit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
          k += _base;
        }
        output.add(_digit(q));
        bias = _adapt(delta, handled + 1, handled == basicCount);
        delta = 0;
        handled++;
      }
      if (delta == _maxInt64 || n == _maxInt64) return null;
      delta++;
      n++;
    }
    return String.fromCharCodes(output);
  }

  /// `xn--` form of a label, or the label itself when it is pure ASCII.
  static String? toASCII(String label) {
    if (label.runes.every((value) => value < 0x80)) return label;
    final encoded = encode(label);
    return encoded == null ? null : 'xn--$encoded';
  }

  static int _digit(int value) => value < 26 ? 97 + value : 22 + value;

  static int _adapt(int value, int numPoints, bool firstTime) {
    var delta = firstTime ? value ~/ _damp : value ~/ 2;
    delta += delta ~/ numPoints;
    var k = 0;
    while (delta > ((_base - _tMin) * _tMax) ~/ 2) {
      delta ~/= _base - _tMin;
      k += _base;
    }
    return k + (_base - _tMin + 1) * delta ~/ (delta + _skew);
  }
}
