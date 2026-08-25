import Foundation
import WayforkCore
import os

// M0 placeholder: the XPC listener, Supervisor and process helpers arrive in M2.
// launchd starts this executable on the first connection to `com.wayfork.daemon.xpc`.

let log = Logger(subsystem: WayforkIdentifiers.daemon, category: "main")
log.notice("WayforkDaemon \(WayforkCore.version, privacy: .public) started (scaffolding build)")

dispatchMain()
