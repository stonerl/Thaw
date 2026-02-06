//
//  LayoutBarPaddingView.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine
import OSLog

/// A Cocoa view that manages the menu bar layout interface.
final class LayoutBarPaddingView: NSView {
    private let container: LayoutBarContainer
    private var isStabilizing = false

    /// The layout view's arranged views.
    var arrangedViews: [LayoutBarItemView] {
        get { container.arrangedViews }
        set { container.arrangedViews = newValue }
    }

    /// Creates a layout bar view with the given app state, section, and spacing.
    ///
    /// - Parameters:
    ///   - appState: The shared app state instance.
    ///   - section: The section whose items are represented.
    init(appState: AppState, section: MenuBarSection.Name) {
        self.container = LayoutBarContainer(appState: appState, section: section)

        super.init(frame: .zero)

        addSubview(container)
        self.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7.5),
            leadingAnchor.constraint(lessThanOrEqualTo: container.leadingAnchor, constant: -7.5),
        ])

        registerForDraggedTypes([.layoutBarItem])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        return container.updateArrangedViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !isStabilizing else { return }
        if let sender {
            container.updateArrangedViewsForDrag(with: sender, phase: .exited)
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        return container.updateArrangedViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard !isStabilizing else { return }
        container.updateArrangedViewsForDrag(with: sender, phase: .ended)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            DispatchQueue.main.async {
                self.container.canSetArrangedViews = true
            }
        }

        guard let draggingSource = sender.draggingSource as? LayoutBarItemView else {
            return false
        }

        if let index = arrangedViews.firstIndex(of: draggingSource) {
            if arrangedViews.count == 1 {
                Task {
                    // dragging source is the only view in the layout bar, so we
                    // need to find a target item
                    let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
                    let targetItem: MenuBarItem? = switch container.section {
                    case .visible: nil // visible section always has more than 1 item
                    case .hidden: items.first(matching: .hiddenControlItem)
                    case .alwaysHidden: items.first(matching: .alwaysHiddenControlItem)
                    }
                    if let targetItem {
                        move(item: draggingSource.item, to: .leftOfItem(targetItem))
                    } else {
                        Logger.default.error("No target item for layout bar drag")
                    }
                }
            } else if arrangedViews.indices.contains(index + 1) {
                // we have a view to the right of the dragging source
                let targetItem = arrangedViews[index + 1].item
                move(item: draggingSource.item, to: .leftOfItem(targetItem))
            } else if arrangedViews.indices.contains(index - 1) {
                // we have a view to the left of the dragging source
                let targetItem = arrangedViews[index - 1].item
                move(item: draggingSource.item, to: .rightOfItem(targetItem))
            }
        }

        return true
    }

    private func move(item: MenuBarItem, to destination: MenuBarItemManager.MoveDestination) {
        guard let appState = container.appState else {
            return
        }
        Task {
            guard !isStabilizing else { return }
            isStabilizing = true
            await MainActor.run { self.showOverlay(true) }
            try await Task.sleep(for: .milliseconds(25))
            do {
                try await appState.itemManager.move(item: item, to: destination)
                appState.itemManager.removeTemporarilyShownItemFromCache(with: item.tag)
                await stabilizePlacement(of: item, to: destination, expectedSection: container.section, appState: appState)
            } catch {
                Logger.default.error("Error moving menu bar item: \(error, privacy: .public)")
                let alert = NSAlert(error: error)
                alert.runModal()
            }
            await MainActor.run {
                self.isStabilizing = false
                self.showOverlay(false)
            }
        }
    }

    private func showOverlay(_ visible: Bool) {
        container.alphaValue = visible ? 0.6 : 1.0
    }

    /// Ensures the dragged item remains in the intended section and its icon appears.
    private func stabilizePlacement(
        of item: MenuBarItem,
        to destination: MenuBarItemManager.MoveDestination,
        expectedSection: MenuBarSection.Name,
        appState: AppState
    ) async {
        // First refresh caches and verify placement.
        await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)

        func isInExpectedSection() -> Bool {
            appState.itemManager.itemCache[expectedSection].contains { $0.tag == item.tag }
        }

        if !isInExpectedSection() {
            // Allow macOS a brief moment to settle, then retry once.
            try? await Task.sleep(for: .milliseconds(120))
            do {
                try await appState.itemManager.move(item: item, to: destination)
                await appState.itemManager.cacheItemsRegardless(skipRecentMoveCheck: true)
            } catch {
                Logger.default.error("Stabilize move failed: \(error, privacy: .public)")
            }
        }

        // Refresh images so icons show immediately in the UI without clearing to avoid temporary gaps.
        await MainActor.run {
            appState.imageCache.performCacheCleanup()
        }
        await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
    }
}
