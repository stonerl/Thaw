//
//  DisplaySettingsPane.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import SwiftUI

struct DisplaySettingsPane: View {
    @ObservedObject var displaySettings: DisplaySettingsManager

    var body: some View {
        IceForm {
            ForEach(displaySettings.connectedDisplays()) { display in
                IceSection {
                    displayRow(for: display)
                }
            }
        }
    }

    @ViewBuilder
    private func displayRow(for display: DisplaySettingsManager.DisplayInfo) -> some View {
        let useIceBar = Binding<Bool>(
            get: { displaySettings.configuration(for: display.displayID).useIceBar },
            set: { newValue in
                displaySettings.updateConfiguration(forDisplayUUID: display.id) { config in
                    config.withUseIceBar(newValue)
                }
            }
        )

        let location = Binding<IceBarLocation>(
            get: { displaySettings.configuration(for: display.displayID).iceBarLocation },
            set: { newValue in
                displaySettings.updateConfiguration(forDisplayUUID: display.id) { config in
                    config.withIceBarLocation(newValue)
                }
            }
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.name)
                    .font(.headline)
                if display.hasNotch {
                    Text("Notch")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
        }

        Toggle("Use \(Constants.displayName) Bar", isOn: useIceBar)
            .annotation("Show hidden menu bar items in a separate bar below the menu bar on this display.")

        if useIceBar.wrappedValue {
            IcePicker("Location", selection: location) {
                ForEach(IceBarLocation.allCases) { loc in
                    Text(loc.localized).tag(loc)
                }
            }
            .annotation {
                switch location.wrappedValue {
                case .dynamic:
                    Text("The \(Constants.displayName) Bar's location changes based on context.")
                case .mousePointer:
                    Text("The \(Constants.displayName) Bar is centered below the mouse pointer.")
                case .iceIcon:
                    Text("The \(Constants.displayName) Bar is centered below the \(Constants.displayName) icon.")
                }
            }
        }
    }
}
