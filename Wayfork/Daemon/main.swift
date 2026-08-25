import Darwin
import Foundation
import WayforkCore
import WayforkDaemonCore
import os

// launchd starts this executable on the first connection to `com.wayfork.daemon.xpc`
// (docs/design/05-daemon.md). Everything privileged happens behind `Supervisor`.

signal(SIGPIPE, SIG_IGN)

let environment = DaemonEnvironment.current()
let hub = ClientHub(logDirectory: environment.logDirectory)
let supervisor = Supervisor(env: environment, hub: hub)

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--dev-apply" {
    // Terminal mode for verifying the daemon without launchd/app (see docs/design/05-daemon.md).
    try? environment.prepareDirectories()
    DevRunner.run(planPath: CommandLine.arguments[2], supervisor: supervisor, hub: hub)
}

let listenerDelegate = ListenerDelegate(
    supervisor: supervisor, hub: hub, teamID: environment.teamID)
let listener = NSXPCListener(machServiceName: WayforkIdentifiers.machService)
listener.delegate = listenerDelegate

do {
    try environment.prepareDirectories()
} catch {
    Logger(subsystem: WayforkIdentifiers.daemon, category: "main")
        .error("cannot create directories: \(error, privacy: .public)")
}

// SIGTERM (launchd unload, app update): bring everything down before exiting so no
// child outlives the daemon.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task {
        _ = await supervisor.stop()
        exit(0)
    }
}
termination.resume()

Task {
    await hub.start()
    await supervisor.bootstrap()
    listener.resume()
}

dispatchMain()
