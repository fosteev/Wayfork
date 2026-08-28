/// A byte stream to the service (docs/design/08-windows.md, "IPC"): the named
/// pipe in production, an in-memory pair in tests.
abstract interface class ServiceTransport {
  /// Bytes from the service; done when the service closes the connection,
  /// with an error when the transport breaks.
  Stream<List<int>> get input;

  /// Writes one frame; frames are delivered in call order.
  Future<void> write(List<int> bytes);

  Future<void> close();
}

/// Opens a fresh transport; throws [ServiceUnavailableException] when nothing
/// listens (service not installed or not running).
typedef ServiceTransportConnector = Future<ServiceTransport> Function();

/// The pipe does not exist: the service is not installed or not running.
final class ServiceUnavailableException implements Exception {
  const ServiceUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'ServiceUnavailableException: $message';
}

/// The transport failed after connecting.
final class ServiceTransportException implements Exception {
  const ServiceTransportException(this.message);

  final String message;

  @override
  String toString() => 'ServiceTransportException: $message';
}
