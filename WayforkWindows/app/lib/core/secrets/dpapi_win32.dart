import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:wayfork/core/secrets/dpapi_secret_store.dart';
import 'package:wayfork/core/secrets/secret_store.dart';
import 'package:win32/win32.dart';

final class DpapiProtector implements DataProtector {
  static const _cryptProtectUiForbidden = 0x1;

  @override
  Uint8List protect(Uint8List plain) => _transform(plain, protect: true);

  @override
  Uint8List unprotect(Uint8List blob) => _transform(blob, protect: false);

  Uint8List _transform(Uint8List input, {required bool protect}) {
    final inputBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outputBlob = calloc<CRYPT_INTEGER_BLOB>();
    final inputBytes = calloc<Uint8>(input.length);
    inputBytes.asTypedList(input.length).setAll(0, input);
    inputBlob.ref
      ..cbData = input.length
      ..pbData = inputBytes;

    final description = protect ? 'Wayfork'.toPcwstr() : null;
    try {
      final result = protect
          ? CryptProtectData(
              inputBlob,
              description,
              null,
              null,
              _cryptProtectUiForbidden,
              outputBlob,
            )
          : CryptUnprotectData(
              inputBlob,
              null,
              null,
              null,
              _cryptProtectUiForbidden,
              outputBlob,
            );
      if (!result.value) {
        throw SecretStoreException(
          kind: SecretStoreError.dpapi,
          status: result.error.code,
        );
      }
      try {
        return Uint8List.fromList(
          outputBlob.ref.pbData.asTypedList(outputBlob.ref.cbData),
        );
      } finally {
        LocalFree(HLOCAL(outputBlob.ref.pbData.cast()));
      }
    } finally {
      if (description != null) free(description);
      free(inputBytes);
      free(inputBlob);
      free(outputBlob);
    }
  }
}
