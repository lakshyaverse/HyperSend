import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// Preferences. Everything the Settings window edits lives in UserDefaults under
// one namespaced key, so `@AppStorage` in the views and plain reads in the
// engine always agree.

enum Pref {
    static let launchAtLogin = "pref.launchAtLogin"
    static let appearance = "pref.appearance" // system | light | dark
    static let liquidGlass = "pref.liquidGlass"
    static let glassIntensity = "pref.glassIntensity"
    static let autoAccept = "pref.autoAccept"
    static let openAfterReceive = "pref.openAfterReceive"
    static let revealInFinder = "pref.revealInFinder"
    static let receivePath = "pref.receivePath"
    static let deviceName = "pref.deviceName"
    static let showMenuBarIcon = "pref.showMenuBarIcon"
    static let socketsPerLane = "pref.socketsPerLane"

    /// Registers the defaults the app ships with. Called once at launch, before
    /// anything reads a preference.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            launchAtLogin: false,
            appearance: "system",
            liquidGlass: true,
            glassIntensity: GlassIntensity.maximum.rawValue,
            autoAccept: true,
            // Off by default: opening a received file runs it with its default
            // app. Revealing it in Finder is the safe default.
            openAfterReceive: false,
            revealInFinder: true,
            socketsPerLane: 2,
            showMenuBarIcon: false,
        ])
    }
}

enum AppearancePref: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the choice app-wide. `nil` hands control back to the system.
    static func apply(_ raw: String) {
        NSApp?.appearance = AppearancePref(rawValue: raw)?.nsAppearance
    }
}

/// "Launch at login" via the modern service API — no helper bundle, no
/// AppleScript login items.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually achieved, so the toggle can snap back if the
    /// system refuses.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            LaunchTrace.mark("launch at login failed: \(error.localizedDescription)")
            return isEnabled
        }
        return isEnabled
    }
}
