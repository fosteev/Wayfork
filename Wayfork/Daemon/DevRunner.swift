import Darwin
import Foundation
import WayforkCore
import WayforkDaemonCore

/// `WayforkDaemon --dev-apply <plan.json>`: run the supervisor from a terminal as root,
/// without launchd or the app. Applies the plan, re-applies whenever the file changes,
/// prints status and log lines to stderr, stops everything on Ctrl-C.
enum DevRunner {
    static func run(planPath: String, supervisor: Supervisor, hub: ClientHub) -> Never {
        let printer = ConsoleClient()
        let box = ClientProxy(proxy: printer, connectionID: ObjectIdentifier(printer))
        let stopSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        stopSignal.setEventHandler {
            Task {
                _ = await supervisor.stop()
                exit(0)
            }
        }
        stopSignal.resume()

        Task {
            await hub.start()
            await supervisor.bootstrap()
            await hub.subscribe(box)
            var lastModified: Date?
            while true {
                let attributes = try? FileManager.default.attributesOfItem(atPath: planPath)
                let modified = attributes?[.modificationDate] as? Date
                if attributes == nil, lastModified == nil {
                    printer.print("waiting for \(planPath)")
                    lastModified = .distantPast
                }
                if let modified, modified != lastModified {
                    lastModified = modified
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: planPath))
                        let plan = try XPCCodec.decode(RuntimePlan.self, from: data)
                        printer.print("apply \(planPath) (planHash \(plan.planHash.prefix(12)))")
                        let result = await supervisor.apply(plan)
                        printer.print("apply → \(result)")
                    } catch {
                        printer.print("cannot read plan: \(error)")
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        dispatchMain()
    }
}

/// Stand-in for the app's `WayforkClientXPC` object: prints pushes to stderr.
final class ConsoleClient: NSObject, WayforkClientXPC, Sendable {
    func statusChanged(_ status: Data) {
        guard let status = try? XPCCodec.decode(RuntimeStatus.self, from: status) else { return }
        var lines = ["status: engine=\(status.engine)"]
        for (id, state) in status.tunnels.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(id.prefix(8)) \(state)")
        }
        for (id, servers) in status.discoveredDNS.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(id.prefix(8)) dns=\(servers)")
        }
        print(lines.joined(separator: "\n"))
    }

    func logLines(_ batch: Data) {
        guard let lines = try? XPCCodec.decode([LogLine].self, from: batch) else { return }
        for line in lines {
            print("[\(line.source)] \(line.level.rawValue.uppercased()) \(line.message)")
        }
    }

    func print(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
