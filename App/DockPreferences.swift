/*
 * DockPreferences.swift — cleanup for early Instant Mission Control builds
 *
 * The first issue #28 test build wrote the legacy
 * `expose-animation-duration` Dock preference. Modern macOS ignores that key,
 * but restore the user's exact prior value once before the event-based feature
 * takes over.
 */

import Foundation

private let kDockBundleID = "com.apple.dock" as CFString
private let kLegacyMissionControlAnimationKey =
    "expose-animation-duration" as CFString
private let kLegacyBackupWasSet = "wasSet"
private let kLegacyBackupValue  = "value"

/// Restores the value saved by the preference-based test implementation.
/// A missing or malformed record is left untouched rather than guessing what
/// the user's original Dock preference was.
func restoreLegacyMissionControlPreferenceIfNeeded() {
    let defaults = UserDefaults.standard
    guard let backup = defaults.dictionary(
        forKey: Defaults.instantMissionControlBackup
    ), let wasSetNumber = backup[kLegacyBackupWasSet] as? NSNumber else {
        return
    }

    let previous: CFPropertyList?
    if wasSetNumber.boolValue {
        guard let rawValue = backup[kLegacyBackupValue],
              let value = rawValue as? CFPropertyList else { return }
        previous = value
    } else {
        previous = nil
    }

    CFPreferencesSetAppValue(
        kLegacyMissionControlAnimationKey,
        previous,
        kDockBundleID
    )
    CFPreferencesAppSynchronize(kDockBundleID)
    defaults.removeObject(forKey: Defaults.instantMissionControlBackup)
}

/// Updates the independent Mission Control gesture feature and its two UI
/// surfaces. The event tap lifecycle changes immediately; no Dock restart is
/// needed.
func setInstantMissionControlEnabled(_ enabled: Bool) {
    gInstantMissionControlEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Defaults.instantMissionControl)
    updateSwipeTap()
    gMenu?.syncMenuItems()
    SettingsWindowController.shared.syncPanes()
}
