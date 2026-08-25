import Foundation

/// Exported by the daemon on `com.wayfork.daemon.xpc`. Every payload is JSON `Data`
/// produced by `XPCCodec` (docs/design/05-daemon.md, "XPC interface").
@objc public protocol WayforkDaemonXPC {
    /// → `DaemonInfo`
    func getInfo(_ reply: @escaping @Sendable (Data) -> Void)
    /// `RuntimePlan` → `ApplyResult`. Returns once reconcile has been initiated and
    /// `sing-box check` passed; progress arrives through `WayforkClientXPC.statusChanged`.
    func apply(_ plan: Data, _ reply: @escaping @Sendable (Data) -> Void)
    /// → `ApplyResult`; returns after every child exited or was killed.
    func stop(_ reply: @escaping @Sendable (Data) -> Void)
    /// → `ApplyResult`; resets backoff and restarts one OpenVPN tunnel.
    func reconnect(tunnelID: String, _ reply: @escaping @Sendable (Data) -> Void)
    /// → `RuntimeStatus`
    func getStatus(_ reply: @escaping @Sendable (Data) -> Void)
    /// Registers the connection's exported `WayforkClientXPC` object for pushes → `ApplyResult`.
    func subscribe(_ reply: @escaping @Sendable (Data) -> Void)
    /// → `DaemonDiagnostics`
    func collectDiagnostics(_ reply: @escaping @Sendable (Data) -> Void)
}

/// Exported by the app on its connection; the daemon pushes into it.
@objc public protocol WayforkClientXPC {
    /// `RuntimeStatus`, on every change (coalesced, 100 ms).
    func statusChanged(_ status: Data)
    /// `[LogLine]`, every 250 ms or 200 lines.
    func logLines(_ batch: Data)
}
