import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        statusItem = StatusItemController(controller: controller)
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
