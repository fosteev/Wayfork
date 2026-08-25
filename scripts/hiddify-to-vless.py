#!/usr/bin/env python3
"""Convert Hiddify's stored profiles (sing-box outbound JSON) into vless:// URIs.

Usage: scripts/hiddify-to-vless.py [hiddify-configs-dir] > local/vless/hiddify.txt

Default input: ~/Library/Application Support/app.hiddify.com/configs. Every VLESS outbound
found (single profiles and subscription selectors alike) becomes one line; transports that
Wayfork does not support yet (xhttp, http/h2) are written as commented-out lines so nothing
is silently lost. Output contains UUIDs — keep it in the git-ignored local/ folder.
"""

import glob
import json
import os
import re
import sys
from urllib.parse import quote

SUPPORTED_TRANSPORTS = {"tcp", "ws", "grpc"}


def to_uri(outbound):
    tls = outbound.get("tls") or {}
    params = []
    if tls.get("enabled"):
        reality = tls.get("reality") or {}
        params.append(("security", "reality" if reality.get("enabled") else "tls"))
        if tls.get("server_name"):
            params.append(("sni", tls["server_name"]))
        utls = tls.get("utls") or {}
        if utls.get("enabled") and utls.get("fingerprint"):
            params.append(("fp", utls["fingerprint"]))
        if tls.get("alpn"):
            params.append(("alpn", ",".join(tls["alpn"])))
        if reality.get("enabled"):
            params.append(("pbk", reality.get("public_key", "")))
            if reality.get("short_id"):
                params.append(("sid", reality["short_id"]))
        if tls.get("insecure"):
            params.append(("insecure", "1"))
    else:
        params.append(("security", "none"))
    if outbound.get("flow"):
        params.append(("flow", outbound["flow"]))
    transport = outbound.get("transport") or {}
    kind = transport.get("type", "tcp")
    params.append(("type", kind))
    if kind == "ws":
        params.append(("path", transport.get("path", "/")))
        host = (transport.get("headers") or {}).get("Host")
        if host:
            params.append(("host", host))
    elif kind == "grpc":
        params.append(("serviceName", transport.get("service_name", "")))
    elif kind in ("http", "xhttp", "httpupgrade"):
        if transport.get("path"):
            params.append(("path", transport["path"]))
        hosts = transport.get("host")
        if hosts:
            params.append(("host", hosts[0] if isinstance(hosts, list) else hosts))
    name = outbound.get("tag", "").split("§")[0].strip() or outbound["server"]
    query = "&".join(f"{k}={quote(str(v), safe='')}" for k, v in params)
    uri = f"vless://{outbound['uuid']}@{outbound['server']}:{outbound['server_port']}?{query}#{quote(name)}"
    return uri, kind


def main():
    directory = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.path.expanduser("~/Library/Application Support/app.hiddify.com/configs")
    )
    seen = set()
    supported = skipped = 0
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        try:
            with open(path, encoding="utf-8") as handle:
                document = json.load(handle)
        except (OSError, ValueError):
            continue
        for outbound in document.get("outbounds", []):
            if outbound.get("type") != "vless" or not outbound.get("uuid"):
                continue
            uri, kind = to_uri(outbound)
            if uri in seen:
                continue
            seen.add(uri)
            if kind in SUPPORTED_TRANSPORTS:
                print(uri)
                supported += 1
            else:
                print(f"# unsupported transport {kind}: {uri}")
                skipped += 1
    print(f"converted {supported} profiles, {skipped} unsupported", file=sys.stderr)


if __name__ == "__main__":
    main()
