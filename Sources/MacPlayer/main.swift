import AppKit
import MacPlayerCore

let args = CommandLine.arguments
var sandbox: URL?
if let i = args.firstIndex(of: "--sandbox"), i + 1 < args.count { sandbox = URL(fileURLWithPath: args[i + 1], isDirectory: true) }
let app = NSApplication.shared
MainActor.assumeIsolated {
    AppEnvironment.shared = AppEnvironment(sandbox: sandbox)
    let delegate = AppDelegate()
    app.delegate = delegate
    objc_setAssociatedObject(app, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
