//
//  nutApp.swift
//  nut
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct nutApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private var notchIslandManager: NotchIslandManager?
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🥜 Nut: Starting...")
        print("🥜 Nut: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        NutAnalytics.configure()
        NutAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()

        // Show the notch island only once the user has completed onboarding
        // and granted all permissions — it's confusing to show it mid-setup.
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            notchIslandManager = NotchIslandManager(companionManager: companionManager)
            notchIslandManager?.show()
        }

        // Auto-open the menu bar panel on launch if the user still needs to
        // grant permissions, complete onboarding, or configure their AI key.
        if !companionManager.hasCompletedOnboarding
            || !companionManager.allPermissionsGranted
            || !companionManager.isLLMConfigured {
            menuBarPanelManager?.showPanelOnLaunch()
        }

        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🥜 Nut: Registered as login item")
            } catch {
                print("⚠️ Nut: Failed to register as login item: \(error)")
            }
        }
    }
}
