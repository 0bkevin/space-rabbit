/*
 * DockPreferences.swift — Dock preferences used by optional features
 *
 * Some Dock settings are undocumented and only take effect after the Dock is
 * restarted. Keep the Mission Control preference handling here so the menu
 * bar and Preferences use the same backup/restore behavior.
 */

import AppKit

// MARK: - Dock Preference Constants

private let kDockBundleID = "com.apple.dock" as CFString

/// Undocumented Dock preference that controls Mission Control's opening
/// animation on systems that implement it. macOS may ignore this key; there
/// is deliberately no input interception fallback, so native behavior remains
/// intact when it is unsupported.
private let kMissionControlAnimationKey = "expose-animation-duration" as CFString

/// A small non-zero duration is less likely to be rejected than zero while
/// still making the opening transition effectively instantaneous.
private let kInstantMissionControlDuration = 0.01

// MARK: - Mission Control Preference

/// A single UserDefaults record stores both the previous value and whether the
/// Dock key was set at all. The explicit `wasSet` flag is important: removing
/// the key must be distinguishable from restoring a saved numeric value.
private let kMissionControlBackupWasSet = "wasSet"
private let kMissionControlBackupValue  = "value"

/// Reads the Dock app-domain value directly rather than the effective value
/// after global-domain fallback. This lets restoration preserve an unset key.
private func missionControlDockValue() -> CFPropertyList? {
    CFPreferencesCopyValue(
        kMissionControlAnimationKey,
        kDockBundleID,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    )
}

/// Compares the values used by this preference, including nil (unset).
private func dockValuesEqual(_ lhs: CFPropertyList?, _ rhs: CFPropertyList?) -> Bool {
    guard let left = lhs, let right = rhs else {
        return lhs == nil && rhs == nil
    }
    return CFEqual(left as CFTypeRef, right as CFTypeRef)
}

/// Writes the Dock value and reports whether a write was needed. The caller
/// decides whether to ask the user about restarting Dock.
@discardableResult
private func setMissionControlDockValue(_ value: CFPropertyList?) -> Bool {
    guard !dockValuesEqual(missionControlDockValue(), value) else { return false }

    CFPreferencesSetAppValue(kMissionControlAnimationKey, value, kDockBundleID)
    CFPreferencesAppSynchronize(kDockBundleID)
    return true
}

/// Saves the current Dock value exactly once for the current enable cycle.
/// Repeated enable/sync calls must never replace the original value.
private func saveMissionControlDockValueIfNeeded() {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: Defaults.instantMissionControlBackup) == nil else {
        return
    }

    let current = missionControlDockValue()
    var backup: [String: Any] = [kMissionControlBackupWasSet: current != nil]
    if let current = current { backup[kMissionControlBackupValue] = current }
    defaults.set(backup, forKey: Defaults.instantMissionControlBackup)
}

/// Restores and then forgets the saved Dock value. If no backup exists, leave
/// the key untouched: there is no safe original state to restore.
@discardableResult
private func restoreMissionControlDockValue() -> Bool {
    let defaults = UserDefaults.standard
    guard let backup = defaults.dictionary(forKey: Defaults.instantMissionControlBackup),
          let wasSetNumber = backup[kMissionControlBackupWasSet] as? NSNumber else {
        return false
    }
    let wasSet = wasSetNumber.boolValue

    let previous: CFPropertyList?
    if wasSet {
        guard let rawValue = backup[kMissionControlBackupValue],
              let value = rawValue as? CFPropertyList else {
            return false
        }
        previous = value
    } else {
        previous = nil
    }

    let changed = setMissionControlDockValue(previous)
    defaults.removeObject(forKey: Defaults.instantMissionControlBackup)
    return changed
}

/// Applies the requested Mission Control preference and returns whether the
/// Dock value changed. The preference may be ignored by macOS; in that case
/// Mission Control continues using its native behavior.
@discardableResult
func applyInstantMissionControlPreference(enabled: Bool) -> Bool {
    if enabled {
        saveMissionControlDockValueIfNeeded()
        return setMissionControlDockValue(NSNumber(value: kInstantMissionControlDuration))
    }
    return restoreMissionControlDockValue()
}

/// Whether the Dock key or a pending restore record currently exists.
/// A restored custom value still counts as an override and can be removed with
/// the Advanced pane's explicit "Reset to system default" action.
func hasInstantMissionControlOverride() -> Bool {
    missionControlDockValue() != nil
        || UserDefaults.standard.object(forKey: Defaults.instantMissionControlBackup) != nil
}

/// Updates the feature state, persists it, synchronizes both UI surfaces, and
/// asks before restarting Dock only when the preference actually changed.
func setInstantMissionControlEnabled(_ enabled: Bool) {
    let dockChanged = applyInstantMissionControlPreference(enabled: enabled)
    gInstantMissionControlEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Defaults.instantMissionControl)

    if dockChanged {
        promptDockRestart()
    }
    gMenu?.syncMenuItems()
    SettingsWindowController.shared.syncPanes()
}

/// Removes the Dock key rather than restoring the pre-feature value. This is
/// intentionally distinct from turning the feature off: disable is reversible,
/// while reset is the user's explicit request to return to the system default.
func resetInstantMissionControlToDefault() {
    let dockChanged = setMissionControlDockValue(nil)
    UserDefaults.standard.removeObject(forKey: Defaults.instantMissionControlBackup)
    gInstantMissionControlEnabled = false
    UserDefaults.standard.set(false, forKey: Defaults.instantMissionControl)

    if dockChanged {
        promptDockRestart()
    }
    gMenu?.syncMenuItems()
    SettingsWindowController.shared.syncPanes()
}

// MARK: - Dock Restart Confirmation

/// Dock preference changes are intentionally left pending when the user
/// chooses "Later", matching the existing Instant Dock hide behavior.
func promptDockRestart() {
    let alert = NSAlert()
    alert.messageText     = L("settings.advanced.dockRestart.title")
    alert.informativeText = L("settings.advanced.dockRestart.message")
    alert.addButton(withTitle: L("settings.advanced.dockRestart.confirm"))
    alert.addButton(withTitle: L("common.later"))
    alert.alertStyle = .informational

    if alert.runModal() == .alertFirstButtonReturn {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments  = ["Dock"]
        try? task.run()
    }
}
