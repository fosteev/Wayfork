import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// The few `HKEY_CURRENT_USER` reads and writes the app layer needs. The core
/// has its own reader for the Tcpip keys (`core/support/windows_adapters.dart`);
/// this one writes, which the core never does.
abstract final class WindowsRegistry {
  /// A `REG_SZ` value, or null when the key or the value is missing.
  static String? readString(String subKey, String value) {
    final keyName = subKey.toPcwstr();
    final valueName = value.toPcwstr();
    final size = calloc<Uint32>();
    try {
      var result = RegGetValue(
        HKEY_CURRENT_USER,
        keyName,
        valueName,
        RRF_RT_REG_SZ,
        null,
        null,
        size,
      );
      if (result != 0 || size.value == 0) return null;
      final data = calloc<Uint8>(size.value + 2);
      try {
        result = RegGetValue(
          HKEY_CURRENT_USER,
          keyName,
          valueName,
          RRF_RT_REG_SZ,
          null,
          data,
          size,
        );
        if (result != 0) return null;
        return data.cast<Utf16>().toDartString();
      } finally {
        calloc.free(data);
      }
    } finally {
      calloc.free(size);
      free(valueName);
      free(keyName);
    }
  }

  /// A `REG_DWORD` value, or null when the key or the value is missing.
  static int? readDword(String subKey, String value) {
    final keyName = subKey.toPcwstr();
    final valueName = value.toPcwstr();
    final data = calloc<Uint32>();
    final size = calloc<Uint32>();
    try {
      size.value = sizeOf<Uint32>();
      final result = RegGetValue(
        HKEY_CURRENT_USER,
        keyName,
        valueName,
        RRF_RT_REG_DWORD,
        null,
        data.cast<Uint8>(),
        size,
      );
      return result == 0 ? data.value : null;
    } finally {
      calloc.free(size);
      calloc.free(data);
      free(valueName);
      free(keyName);
    }
  }

  /// Writes a `REG_SZ` value, creating the key when it does not exist.
  /// Throws [WindowsRegistryException] with the Win32 code on failure.
  static void writeString(String subKey, String value, String data) {
    final key = _openForWriting(subKey);
    final valueName = value.toPcwstr();
    final buffer = data.toNativeUtf16();
    try {
      final result = RegSetValueEx(
        key,
        valueName,
        REG_SZ,
        buffer.cast<Uint8>(),
        // Bytes, terminator included; `length` counts UTF-16 code units.
        (data.length + 1) * 2,
      );
      if (result != 0) {
        throw WindowsRegistryException('$subKey\\$value', result);
      }
    } finally {
      calloc.free(buffer);
      free(valueName);
      RegCloseKey(key);
    }
  }

  /// Deletes a value; a value that is already gone is not an error.
  static void deleteValue(String subKey, String value) {
    final key = _openForWriting(subKey);
    final valueName = value.toPcwstr();
    try {
      final result = RegDeleteValue(key, valueName);
      if (result != 0 && result != ERROR_FILE_NOT_FOUND) {
        throw WindowsRegistryException('$subKey\\$value', result);
      }
    } finally {
      free(valueName);
      RegCloseKey(key);
    }
  }

  static HKEY _openForWriting(String subKey) {
    final keyName = subKey.toPcwstr();
    final handle = calloc<Pointer>();
    try {
      final result = RegCreateKeyEx(
        HKEY_CURRENT_USER,
        keyName,
        null,
        REG_OPTION_NON_VOLATILE,
        REG_SAM_FLAGS(KEY_SET_VALUE | KEY_QUERY_VALUE),
        null,
        handle,
        null,
      );
      if (result != 0) throw WindowsRegistryException(subKey, result);
      return HKEY(handle.value);
    } finally {
      calloc.free(handle);
      free(keyName);
    }
  }
}

final class WindowsRegistryException implements Exception {
  const WindowsRegistryException(this.path, this.code);

  final String path;
  final int code;

  @override
  String toString() => 'registry error $code on HKEY_CURRENT_USER\\$path';
}
