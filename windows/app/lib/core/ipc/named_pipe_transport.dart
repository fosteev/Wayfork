import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:wayfork/core/ipc/service_transport.dart';
import 'package:win32/win32.dart';

/// The named pipe the service listens on (docs/design/08-windows.md, "IPC").
const String wayforkPipeName = r'\\.\pipe\wayfork';

/// [ServiceTransport] over a Win32 named pipe opened with
/// `FILE_FLAG_OVERLAPPED` on the client side too. A synchronous handle
/// serialises reads and writes (the service-side lesson of WM2), so the reads
/// run in a helper isolate on their own OVERLAPPED/event while writes complete
/// on the caller's isolate; `CancelIoEx` unblocks the reader on close.
final class NamedPipeTransport implements ServiceTransport {
  NamedPipeTransport._(this._handle, this._input, this._readerDone);

  static const _readBufferBytes = 64 * 1024;

  /// Opens the pipe. `ERROR_FILE_NOT_FOUND` becomes
  /// [ServiceUnavailableException]; `ERROR_PIPE_BUSY` (every instance taken)
  /// is retried until [busyTimeout] elapses.
  static Future<NamedPipeTransport> connect({
    String name = wayforkPipeName,
    Duration busyTimeout = const Duration(seconds: 2),
  }) async {
    if (!Platform.isWindows) {
      throw const ServiceUnavailableException(
        'named pipes exist on Windows only',
      );
    }
    final handle = await _openWithRetry(name, busyTimeout);

    final input = StreamController<List<int>>();
    final readerReady = Completer<void>();
    final readerDone = Completer<int>();
    final port = ReceivePort();
    port.listen((message) {
      if (message is Uint8List) {
        if (!input.isClosed) input.add(message);
      } else if (message == _readerReadyMessage) {
        if (!readerReady.isCompleted) readerReady.complete();
      } else if (message is int) {
        // The reader stopped: 0 = clean end of stream, else a Win32 error code.
        port.close();
        if (!readerDone.isCompleted) readerDone.complete(message);
        if (input.isClosed) return;
        if (message == 0 ||
            message == ERROR_BROKEN_PIPE ||
            message == ERROR_PIPE_NOT_CONNECTED ||
            message == ERROR_OPERATION_ABORTED) {
          input.close();
        } else {
          input.addError(
            ServiceTransportException(
              'read failed: ${_describeError(message)}',
            ),
          );
          input.close();
        }
      }
    });
    await Isolate.spawn(_readLoop, (
      handle.address,
      port.sendPort,
    ), debugName: 'wayfork-pipe-reader');
    // Until the reader has issued its first ReadFile there is nothing for
    // CancelIoEx to cancel, so a close() racing a fresh isolate would wait
    // for the reader timeout instead.
    await readerReady.future;
    return NamedPipeTransport._(handle, input, readerDone);
  }

  static const _readerReadyMessage = 'ready';

  final HANDLE _handle;
  final StreamController<List<int>> _input;
  final Completer<int> _readerDone;
  Future<void> _writes = Future.value();
  bool _closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(List<int> bytes) {
    if (_closed) {
      return Future.error(const ServiceTransportException('pipe closed'));
    }
    // Writes are serialised so frames never interleave; each one blocks the
    // caller only for the transfer itself (the service reads continuously).
    final pending = _writes.then((_) => _writeNow(bytes));
    _writes = pending.then((_) {}, onError: (_) {});
    return pending;
  }

