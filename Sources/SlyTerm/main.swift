import AppKit

let app = NSApplication.shared
if LookupCLI.run(CommandLine.arguments) { exit(0) }
if GuideSnapshotCLI.run(CommandLine.arguments) { exit(0) }
if DRMCheckCLI.run(CommandLine.arguments) { exit(0) }
if StripSnapshotCLI.run(CommandLine.arguments) { exit(0) }
if FloatSnapshotCLI.run(CommandLine.arguments) { exit(0) }
if ActivityCardSnapshotCLI.run(CommandLine.arguments) { exit(0) }
if SessionsCLI.run(CommandLine.arguments) { exit(0) }
if ActivityCLI.run(CommandLine.arguments) { exit(0) }
if TeleportPicker.runSnapshotCLI(CommandLine.arguments) { exit(0) }
if LookupPicker.runSnapshotCLI(CommandLine.arguments) { exit(0) }
if SetupAssistant.runSnapshotCLI(CommandLine.arguments) { exit(0) }
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
