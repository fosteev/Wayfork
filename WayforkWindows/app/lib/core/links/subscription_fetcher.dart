import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wayfork/core/links/proxy_link_parser.dart';
import 'package:wayfork/core/version.dart';

/// Fetches a subscription body for `SubscriptionDecoder`
/// (docs/design/04-tunnels.md, "Subscriptions"): https only, redirects
/// followed, 15 s, 1 MiB, a neutral User-Agent so converters answer with raw
/// links rather than Clash YAML. The URL is a bearer token — callers must not
/// log or store it; this class never does.
abstract final class SubscriptionFetcher {
  static const timeout = Duration(seconds: 15);
  static const maxBodyBytes = 1048576;

  static Future<String> fetch(Uri url, {HttpClient? client}) async {
    if (url.scheme.toLowerCase() != 'https') {
      throw const ProxyLinkException(
        ProxyLinkError.unsupported,
        'subscriptions must use https',
      );
    }
    final http = client ?? HttpClient();
    http.connectionTimeout = timeout;
    http.userAgent = 'Wayfork/${WayforkVersion.app}';
    try {
      final HttpClientResponse response;
      final List<int> bytes;
      try {
        final request = await http.getUrl(url).timeout(timeout);
        request.headers.set(HttpHeaders.acceptHeader, 'text/plain, */*;q=0.1');
        response = await request.close().timeout(timeout);
        bytes = await response
            .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
            .timeout(timeout);
      } on Object catch (error) {
        throw ProxyLinkException(ProxyLinkError.invalid, _describe(error));
      }
      final finalUrl = response.redirects.isEmpty
          ? url
          : response.redirects.last.location;
      if (finalUrl.scheme.toLowerCase() != 'https' && finalUrl.hasScheme) {
        throw const ProxyLinkException(
          ProxyLinkError.unsupported,
          'subscription redirected away from https',
        );
      }
      if (response.statusCode < 200 || response.statusCode > 299) {
        throw ProxyLinkException(
          ProxyLinkError.invalid,
          'server answered ${response.statusCode}',
        );
      }
      if (bytes.length > maxBodyBytes) {
        throw const ProxyLinkException(
          ProxyLinkError.invalid,
          'subscription is larger than 1 MiB',
        );
      }
      try {
        return utf8.decode(bytes);
      } on FormatException {
        throw const ProxyLinkException(
          ProxyLinkError.invalid,
          'subscription is not text',
        );
      }
    } finally {
      if (client == null) http.close(force: true);
    }
  }

  static String _describe(Object error) => switch (error) {
    TimeoutException() => 'timed out',
    SocketException(:final message) => message,
    HttpException(:final message) => message,
    _ => '$error',
  };
}
