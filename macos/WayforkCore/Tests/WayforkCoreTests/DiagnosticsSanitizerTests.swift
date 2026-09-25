import Foundation
import Testing

@testable import WayforkCore

@Test func sanitizesStoreAndSingBoxDocuments() throws {
    let input = #"""
        {
          "tunnels": [
            {"id": "00000000-0000-4000-8000-000000000001",
             "kind": {"openVPN": {"remotes": [{"host": "example.com"}]}},
             "secrets": {"ovpn": "config", "password": "secret"}},
            {"kind": {"vless": {"server": "example.com", "realityPublicKey": "key"}},
             "uuid": "00000000-0000-4000-8000-000000000001"}
          ],
          "rules": [{"id": "rule-id", "tunnelID": "00000000-0000-4000-8000-000000000001"}],
          "outbounds": [{"server": "example.com", "tls": {
            "server_name": "example.com", "reality": {"public_key": "key", "short_id": "id"}},
            "transport": {"headers": {"Host": "secondary.example.com"}}}],
          "route": {"rules": [{"process_path": "/Users/developer/Applications/Browser.app"}]},
          "dns": {"servers": [{"server": "10.8.0.1"}, {"server": "172.16.0.1"},
            {"server": "192.168.1.1"}, {"server": "127.0.0.1"},
            {"server": "100.64.0.1"}, {"server": "fc00::1"}, {"server": "::1"}]},
          "certificate": "prefix -----BEGIN CERTIFICATE----- suffix"
        }
        """#

    let json = try decodedObject(DiagnosticsSanitizer.sanitizeJSON(input))
    let tunnels = json["tunnels"] as! [[String: Any]]
    let openVPN = (tunnels[0]["kind"] as! [String: Any])["openVPN"] as! [String: Any]
    let remote = (openVPN["remotes"] as! [[String: Any]])[0]
    let vless = (tunnels[1]["kind"] as! [String: Any])["vless"] as! [String: Any]
    let outbound = (json["outbounds"] as! [[String: Any]])[0]
    let tls = outbound["tls"] as! [String: Any]
    let reality = tls["reality"] as! [String: Any]
    let headers = (outbound["transport"] as! [String: Any])["headers"] as! [String: Any]
    let rule = ((json["route"] as! [String: Any])["rules"] as! [[String: Any]])[0]
    let dns = (json["dns"] as! [String: Any])["servers"] as! [[String: Any]]
    let rules = json["rules"] as! [[String: Any]]

    #expect(remote["host"] as? String == "server-1")
    #expect(vless["server"] as? String == "server-1")
    #expect(outbound["server"] as? String == "server-1")
    #expect(tls["server_name"] as? String == "server-1")
    #expect(headers["Host"] as? String == "server-2")
    #expect(tunnels[0]["secrets"] as? String == "<redacted>")
    #expect(tunnels[1]["uuid"] as? String == "<redacted>")
    #expect(vless["realityPublicKey"] as? String == "<redacted>")
    #expect(reality["public_key"] as? String == "<redacted>")
    #expect(reality["short_id"] as? String == "<redacted>")
    #expect(tunnels[0]["id"] as? String == "00000000-0000-4000-8000-000000000001")
    #expect(rules[0]["id"] as? String == "rule-id")
    #expect(rules[0]["tunnelID"] as? String == "00000000-0000-4000-8000-000000000001")
    #expect(rule["process_path"] as? String == "~/Applications/Browser.app")
    #expect(
        dns.compactMap { $0["server"] as? String } == [
            "10.8.0.1", "172.16.0.1", "192.168.1.1", "127.0.0.1", "100.64.0.1",
            "fc00::1", "::1",
        ])
    #expect(json["certificate"] as? String == "<redacted>")
}

@Test func optionallyKeepsAddressesButAlwaysRedactsSecrets() throws {
    let input = #"{"server":"example.com","sni":"example.com","password":"secret"}"#
    let output = try DiagnosticsSanitizer.sanitizeJSON(
        input, options: SanitizerOptions(includeServerAddresses: true))
    let json = try decodedObject(output)
    #expect(json["server"] as? String == "example.com")
    #expect(json["sni"] as? String == "example.com")
    #expect(json["password"] as? String == "<redacted>")
}

@Test func sanitizerOutputFormattingAndInvalidInput() throws {
    let output = try DiagnosticsSanitizer.sanitizeJSON(#"{"z":"/tmp/file","a":true}"#)
    #expect(output == "{\n  \"a\" : true,\n  \"z\" : \"/tmp/file\"\n}")
    #expect(throws: (any Error).self) { try DiagnosticsSanitizer.sanitizeJSON("not JSON") }
}

private func decodedObject(_ text: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}
