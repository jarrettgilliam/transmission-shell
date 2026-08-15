import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()

application.delegate = delegate
application.setActivationPolicy(.regular)
application.mainMenu = MainMenu.build(appName: Bundle.transmissionShellName)
application.run()
