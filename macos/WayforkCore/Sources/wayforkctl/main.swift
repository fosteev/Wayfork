import Foundation
import WayforkCore

// wayforkctl — the command line for scripts and coding assistants (F21,
// docs/design/09-wayforkctl.md) and the developer-mode plan builder. Run `wayforkctl help`.

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else { fail(helpText) }
do {
    switch command {
    case "help", "-h", "--help":
        print(helpText)
    case "plan":
        let plan = try buildPlan(arguments.dropFirst())
        let data = try JSONCoding.prettyEncoder.encode(plan)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    case "logs":
        try runLogs(arguments.dropFirst())
    default:
        try runControl(command, arguments.dropFirst())
    }
} catch let usage as Usage {
    fail(usage.description)
} catch {
    fail("\(error)", code: 1)
}
