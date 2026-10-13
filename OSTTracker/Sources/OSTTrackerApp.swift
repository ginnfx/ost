import SwiftUI
#if os(macOS)
import AppKit

// macOS owns the Python backend; iOS starts with its on-device offline store.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { CloudAccount.shared.handle($0) }
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
            #if os(iOS)
            IOSRootView(store: AppStore.shared)
                .task { await AppStore.shared.start() }
                .onOpenURL { CloudAccount.shared.handle($0) }
            #else
            RootView(store: AppStore.shared)
                .task { await AppStore.shared.start() }
                .onOpenURL { CloudAccount.shared.handle($0) }
                .frame(minWidth: 980, minHeight: 640)
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif

    }
}
