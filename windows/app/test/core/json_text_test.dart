import 'package:flutter_test/flutter_test.dart';
import 'package:wayfork/core/json_text.dart';

void main() {
  test('renders Foundation-compatible pretty and compact JSON', () {
    final tree = <String, Object?>{
      'logger': 1,
      'logLevel': 2,
      'Zeta': 3,
      'alpha': 4,
      's': 'a"b\\c/d\ne\rf\tg\bh\fi\u0001j é ж',
      'd': 1.5,
      'e': 2.0,
      'neg': -0.25,
      'i': 1194,
      'arr': <Object?>[],
      'o': <String, Object?>{},
      'nested': <String, Object?>{
        'x': <Object?>[1, <Object?>[], <String, Object?>{}],
      },
    };
    const pretty = r'''{
  "alpha" : 4,
  "arr" : [

  ],
  "d" : 1.5,
  "e" : 2,
  "i" : 1194,
  "logger" : 1,
  "logLevel" : 2,
  "neg" : -0.25,
  "nested" : {
    "x" : [
      1,
      [

      ],
      {

      }
    ]
  },
  "o" : {

  },
  "s" : "a\"b\\c/d\ne\rf\tg\bh\fi\u0001j é ж",
  "Zeta" : 3
}''';
    const compact =
        r'{"alpha":4,"arr":[],"d":1.5,"e":2,"i":1194,"logger":1,"logLevel":2,"neg":-0.25,"nested":{"x":[1,[],{}]},"o":{},"s":"a\"b\\c/d\ne\rf\tg\bh\fi\u0001j é ж","Zeta":3}';
    expect(JsonText.render(tree), pretty);
    expect(JsonText.render(tree, pretty: false), compact);
  });

  test('encodes and decodes ISO 8601 dates', () {
    final date = DateTime.utc(2026, 8, 25, 12);
    expect(JsonCoding.encodeDate(date), '2026-08-25T12:00:00Z');
    expect(
      JsonCoding.decodeDate('2026-08-25T14:00:00.250+02:00'),
      DateTime.utc(2026, 8, 25, 12, 0, 0, 250),
    );
  });
}
