import SwiftUI

@main
struct KeyfobHostDemoApp: App {
    @UIApplicationDelegateAdaptor(DemoAppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup { DemoView() }
    }
}
