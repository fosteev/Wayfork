import Foundation

/// Fetches a subscription body for `SubscriptionDecoder` (docs/design/04-tunnels.md,
/// "Subscriptions"): https only, redirects followed, 15 s, 1 MiB, a neutral User-Agent so
/// converters answer with raw links rather than Clash YAML. The URL is a bearer token —
/// callers must not log or store it; this type never does.
public enum SubscriptionFetcher {
    public static let timeout: TimeInterval = 15
    public static let maxBodyBytes = 1_048_576

    public static func fetch(_ url: URL, session: URLSession = .shared) async throws -> String {
        guard url.scheme?.lowercased() == "https" else {
            throw ProxyLinkError.unsupported("subscriptions must use https")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Wayfork/\(WayforkCore.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, */*;q=0.1", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProxyLinkError.invalid(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProxyLinkError.invalid("no HTTP response")
        }
        guard http.url?.scheme?.lowercased() == "https" else {
            throw ProxyLinkError.unsupported("subscription redirected away from https")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProxyLinkError.invalid("server answered \(http.statusCode)")
        }
        guard data.count <= maxBodyBytes else {
            throw ProxyLinkError.invalid("subscription is larger than 1 MiB")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw ProxyLinkError.invalid("subscription is not text")
        }
        return body
    }
}