  Future<void> _writeNow(List<int> bytes) async {
    if (_closed) throw const ServiceTransportException('pipe closed');
    final buffer = calloc<Uint8>(bytes.length);
    final overlapped = calloc<OVERLAPPED>();
    final transferred = calloc<Uint32>();
    final event = CreateEvent(null, true, false, null).value;
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      overlapped.ref.hEvent = event;
      var offset = 0;
      while (offset < bytes.length) {
        final started = WriteFile(
          _handle,
          buffer + offset,
          bytes.length - offset,
          null,
          overlapped,
        );
        if (!started.value && started.error != ERROR_IO_PENDING) {
          throw ServiceTransportException(
            'write failed: ${_describeError(started.error)}',
          );
        }
        final finished = GetOverlappedResult(
          _handle,
          overlapped,
          transferred,
          true,
        );
        if (!finished.value) {
          throw ServiceTransportException(
            'write failed: ${_describeError(finished.error)}',
          );
        }
        offset += transferred.value;
      }
    } finally {
      CloseHandle(event);
      calloc.free(transferred);
      calloc.free(overlapped);
      calloc.free(buffer);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Abort the pending read and wait for the reader isolate to let go of the
    // handle before closing it. CancelIoEx only reaches an I/O that is already
    // pending, so it is repeated until the reader reports back (bounded).
    for (var attempt = 0; attempt < 40 && !_readerDone.isCompleted; attempt++) {
      CancelIoEx(_handle, null);
      await _readerDone.future.timeout(
        const Duration(milliseconds: 50),
        onTimeout: () => -1,
      );
    }
    CloseHandle(_handle);
    // Not awaited: a controller nobody listens to completes its close future
    // only once a listener appears.
    if (!_input.isClosed) unawaited(_input.close());
  }

  static Future<HANDLE> _openWithRetry(
    String name,
    Duration busyTimeout,
  ) async {
    final deadline = DateTime.now().add(busyTimeout);
    while (true) {
      final result = _open(name);
      if (result.value != INVALID_HANDLE_VALUE) return result.value;
      final error = result.error;
      if (error == ERROR_FILE_NOT_FOUND) {
        throw ServiceUnavailableException('$name does not exist');
      }
      if (error == ERROR_PIPE_BUSY && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        continue;
      }
      throw ServiceTransportException(
        'cannot open $name: ${_describeError(error)}',
      );
    }
  }

  static Win32Result<HANDLE> _open(String name) {
    final path = name.toPcwstr();
    try {
      return CreateFile(
        path,
        GENERIC_READ | GENERIC_WRITE,
        const FILE_SHARE_MODE(0),
        null,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED,
        null,
      );
    } finally {
      free(path);
    }
  }

  static String _describeError(int code) => 'Win32 error $code';
}

/// Runs in the reader isolate: overlapped reads until the pipe ends or the
/// main isolate cancels the I/O; every chunk is posted to the main isolate as
/// a fresh [Uint8List], then the exit code (0 = clean end).
void _readLoop((int, SendPort) args) {
  final (address, port) = args;
  final handle = HANDLE(Pointer.fromAddress(address));
  final buffer = calloc<Uint8>(NamedPipeTransport._readBufferBytes);
  final overlapped = calloc<OVERLAPPED>();
  final transferred = calloc<Uint32>();
  final event = CreateEvent(null, true, false, null).value;
  var exit = 0;
  try {
    port.send(NamedPipeTransport._readerReadyMessage);
    while (true) {
      overlapped.ref
        ..Internal = 0
        ..InternalHigh = 0
        ..hEvent = event;
      final started = ReadFile(
        handle,
        buffer,
        NamedPipeTransport._readBufferBytes,
        null,
        overlapped,
      );
      if (!started.value && started.error != ERROR_IO_PENDING) {
        exit = started.error;
        break;
      }
      final finished = GetOverlappedResult(
        handle,
        overlapped,
        transferred,
        true,
      );
      if (!finished.value) {
        exit = finished.error;
        break;
      }
      final count = transferred.value;
      if (count == 0) continue;
      port.send(Uint8List.fromList(buffer.asTypedList(count)));
    }
  } finally {
    CloseHandle(event);
    calloc.free(transferred);
    calloc.free(overlapped);
    calloc.free(buffer);
    port.send(exit);
  }
}
