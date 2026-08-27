import 'dart:convert';

import 'package:crypto/crypto.dart';

abstract final class Hashing {
  static String sha256Hex(String value) => sha256HexBytes(utf8.encode(value));

  static String sha256HexBytes(List<int> value) =>
      sha256.convert(value).toString();
}
