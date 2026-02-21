//
//  DisplaySettingsManager.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine

/// Manages per-display Ice Bar configuration.
///
/// Configurations are keyed by display UUID string (via `Bridging.getDisplayUUIDString(for:)`).
/// When a display has no explicit configuration, `DisplayIceBarConfiguration.defaultConfiguration`
/// is returned.
@MainActor
final class DisplaySettingsManager: ObservableObject {
    private let diagLog = DiagLog(category: "DisplaySettingsManager")

    /// Per-display configurations, keyed by display UUID string.
    @Published var configurations: [String: DisplayIceBarConfiguration] = [:]

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// JSON encoder for persistence.
    private let encoder = JSONEncoder()

    /// JSON decoder for persistence.
    private let decoder = JSONDecoder()

    /// Performs the initial setup of the manager.
    func performSetup(with _: AppState) {
        loadInitialState()
        configureCancellables()
    }

    // MARK: - Loading

    /// Loads saved configurations from Defaults.
    private func loadInitialState() {
        guard let data = Defaults.data(forKey: .displayIceBarConfigurations) else {
            return
        }
        do {
            configurations = try decoder.decode([String: DisplayIceBarConfiguration].self, from: data)
            diagLog.info("Loaded per-display configurations for \(configurations.count) display(s)")
        } catch {
            diagLog.error("Failed to decode per-display configurations: \(error)")
        }
    }

    // MARK: - Persistence

    /// Configures Combine sinks to persist configurations on change.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $configurations
            .dropFirst() // Skip the initial emission during setup
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configs in
                guard let self else { return }
                do {
                    let data = try encoder.encode(configs)
                    Defaults.set(data, forKey: .displayIceBarConfigurations)
                } catch {
                    diagLog.error("Failed to encode per-display configurations: \(error)")
                }
            }
            .store(in: &c)

        // Listen for display connect/disconnect to log changes.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                diagLog.info("Screen parameters changed — \(NSScreen.screens.count) screen(s) connected")
            }
            .store(in: &c)

        cancellables = c
    }

    // MARK: - Lookup

    /// Returns the configuration for a given display ID.
    func configuration(for displayID: CGDirectDisplayID) -> DisplayIceBarConfiguration {
        guard let uuid = Bridging.getDisplayUUIDString(for: displayID) else {
            return .defaultConfiguration
        }
        return configurations[uuid] ?? .defaultConfiguration
    }

    /// Returns the configuration for the display with the active menu bar.
    func configurationForActiveDisplay() -> DisplayIceBarConfiguration {
        guard let displayID = Bridging.getActiveMenuBarDisplayID() else {
            return .defaultConfiguration
        }
        return configuration(for: displayID)
    }

    /// Whether the Ice Bar is enabled for the given display.
    func useIceBar(for displayID: CGDirectDisplayID) -> Bool {
        configuration(for: displayID).useIceBar
    }

    /// The Ice Bar location for the given display.
    func iceBarLocation(for displayID: CGDirectDisplayID) -> IceBarLocation {
        configuration(for: displayID).iceBarLocation
    }

    /// Whether any connected display has the Ice Bar enabled.
    var isIceBarEnabledOnAnyDisplay: Bool {
        configurations.values.contains { $0.useIceBar }
    }

    // MARK: - Mutation (Immutable Pattern)

    /// Updates the configuration for a display by applying a transform,
    /// producing a new dictionary (immutable pattern).
    func updateConfiguration(
        forDisplayUUID uuid: String,
        transform: (DisplayIceBarConfiguration) -> DisplayIceBarConfiguration
    ) {
        let current = configurations[uuid] ?? .defaultConfiguration
        let updated = transform(current)
        var newConfigurations = configurations
        newConfigurations[uuid] = updated
        configurations = newConfigurations
    }

    /// Toggles the Ice Bar for the display with the active menu bar.
    func toggleIceBarForActiveDisplay() {
        guard let uuid = Bridging.getActiveMenuBarDisplayUUID() else {
            diagLog.warning("Cannot toggle Ice Bar — no active menu bar display UUID")
            return
        }
        updateConfiguration(forDisplayUUID: uuid) { config in
            config.withUseIceBar(!config.useIceBar)
        }
    }

    // MARK: - Display Info

    /// Information about a connected display for use in the settings UI.
    struct DisplayInfo: Identifiable {
        let id: String // UUID string
        let displayID: CGDirectDisplayID
        let name: String
        let hasNotch: Bool
    }

    /// Returns info about all currently connected displays.
    func connectedDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else {
                return nil
            }
            return DisplayInfo(
                id: uuid,
                displayID: screen.displayID,
                name: screen.localizedName,
                hasNotch: screen.hasNotch
            )
        }
    }
}
