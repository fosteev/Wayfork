import Foundation
import WayforkCore
import WayforkDaemonCore

/// Runs a short-lived helper (`route`, `sing-box check`, `openvpn --version`) to completion
/// and collects its output. No shell anywhere.
enum CommandRunner {
    struct Result: Sendable {
        var exit: ProcessExit
        var lines: [String]
        var output: String { lines.joined(separator: "\n") }
        var succeeded: Bool { exit == .exited(status: 0) }
    }

    static func run(
        _ executable: String, _ arguments: [String], workingDirectory: String? = nil,
        timeout: Duration = .seconds(15)
    ) async throws -> Result {
        let collector = LineCollector()
        let process = try ManagedProcess(
            spec: ProcessSpec(
                executable: executable, arguments: arguments,
                workingDirectory: workingDirectory),
            handlers: ProcessEventHandlers(
                onLine: { _, line in collector.append(line) },
                onExit: { _ in }))
        let exit = await withTaskGroup(of: ProcessExit?.self) { group in
            group.addTask { await process.exit }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            var result: ProcessExit?
            for await candidate in group {
                if let candidate {
                    result = candidate
                    break
                }
                result = await process.terminate(timeout: .seconds(1))
                break
            }
            group.cancelAll()
            return result ?? .signaled(signal: SIGKILL)
        }
        return Result(exit: exit, lines: collector.snapshot())
    }
}

/// Route helper: interface-scoped default routes for OpenVPN tunnels
/// (docs/design/04-tunnels.md, "Interface-scoped default route").
enum RouteHelper {
    static func addScopedDefault(interface: String) async -> String? {
        await run(RouteCommand.addScopedDefault, interface)
    }

    static func deleteScopedDefault(interface: String) async -> String? {
        await run(RouteCommand.deleteScopedDefault, interface)
    }

    /// Interface currently holding the unscoped default route.
    static func defaultInterface() async -> String? {
        guard
            let result = try? await CommandRunner.run(
                RouteCommand.executable, RouteCommand.getDefault)
        else { return nil }
        return RouteCommand.interface(fromGetOutput: result.output)
    }

    /// Interface a packet to `address` would leave through (scoped-route aware).
    static func interface(forAddress address: String) async -> String? {
        guard
            let result = try? await CommandRunner.run(
                RouteCommand.executable, RouteCommand.get(address: address))
        else { return nil }
        return RouteCommand.interface(fromGetOutput: result.output)
    }

    static func routeDescription(forAddress address: String) async -> String {
        (try? await CommandRunner.run(RouteCommand.executable, RouteCommand.get(address: address)))?
            .output ?? "(route -n get \(address) failed)"
    }

    static func defaultRouteDescription() async -> String {
        (try? await CommandRunner.run(RouteCommand.executable, RouteCommand.getDefault))?.output
            ?? "(route -n get default failed)"
    }

    /// Returns the error output on failure, nil on success.
    private static func run(
        _ command: (String) throws(RouteCommand.Error) -> [String], _ interface: String
    ) async -> String? {
        let arguments: [String]
        do {
            arguments = try command(interface)
        } catch {
            return "invalid interface \(interface)"
        }
        guard let result = try? await CommandRunner.run(RouteCommand.executable, arguments) else {
            return "could not run \(RouteCommand.executable)"
        }
        return result.succeeded ? nil : result.output
    }
}
