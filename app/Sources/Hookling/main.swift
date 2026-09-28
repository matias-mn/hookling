import AppKit

// Entry point. Deliberately tiny: everything happens in AppDelegate once AppKit
// is up. Note there is no .xib and no main menu - an accessory app needs neither.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
