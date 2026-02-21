//
//  DisplayIceBarConfiguration.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

/// Per-display configuration for the Ice Bar.
struct DisplayIceBarConfiguration: Codable, Equatable {
    /// Whether the Ice Bar is enabled on this display.
    let useIceBar: Bool

    /// The location where the Ice Bar appears on this display.
    let iceBarLocation: IceBarLocation

    /// Whether to always show hidden menu bar items on this display.
    ///
    /// This setting is only applicable when ``useIceBar`` is `false`.
    let alwaysShowHiddenItems: Bool

    /// Default configuration (disabled, dynamic location).
    static let defaultConfiguration = DisplayIceBarConfiguration(
        useIceBar: false,
        iceBarLocation: .dynamic,
        alwaysShowHiddenItems: false
    )

    /// Returns a new configuration with the `useIceBar` flag replaced.
    func withUseIceBar(_ value: Bool) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(
            useIceBar: value,
            iceBarLocation: iceBarLocation,
            alwaysShowHiddenItems: alwaysShowHiddenItems
        )
    }

    /// Returns a new configuration with the `iceBarLocation` replaced.
    func withIceBarLocation(_ value: IceBarLocation) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(
            useIceBar: useIceBar,
            iceBarLocation: value,
            alwaysShowHiddenItems: alwaysShowHiddenItems
        )
    }

    /// Returns a new configuration with the `alwaysShowHiddenItems` flag replaced.
    func withAlwaysShowHiddenItems(_ value: Bool) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(
            useIceBar: useIceBar,
            iceBarLocation: iceBarLocation,
            alwaysShowHiddenItems: value
        )
    }

    /// Builds per-display configurations for all connected screens.
    @MainActor
    static func buildConfigurations(
        onlyOnNotched: Bool,
        location: IceBarLocation
    ) -> [String: DisplayIceBarConfiguration] {
        var configs = [String: DisplayIceBarConfiguration]()
        for screen in NSScreen.screens {
            guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else {
                continue
            }
            let enabled = onlyOnNotched ? screen.hasNotch : true
            configs[uuid] = DisplayIceBarConfiguration(
                useIceBar: enabled,
                iceBarLocation: location,
                alwaysShowHiddenItems: false
            )
        }
        return configs
    }
}
