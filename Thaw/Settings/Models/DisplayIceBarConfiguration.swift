//
//  DisplayIceBarConfiguration.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Per-display configuration for the Ice Bar.
struct DisplayIceBarConfiguration: Codable, Equatable {
    /// Whether the Ice Bar is enabled on this display.
    let useIceBar: Bool

    /// The location where the Ice Bar appears on this display.
    let iceBarLocation: IceBarLocation

    /// Default configuration (disabled, dynamic location).
    static let defaultConfiguration = DisplayIceBarConfiguration(
        useIceBar: false,
        iceBarLocation: .dynamic
    )

    /// Returns a new configuration with the `useIceBar` flag replaced.
    func withUseIceBar(_ value: Bool) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(useIceBar: value, iceBarLocation: iceBarLocation)
    }

    /// Returns a new configuration with the `iceBarLocation` replaced.
    func withIceBarLocation(_ value: IceBarLocation) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(useIceBar: useIceBar, iceBarLocation: value)
    }
}
