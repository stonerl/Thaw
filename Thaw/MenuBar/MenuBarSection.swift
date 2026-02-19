//
//  MenuBarSection.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        /// A string to show in the interface.
        var displayString: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always-Hidden"
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .visible: "visible section"
            case .hidden: "hidden section"
            case .alwaysHidden: "always-hidden section"
            }
        }

        /// Localized string key representation.
        var localized: LocalizedStringKey {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always-Hidden"
            }
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A timer that manages rehiding the section.
    private var rehideTimer: Timer?

    /// An event monitor that handles starting the rehide timer when the mouse
    /// is outside of the menu bar.
    private var rehideMonitor: EventMonitor?

    /// The section's diagnostic logger.
    private nonisolated let diagLog = DiagLog(category: "MenuBarSection")

    /// A Boolean value that indicates whether the Ice Bar should be used.
    private var useIceBar: Bool {
        guard let settings = appState?.settings.general, settings.useIceBar else {
            return false
        }
        if settings.useIceBarOnlyOnNotchedDisplay {
            let screen = screenForIceBar
            return screen?.hasNotch ?? false
        }
        return true
    }

    /// A weak reference to the menu bar manager.
    private weak var menuBarManager: MenuBarManager? {
        appState?.menuBarManager
    }

    /// The best screen to show the Ice Bar on.
    ///
    /// Always returns the screen with the active menu bar so that
    /// clicking icons in the IceBar actually activates their popups.
    private weak var screenForIceBar: NSScreen? {
        NSScreen.screenWithActiveMenuBar ?? NSScreen.main
    }

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        if useIceBar {
            if controlItem.state == .showSection {
                return false
            }
            switch name {
            case .visible, .hidden:
                return menuBarManager?.iceBarPanel.currentSection != .hidden
            case .alwaysHidden:
                return menuBarManager?.iceBarPanel.currentSection != .alwaysHidden
            }
        }
        switch name {
        case .visible, .hidden:
            if menuBarManager?.iceBarPanel.currentSection == .hidden {
                return false
            }
            return controlItem.state == .hideSection
        case .alwaysHidden:
            if menuBarManager?.iceBarPanel.currentSection == .alwaysHidden {
                return false
            }
            return controlItem.state == .hideSection
        }
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        if case .visible = name {
            // The visible section should always be enabled.
            return true
        }
        return controlItem.isAddedToMenuBar
    }

    /// The hotkey to toggle the section.
    var hotkey: Hotkey? {
        guard let hotkeys = appState?.settings.hotkeys else {
            return nil
        }
        return switch name {
        case .visible: nil
        case .hidden: hotkeys.hotkey(withAction: .toggleHiddenSection)
        case .alwaysHidden: hotkeys.hotkey(withAction: .toggleAlwaysHiddenSection)
        }
    }

    /// Creates a section with the given name and control item.
    init(name: Name, controlItem: ControlItem) {
        self.name = name
        self.controlItem = controlItem
    }

    /// Creates a section with the given name.
    convenience init(name: Name) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .visible)
        case .hidden:
            ControlItem(identifier: .hidden)
        case .alwaysHidden:
            ControlItem(identifier: .alwaysHidden)
        }
        self.init(name: name, controlItem: controlItem)
    }

    /// Performs the initial setup of the section.
    func performSetup(with appState: AppState) {
        self.appState = appState
        controlItem.performSetup(with: appState)
    }

    /// Shows the section.
    func show(triggeredByHotkey: Bool = false) {
        guard let menuBarManager, isHidden else {
            return
        }

        menuBarManager.updateLastShowTimestamp()

        guard controlItem.isAddedToMenuBar else {
            // The section is disabled.
            // TODO: Can we use isEnabled for this check?
            return
        }

        if useIceBar {
            // Make sure hidden and always-hidden control items are collapsed.
            // Still update the visible control item (Ice icon) state to show
            // its alternate icon.
            for section in menuBarManager.sections {
                switch section.name {
                case .visible:
                    section.controlItem.state = .showSection
                case .hidden, .alwaysHidden:
                    section.controlItem.state = .hideSection
                }
            }

            if let screen = screenForIceBar {
                Task {
                    switch name {
                    case .visible, .hidden:
                        await menuBarManager.iceBarPanel.show(
                            section: .hidden,
                            on: screen,
                            triggeredByHotkey: triggeredByHotkey
                        )
                    case .alwaysHidden:
                        await menuBarManager.iceBarPanel.show(
                            section: .alwaysHidden,
                            on: screen,
                            triggeredByHotkey: triggeredByHotkey
                        )
                    }
                    startRehideChecks()
                }
            }

            return // We're done.
        }

        // If we made it here, we're not using the Ice Bar.
        // Make sure it's closed.
        menuBarManager.iceBarPanel.close()

        switch name {
        case .visible, .hidden:
            for section in menuBarManager.sections where section.name != .alwaysHidden {
                section.controlItem.state = .showSection
            }
        case .alwaysHidden:
            for section in menuBarManager.sections {
                section.controlItem.state = .showSection
            }
        }

        startRehideChecks()
    }

    /// Hides the section.
    func hide() {
        guard let menuBarManager, !isHidden else {
            return
        }

        menuBarManager.iceBarPanel.close() // Make sure Ice Bar is always closed.
        menuBarManager.showOnHoverAllowed = true

        switch name {
        case _ where useIceBar, .visible, .hidden:
            for section in menuBarManager.sections {
                section.controlItem.state = .hideSection
            }
        case .alwaysHidden:
            controlItem.state = .hideSection
        }

        stopRehideChecks()
    }

    /// Toggles the visibility of the section.
    func toggle(triggeredByHotkey: Bool = false) {
        if isHidden {
            show(triggeredByHotkey: triggeredByHotkey)
        } else {
            hide()
        }
    }

    /// Returns `true` when the mouse cursor is inside the menu bar or the
    /// IceBar panel, meaning the section should not be rehidden yet.
    private func isMouseInsideActiveArea() -> Bool {
        guard let appState else { return false }
        if let screen = appState.hidEventManager.bestScreen(appState: appState),
           appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
        {
            return true
        }
        if appState.hidEventManager.isMouseInsideIceBar(appState: appState) {
            return true
        }
        return false
    }

    /// Starts running checks to determine when to rehide the section.
    private func startRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()

        guard
            let appState,
            appState.settings.general.autoRehide
        else {
            return
        }

        switch appState.settings.general.rehideStrategy {
        case .smart:
            // Smart rehide strategy uses the rehide interval as a fallback
            // to the click-based rehide checks.
            rehideTimer = .scheduledTimer(
                withTimeInterval: appState.settings.general.rehideInterval,
                repeats: false
            ) { [weak self] _ in
                Task {
                    // Don't rehide while the mouse is inside the menu bar or IceBar.
                    if await self?.isMouseInsideActiveArea() == true {
                        await self?.startRehideChecks()
                        return
                    }
                    // Check if any menu bar item has a menu open before hiding.
                    if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                        // Restart the timer to check again later.
                        await self?.startRehideChecks()
                        return
                    }
                    await self?.hide()
                }
            }
        case .timed:
            rehideMonitor = EventMonitor.universal(for: .mouseMoved) { [weak self] event in
                // Throttle: process at most ~20fps regardless of mouse polling rate.
                enum Context {
                    static var lastTime: TimeInterval = 0
                }
                let now = CACurrentMediaTime()
                guard now - Context.lastTime > 0.05 else { return event }
                Context.lastTime = now

                guard
                    let self,
                    let screen = NSScreen.main
                else {
                    return event
                }
                let mouseInActiveArea =
                    NSEvent.mouseLocation.y >= screen.visibleFrame.maxY ||
                    appState.hidEventManager.isMouseInsideIceBar(appState: appState)

                if !mouseInActiveArea {
                    if rehideTimer == nil {
                        rehideTimer = .scheduledTimer(
                            withTimeInterval: appState.settings.general.rehideInterval,
                            repeats: false
                        ) { [weak self] _ in
                            guard let self else { return }
                            Task {
                                // Don't rehide while the mouse is inside the menu bar or IceBar.
                                if await self.isMouseInsideActiveArea() {
                                    await self.startRehideChecks()
                                    return
                                }
                                // Check if any menu bar item has a menu open before hiding.
                                if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                                    self.diagLog.debug("Open menu detected - restarting timed rehide timer")
                                    await self.restartTimedRehideTimer()
                                    return
                                }
                                await self.hide()
                            }
                        }
                    }
                } else {
                    rehideTimer?.invalidate()
                    rehideTimer = nil
                }
                return event
            }

            rehideMonitor?.start()
        case .focusedApp:
            break
        }
    }

    /// Restarts the timed rehide timer (used when a menu is detected).
    @MainActor
    private func restartTimedRehideTimer() async {
        guard
            let appState,
            appState.settings.general.autoRehide,
            case .timed = appState.settings.general.rehideStrategy
        else {
            return
        }

        rehideTimer?.invalidate()
        rehideTimer = .scheduledTimer(
            withTimeInterval: appState.settings.general.rehideInterval,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                // Don't rehide while the mouse is inside the menu bar or IceBar.
                if await self.isMouseInsideActiveArea() {
                    await self.startRehideChecks()
                    return
                }
                // Check if any menu bar item has a menu open before hiding.
                if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                    self.diagLog.debug("Open menu still detected - restarting timed rehide timer again")
                    await self.restartTimedRehideTimer()
                    return
                }
                await self.hide()
            }
        }
    }

    /// Stops running checks to determine when to rehide the section.
    private func stopRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()
        rehideTimer = nil
        rehideMonitor = nil
    }
}
