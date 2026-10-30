import Foundation

/// Builds the config of one bundled `xray` process: a loopback SOCKS5 inbound and a VLESS
/// outbound over XHTTP (docs/design/04-tunnels.md, "VLESS over XHTTP"). Pure function of its
/// input; the output is deterministic (sorted keys) so it can be hashed and golden-tested.
public enum XrayConfigGenerator {
    public static let listenAddress = "127.0.0.1"
    /// Used when the link carries no `fp`; Xray needs a fingerprint for REALITY.
    public static let defaultRealityFingerprint = "chrome"
    public static let defaultMode = "auto"

    /// nil when `meta` is not an XHTTP tunnel — sing-box dials those itself.
    public static func generate(meta: VLESSMeta, uuid: String, port: Int) -> String? {
        guard case .xhttp(let path, let host, let mode, let extra) = meta.transport else {
            return nil
        }
        var xhttp: [String: Any] = ["path": path, "mode": mode ?? defaultMode]
        if let host {
            xhttp["host"] = host
        }
        if let extra, let object = extraObject(extra) {
            xhttp["extra"] = object
        }
        var stream: [String: Any] = [
            "network": "xhttp",
            "security": meta.security.rawValue,
            "xhttpSettings": xhttp,
        ]
        switch meta.security {
        case .none:
            break
        case .tls:
            var tls: [String: Any] = ["serverName": meta.sni ?? meta.server]
            if !meta.alpn.isEmpty {
                tls["alpn"] = meta.alpn
            }
            if let fingerprint = meta.fingerprint {
                tls["fingerprint"] = fingerprint
            }
            stream["tlsSettings"] = tls
        case .reality:
            stream["realitySettings"] = [
                "serverName": meta.sni ?? meta.server,
                "fingerprint": meta.fingerprint ?? defaultRealityFingerprint,
                "password": meta.realityPublicKey ?? "",
                "shortId": meta.realityShortID ?? "",
            ]
        }
        let config: [String: Any] = [
            "log": ["loglevel": "warning", "access": "none"],
            "inbounds": [
                [
                    "listen": listenAddress,
                    "port": port,
                    "protocol": "socks",
                    "settings": ["auth": "noauth", "udp": true, "ip": listenAddress],
                ] as [String: Any]
            ],
            "outbounds": [
                [
                    "protocol": "vless",
                    "settings": [
                        "vnext": [
                            [
                                "address": meta.server,
                                "port": meta.port,
                                "users": [["id": uuid, "encryption": "none"]],
                            ] as [String: Any]
                        ]
                    ],
                    "streamSettings": stream,
                ] as [String: Any]
            ],
        ]
        return JSONText.render(config)
    }

    /// The link's `extra` as a JSON object; the parser only stores objects, so a miss here
    /// means a hand-edited store and the field is dropped rather than sent malformed.
    private static func extraObject(_ extra: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any]
    }
}
