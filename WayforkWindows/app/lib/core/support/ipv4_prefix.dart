final class IPv4Prefix {
  IPv4Prefix(int address, int bits)
    : bits = RangeError.checkValueInInterval(bits, 0, 32, 'bits'),
      address = address & _mask(bits);

  final int address;
  final int bits;

  static IPv4Prefix? parse(String text) {
    final slash = text.indexOf('/');
    if (slash != -1 && text.indexOf('/', slash + 1) != -1) return null;
    final addressText = slash == -1 ? text : text.substring(0, slash);
    final bitsText = slash == -1 ? null : text.substring(slash + 1);
    if (bitsText != null &&
        (!_plainDigits(bitsText) || int.parse(bitsText) > 32)) {
      return null;
    }
    final parts = addressText.split('.');
    if (parts.length != 4) return null;
    var address = 0;
    for (final part in parts) {
      if (!_plainDigits(part) ||
          part.length > 3 ||
          (part.length > 1 && part.startsWith('0'))) {
        return null;
      }
      final octet = int.parse(part);
      if (octet > 255) return null;
      address = (address << 8) | octet;
    }
    return IPv4Prefix(address, bitsText == null ? 32 : int.parse(bitsText));
  }

  static int _mask(int bits) =>
      bits == 0 ? 0 : (0xffffffff << (32 - bits)) & 0xffffffff;

  bool get isHost => bits == 32;

  bool contains(IPv4Prefix other) =>
      other.bits >= bits && (other.address & _mask(bits)) == address;

  bool overlaps(IPv4Prefix other) => contains(other) || other.contains(this);

  List<IPv4Prefix> subtracting(IPv4Prefix inner) {
    if (!contains(inner)) return [this];
    if (inner.bits <= bits) return const [];
    final result = <IPv4Prefix>[];
    for (var depth = bits + 1; depth <= inner.bits; depth++) {
      result.add(IPv4Prefix(inner.address ^ (1 << (32 - depth)), depth));
    }
    result.sort((a, b) => a.address.compareTo(b.address));
    return result;
  }

  List<IPv4Prefix> subtractingAll(Iterable<IPv4Prefix> inners) {
    var result = <IPv4Prefix>[this];
    for (final inner in inners) {
      result = [for (final prefix in result) ...prefix.subtracting(inner)];
    }
    result.sort((a, b) => a.address.compareTo(b.address));
    return result;
  }

  String get _dotted =>
      '${address >> 24}.${(address >> 16) & 0xff}.${(address >> 8) & 0xff}.${address & 0xff}';

  String get canonical => isHost ? _dotted : toString();

  @override
  String toString() => '$_dotted/$bits';

  @override
  bool operator ==(Object other) =>
      other is IPv4Prefix && address == other.address && bits == other.bits;

  @override
  int get hashCode => Object.hash(address, bits);
}

bool _plainDigits(String value) {
  if (value.isEmpty) return false;
  for (final code in value.codeUnits) {
    if (code < 0x30 || code > 0x39) return false;
  }
  return true;
}
