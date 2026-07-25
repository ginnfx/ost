import SwiftUI
#if os(macOS)
import AppKit

// TODO(iOS): the sidecar lifecycle is macOS-only (it spawns a local process).
// An iOS LAN-companion build would talk to a Mac-hosted sidecar instead and
// tear down via scenePhase rather than an AppKit terminate hook.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.shutdown()
    }
}
#endif

@main
struct OSTTrackerApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    init() {
        setlinebuf(stdout)  // GATE lines must survive a piped, killed run
        Theme.registerFonts()
        #if DEBUG
        Theme.verify()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: AppStore.shared)
                .task { await AppStore.shared.start() }
                .frame(minWidth: 980, minHeight: 640)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)  // TODO(iOS): no window chrome to hide
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
