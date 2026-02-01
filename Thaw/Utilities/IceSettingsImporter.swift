//
//  IceSettingsImporter.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import Foundation
import OSLog

/// A type that handles importing settings from Ice.
@MainActor
struct IceSettingsImporter {
    private let logger = Logger(category: "IceSettingsImporter")

    /// The bundle identifier for Ice.
    private static let iceBundleIdentifier = "com.jordanbaird.Ice"

    /// Checks if Ice settings are available for import.
    func hasIceSettings() -> Bool {
        let iceUserDefaults = UserDefaults(suiteName: Self.iceBundleIdentifier)
        return iceUserDefaults?.dictionaryRepresentation().isEmpty == false
    }

    /// Imports settings from Ice if available.
    /// - Returns: A tuple indicating success and the number of settings imported.
    func importIceSettings() -> (success: Bool, settingsImported: Int) {
        guard let iceUserDefaults = UserDefaults(suiteName: Self.iceBundleIdentifier) else {
            logger.warning("Could not access Ice user defaults")
            return (false, 0)
        }

        let iceSettings = iceUserDefaults.dictionaryRepresentation()
        var settingsImported = 0

        logger.info("Starting import of Ice settings. Found \(iceSettings.count) potential settings")

        // Import General Settings
        settingsImported += importGeneralSettings(from: iceSettings)

        // Import Advanced Settings
        settingsImported += importAdvancedSettings(from: iceSettings)

        // Import Hotkeys Settings
        settingsImported += importHotkeysSettings(from: iceSettings)

        // Import Appearance Settings
        settingsImported += importAppearanceSettings(from: iceSettings)

        // Import control item positions/visibility
        settingsImported += importControlItemSettings(from: iceUserDefaults)

        logger.info("Successfully imported \(settingsImported) settings from Ice")
        return (true, settingsImported)
    }

    /// Imports general settings from Ice.
    private func importGeneralSettings(from iceSettings: [String: Any]) -> Int {
        var imported = 0

        let mappings: [(Defaults.Key, String)] = [
            (.showIceIcon, "ShowIceIcon"),
            (.iceIcon, "IceIcon"),
            (.customIceIconIsTemplate, "CustomIceIconIsTemplate"),
            (.useIceBar, "UseIceBar"),
            (.iceBarLocation, "IceBarLocation"),
            (.showOnClick, "ShowOnClick"),
            (.showOnHover, "ShowOnHover"),
            (.showOnScroll, "ShowOnScroll"),
            (.autoRehide, "AutoRehide"),
            (.rehideStrategy, "RehideStrategy"),
            (.rehideInterval, "RehideInterval"),
            (.itemSpacingOffset, "ItemSpacingOffset"),
        ]

        for (key, iceKey) in mappings {
            if let value = iceSettings[iceKey] {
                Defaults.set(value, forKey: key)
                imported += 1
                logger.debug("Imported general setting: \(iceKey)")
            }
        }

        return imported
    }

    /// Imports advanced settings from Ice.
    private func importAdvancedSettings(from iceSettings: [String: Any]) -> Int {
        var imported = 0

        let mappings: [(Defaults.Key, String)] = [
            (.enableAlwaysHiddenSection, "EnableAlwaysHiddenSection"),
            (.showAllSectionsOnUserDrag, "ShowAllSectionsOnUserDrag"),
            (.sectionDividerStyle, "SectionDividerStyle"),
            (.hideApplicationMenus, "HideApplicationMenus"),
            (.enableSecondaryContextMenu, "EnableSecondaryContextMenu"),
            (.showOnHoverDelay, "ShowOnHoverDelay"),
            (.tempShowInterval, "TempShowInterval"),
        ]

        for (key, iceKey) in mappings {
            if let value = iceSettings[iceKey] {
                Defaults.set(value, forKey: key)
                imported += 1
                logger.debug("Imported advanced setting: \(iceKey)")
            }
        }

        return imported
    }

    /// Imports hotkeys settings from Ice.
    private func importHotkeysSettings(from iceSettings: [String: Any]) -> Int {
        // Ice stores hotkeys as a dictionary of action identifiers to encoded `KeyCombination` data.
        if let hotkeysDict = iceSettings["Hotkeys"] as? [String: Any] {
            let dataDict = hotkeysDict.compactMapValues { $0 as? Data }
            guard !dataDict.isEmpty else {
                return 0
            }
            Defaults.set(dataDict, forKey: .hotkeys)
            logger.debug("Imported \(dataDict.count) hotkey settings")
            return dataDict.count
        }

        // Fallback in case the value is already a data blob.
        if let hotkeysData = iceSettings["Hotkeys"] as? Data {
            Defaults.set(hotkeysData, forKey: .hotkeys)
            logger.debug("Imported hotkeys settings")
            return 1
        }

        return 0
    }

    /// Imports appearance settings from Ice.
    private func importAppearanceSettings(from iceSettings: [String: Any]) -> Int {
        var imported = 0

        // Import V2 appearance configuration if available
        if let appearanceData = iceSettings["MenuBarAppearanceConfigurationV2"] as? Data {
            Defaults.set(appearanceData, forKey: .menuBarAppearanceConfigurationV2)
            imported += 1
            logger.debug("Imported appearance configuration V2")
        }
        // Fallback to V1 if V2 not available
        else if let appearanceData = iceSettings["MenuBarAppearanceConfiguration"] as? Data {
            // This will be handled by the existing migration system
            Defaults.set(appearanceData, forKey: .menuBarAppearanceConfiguration)
            imported += 1
            logger.debug("Imported appearance configuration V1")
        }

        return imported
    }

    /// Imports control item positions and visibility flags from Ice.
    private func importControlItemSettings(from iceUserDefaults: UserDefaults) -> Int {
        var imported = 0

        for identifier in ControlItem.Identifier.allCases {
            let autosaveName = identifier.rawValue

            let preferredPositionKey = ControlItemDefaults.Key<CGFloat>.preferredPosition.stringKey(for: autosaveName)
            if let value = iceUserDefaults.object(forKey: preferredPositionKey) as? NSNumber {
                ControlItemDefaults[.preferredPosition, autosaveName] = CGFloat(value.doubleValue)
                imported += 1
                logger.debug("Imported control item position for \(autosaveName)")
            }

            let visibleKey = ControlItemDefaults.Key<Bool>.visible.stringKey(for: autosaveName)
            if let visible = iceUserDefaults.object(forKey: visibleKey) as? Bool {
                ControlItemDefaults[.visible, autosaveName] = visible
                imported += 1
                logger.debug("Imported control item visibility for \(autosaveName)")
            }

            if #available(macOS 26.0, *) {
                let visibleCCKey = ControlItemDefaults.Key<Bool>.visibleCC.stringKey(for: autosaveName)
                if let visibleCC = iceUserDefaults.object(forKey: visibleCCKey) as? Bool {
                    ControlItemDefaults[.visibleCC, autosaveName] = visibleCC
                    imported += 1
                    logger.debug("Imported control item Control Center visibility for \(autosaveName)")
                }
            }
        }

        return imported
    }
}
