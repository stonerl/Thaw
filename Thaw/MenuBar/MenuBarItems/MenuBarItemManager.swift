//
//  MenuBarItemManager.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine
import OSLog

/// Simple actor-based semaphore to prevent overlapping operations
actor SimpleSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var value: Int
    private var waiters: [Waiter] = [] // FIFO

    init(value: Int) {
        precondition(value >= 0, "SimpleSemaphore requires a non-negative value")
        self.value = value
    }

    /// Waits for, or decrements, the semaphore, throwing on cancellation.
    func wait() async throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        value -= 1
        if value >= 0 {
            return
        }

        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: { [weak self] in
            Task.detached { await self?.cancelWaiter(withID: id) }
        }
    }

    private func cancelWaiter(withID id: UUID) {
        defer { value += 1 }
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Signals the semaphore, resuming the next waiter if present.
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: ())
        } else {
            value += 1
        }
    }
}

/// Manager for menu bar items.
@MainActor
final class MenuBarItemManager: ObservableObject {
    static let layoutWatchdogTimeout: DispatchTimeInterval = .seconds(6)

    /// The current cache of menu bar items.
    @Published private(set) var itemCache = ItemCache(displayID: nil)

    /// Logger for the menu bar item manager.
    private nonisolated let logger = Logger.menuBarItemManager

    /// Diagnostic logger for the menu bar item manager.
    private let diagLog = DiagLog(category: "MenuBarItemManager")

    /// Semaphore to prevent overlapping event operations.
    private let eventSemaphore = SimpleSemaphore(value: 1)

    /// Actor for managing menu bar item cache operations.
    private let cacheActor = CacheActor()

    /// Contexts for temporarily shown menu bar items.
    private var temporarilyShownItemContexts = [TemporarilyShownItemContext]()

    /// A timer for rehiding temporarily shown menu bar items.
    private var rehideTimer: Timer?
    private var rehideCancellable: AnyCancellable?

    /// Timestamp of the most recent menu bar item move operation.
    private var lastMoveOperationTimestamp: ContinuousClock.Instant?

    /// Cached timeouts for move operations.
    private var moveOperationTimeouts = [MenuBarItemTag: Duration]()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Timer for lightweight periodic cache checks.
    private var cacheTickCancellable: AnyCancellable?

    /// Persisted identifiers of menu bar items we've already seen.
    private var knownItemIdentifiers = Set<String>()
    /// Suppresses the next automatic relocation of newly seen leftmost items.
    private var suppressNextNewLeftmostItemRelocation = false
    /// Persisted bundle identifiers explicitly placed in hidden section.
    private var pinnedHiddenBundleIDs = Set<String>()
    /// Persisted bundle identifiers explicitly placed in always-hidden section.
    private var pinnedAlwaysHiddenBundleIDs = Set<String>()

    /// Persisted mapping of item tag identifiers to their original section name for
    /// temporarily shown items whose apps quit before they could be rehidden. When
    /// the app relaunches, this allows us to move the item back to its original section.
    private var pendingRelocations = [String: String]()

    /// Loads persisted known item identifiers.
    private func loadKnownItemIdentifiers() {
        let key = "MenuBarItemManager.knownItemIdentifiers"
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: key) as? [String] {
            knownItemIdentifiers = Set(stored)
        }
    }

    /// Persists known item identifiers.
    private func persistKnownItemIdentifiers() {
        let key = "MenuBarItemManager.knownItemIdentifiers"
        let defaults = UserDefaults.standard
        defaults.set(Array(knownItemIdentifiers), forKey: key)
    }

    /// Loads persisted pinned bundle identifiers.
    private func loadPinnedBundleIDs() {
        let defaults = UserDefaults.standard
        if let hidden = defaults.array(forKey: "MenuBarItemManager.pinnedHiddenBundleIDs") as? [String] {
            pinnedHiddenBundleIDs = Set(hidden)
        }
        if let alwaysHidden = defaults.array(forKey: "MenuBarItemManager.pinnedAlwaysHiddenBundleIDs") as? [String] {
            pinnedAlwaysHiddenBundleIDs = Set(alwaysHidden)
        }
    }

    /// Persists pinned bundle identifiers.
    private func persistPinnedBundleIDs() {
        let defaults = UserDefaults.standard
        defaults.set(Array(pinnedHiddenBundleIDs), forKey: "MenuBarItemManager.pinnedHiddenBundleIDs")
        defaults.set(Array(pinnedAlwaysHiddenBundleIDs), forKey: "MenuBarItemManager.pinnedAlwaysHiddenBundleIDs")
    }

    /// Loads persisted pending relocations for temporarily shown items
    /// whose apps quit before they could be rehidden.
    private func loadPendingRelocations() {
        let key = "MenuBarItemManager.pendingRelocations"
        if let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            pendingRelocations = stored
        }
    }

    /// Persists pending relocations.
    private func persistPendingRelocations() {
        let key = "MenuBarItemManager.pendingRelocations"
        UserDefaults.standard.set(pendingRelocations, forKey: key)
    }

    /// Returns a persistable string key for the given section name.
    private func sectionKey(for section: MenuBarSection.Name) -> String {
        switch section {
        case .visible: "visible"
        case .hidden: "hidden"
        case .alwaysHidden: "alwaysHidden"
        }
    }

    /// Returns the section name for the given persisted key, if valid.
    private func sectionName(for key: String) -> MenuBarSection.Name? {
        switch key {
        case "visible": .visible
        case "hidden": .hidden
        case "alwaysHidden": .alwaysHidden
        default: nil
        }
    }

    /// The shared app state.
    private(set) weak var appState: AppState?

    /// Sets up the manager.
    func performSetup(with appState: AppState) async {
        diagLog.debug("performSetup: starting MenuBarItemManager setup")
        self.appState = appState
        loadKnownItemIdentifiers()
        loadPinnedBundleIDs()
        loadPendingRelocations()
        diagLog.debug("performSetup: loaded \(self.knownItemIdentifiers.count) known identifiers, \(self.pinnedHiddenBundleIDs.count) pinned hidden, \(self.pinnedAlwaysHiddenBundleIDs.count) pinned always-hidden")
        // On first launch (no known identifiers), avoid auto-relocating the leftmost item
        // so everything remains in the hidden section until the user interacts.
        suppressNextNewLeftmostItemRelocation = knownItemIdentifiers.isEmpty
        diagLog.debug("performSetup: calling initial cacheItemsRegardless")
        await cacheItemsRegardless()
        diagLog.debug("performSetup: initial cache complete, items in cache: visible=\(self.itemCache[.visible].count), hidden=\(self.itemCache[.hidden].count), alwaysHidden=\(self.itemCache[.alwaysHidden].count), managedItems=\(self.itemCache.managedItems.count)")
        configureCancellables(with: appState)
        configureCacheTick()
        diagLog.debug("performSetup: MenuBarItemManager setup complete")
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables(with appState: AppState) {
        var c = Set<AnyCancellable>()

        NSWorkspace.shared.publisher(for: \.runningApplications)
            .delay(for: 0.25, scheduler: DispatchQueue.main)
            .discardMerge(Timer.publish(every: 0.5, on: .main, in: .default).autoconnect())
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
            .store(in: &c)

        appState.navigationState.$settingsNavigationIdentifier
            .sink { [weak self] identifier in
                guard let self, identifier == .menuBarLayout else {
                    return
                }
                Task {
                    await self.cacheItemsRegardless()
                }
            }
            .store(in: &c)

        // When Settings reopens with Menu Bar Layout already selected,
        // settingsNavigationIdentifier does not change, so the subscriber
        // above does not fire. Observe isSettingsPresented to catch this case.
        appState.navigationState.$isSettingsPresented
            .removeDuplicates()
            .sink { [weak self] isPresented in
                guard
                    let self,
                    isPresented,
                    appState.navigationState.settingsNavigationIdentifier == .menuBarLayout
                else {
                    return
                }
                Task {
                    await self.cacheItemsRegardless()
                }
            }
            .store(in: &c)

        cancellables = c
    }

    /// Sets up a lightweight periodic cache tick to catch new items promptly.
    private func configureCacheTick() {
        cacheTickCancellable?.cancel()
        cacheTickCancellable = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.cacheItemsIfNeeded()
                }
            }
    }

    /// Returns a Boolean value that indicates whether the most recent
    /// menu bar item move operation occurred within the given duration.
    func lastMoveOperationOccurred(within duration: Duration) -> Bool {
        guard let timestamp = lastMoveOperationTimestamp else {
            return false
        }
        return timestamp.duration(to: .now) <= duration
    }
}

// MARK: - Item Cache

extension MenuBarItemManager {
    /// An actor that manages menu bar item cache operations.
    private final actor CacheActor {
        /// Stored task for the current cache operation.
        private var cacheTask: Task<Void, Never>?

        /// A list of the menu bar item window identifiers at the time
        /// of the previous cache.
        private(set) var cachedItemWindowIDs = [CGWindowID]()

        /// Runs the given async closure as a task and waits for it to
        /// complete before returning.
        ///
        /// If a task from a previous call to this method is currently
        /// running, that task is cancelled and replaced.
        func runCacheTask(_ operation: @escaping () async -> Void) async {
            cacheTask.take()?.cancel()
            let task = Task(operation: operation)
            cacheTask = task
            await task.value
        }

        /// Updates the list of cached menu bar item window identifiers.
        func updateCachedItemWindowIDs(_ itemWindowIDs: [CGWindowID]) {
            cachedItemWindowIDs = itemWindowIDs
        }

        /// Clears the list of cached menu bar item window identifiers.
        func clearCachedItemWindowIDs() {
            cachedItemWindowIDs.removeAll()
        }
    }

    /// Cache for menu bar items.
    struct ItemCache: Hashable {
        /// Storage for cached menu bar items, keyed by section.
        private var storage = [MenuBarSection.Name: [MenuBarItem]]()

        /// The identifier of the display with the active menu bar at
        /// the time this cache was created.
        let displayID: CGDirectDisplayID?

        /// The cached menu bar items as an array.
        var managedItems: [MenuBarItem] {
            MenuBarSection.Name.allCases.reduce(into: []) { result, section in
                guard let items = storage[section] else {
                    return
                }
                result.append(contentsOf: items)
            }
        }

        /// Creates a cache with the given display identifier.
        init(displayID: CGDirectDisplayID?) {
            self.displayID = displayID
        }

        // TODO: This is redundant now, so remove it.
        /// Returns the managed menu bar items for the given section.
        func managedItems(for section: MenuBarSection.Name) -> [MenuBarItem] {
            self[section]
        }

        /// Returns the address for the menu bar item with the given tag,
        /// if it exists in the cache.
        func address(for tag: MenuBarItemTag) -> (section: MenuBarSection.Name, index: Int)? {
            for (section, items) in storage {
                guard let index = items.firstIndex(matching: tag) else {
                    continue
                }
                return (section, index)
            }
            return nil
        }

        /// Inserts the given menu bar item into the cache at the specified
        /// destination.
        mutating func insert(_ item: MenuBarItem, at destination: MoveDestination) {
            let targetTag = destination.targetItem.tag

            if targetTag == .hiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.hidden].append(item)
                case .rightOfItem:
                    self[.visible].insert(item, at: 0)
                }
                return
            }

            if targetTag == .alwaysHiddenControlItem {
                switch destination {
                case .leftOfItem:
                    self[.alwaysHidden].append(item)
                case .rightOfItem:
                    self[.hidden].insert(item, at: 0)
                }
                return
            }

            guard case (let section, var index)? = address(for: targetTag) else {
                return
            }

            if case .rightOfItem = destination {
                let range = self[section].startIndex ... self[section].endIndex
                index = (index + 1).clamped(to: range)
            }

            self[section].insert(item, at: index)
        }

        /// Accesses the items in the given section.
        subscript(section: MenuBarSection.Name) -> [MenuBarItem] {
            get { storage[section, default: []] }
            set { storage[section] = newValue }
        }
    }

    /// A pair of control items, taken from a list of menu bar items
    /// during a menu bar item cache operation.
    private struct ControlItemPair {
        let hidden: MenuBarItem
        let alwaysHidden: MenuBarItem?

        init?(items: inout [MenuBarItem]) {
            guard let hidden = items.removeFirst(matching: .hiddenControlItem) else {
                return nil
            }
            self.hidden = hidden
            alwaysHidden = items.removeFirst(matching: .alwaysHiddenControlItem)
        }
    }

    /// Context maintained during a menu bar item cache operation.
    private struct CacheContext {
        let controlItems: ControlItemPair

        var cache: ItemCache
        var temporarilyShownItems = [(MenuBarItem, MoveDestination)]()
        var shouldClearCachedItemWindowIDs = false
        var relocatedItems = [MenuBarItem]()

        private(set) lazy var hiddenControlItemBounds = bestBounds(for: controlItems.hidden)
        private(set) lazy var alwaysHiddenControlItemBounds = controlItems.alwaysHidden.map(bestBounds)

        init(controlItems: ControlItemPair, displayID: CGDirectDisplayID?) {
            self.controlItems = controlItems
            cache = ItemCache(displayID: displayID)
        }

        func bestBounds(for item: MenuBarItem) -> CGRect {
            Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
        }

        func isValidForCaching(_ item: MenuBarItem) -> Bool {
            if !item.canBeHidden {
                return false
            }
            if item.isSystemClone {
                return false
            }
            if item.isControlItem, item.tag != .visibleControlItem {
                return false
            }
            return true
        }

        mutating func findSection(for item: MenuBarItem) -> MenuBarSection.Name? {
            lazy var itemBounds = bestBounds(for: item)
            return MenuBarSection.Name.allCases.first { section in
                switch section {
                case .visible:
                    return itemBounds.minX >= hiddenControlItemBounds.maxX
                case .hidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX &&
                            itemBounds.minX >= alwaysHiddenControlItemBounds.maxX
                    } else {
                        return itemBounds.maxX <= hiddenControlItemBounds.minX
                    }
                case .alwaysHidden:
                    if let alwaysHiddenControlItemBounds {
                        return itemBounds.maxX <= alwaysHiddenControlItemBounds.minX
                    } else {
                        return false
                    }
                }
            }
        }
    }

    /// Caches the given menu bar items, without ensuring that the provided
    /// control items are correctly ordered.
    private func uncheckedCacheItems(
        items: [MenuBarItem],
        controlItems: ControlItemPair,
        displayID: CGDirectDisplayID?
    ) async {
        diagLog.debug("uncheckedCacheItems: processing \(items.count) items for caching")
        var context = CacheContext(controlItems: controlItems, displayID: displayID)

        var validCount = 0
        var invalidCount = 0
        var noSectionCount = 0

        // Track which tags have already been cached to avoid duplicates.
        // macOS can briefly report two windows for the same item during
        // or shortly after a move operation (e.g. layout reset). We keep
        // the first occurrence, which is the rightmost (items are reversed
        // from the Window Server order).
        var seenTags = Set<MenuBarItemTag>()

        for item in items where context.isValidForCaching(item) {
            guard seenTags.insert(item.tag).inserted else {
                diagLog.debug("uncheckedCacheItems: skipping duplicate tag \(item.logString)")
                continue
            }

            validCount += 1
            if item.sourcePID == nil {
                logger.warning("Missing sourcePID for \(item.logString, privacy: .public)")
            }

            if let temp = temporarilyShownItemContexts.first(where: { $0.tag == item.tag }) {
                // Cache temporarily shown items as if they were in their original locations.
                // Keep track of them separately and use their return destinations to insert
                // them into the cache once all other items have been handled.
                context.temporarilyShownItems.append((item, temp.returnDestination))
                continue
            }

            if let section = context.findSection(for: item) {
                context.cache[section].append(item)
                continue
            }

            noSectionCount += 1
            diagLog.warning("Couldn't find section for caching \(item.logString) bounds=\(NSStringFromRect(item.bounds))")
            context.shouldClearCachedItemWindowIDs = true
        }

        // Count invalid items
        for item in items where !context.isValidForCaching(item) {
            invalidCount += 1
        }

        diagLog.debug("uncheckedCacheItems: \(validCount) valid, \(invalidCount) invalid (filtered), \(noSectionCount) couldn't find section, \(context.temporarilyShownItems.count) temporarily shown")

        for (item, destination) in context.temporarilyShownItems {
            context.cache.insert(item, at: destination)
        }

        if context.shouldClearCachedItemWindowIDs {
            logger.info("Clearing cached menu bar item windowIDs")
            await cacheActor.clearCachedItemWindowIDs() // Ensure next cache isn't skipped.
        }

        guard itemCache != context.cache else {
            logger.debug("Not updating menu bar item cache, as items haven't changed")
            return
        }

        itemCache = context.cache
        diagLog.debug("Updated menu bar item cache: visible=\(context.cache[.visible].count), hidden=\(context.cache[.hidden].count), alwaysHidden=\(context.cache[.alwaysHidden].count)")
    }

    /// Caches the current menu bar items, regardless of whether the
    /// items have changed since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsRegardless(
        _ currentItemWindowIDs: [CGWindowID]? = nil,
        skipRecentMoveCheck: Bool = false
    ) async {
        diagLog.debug("cacheItemsRegardless: entering (skipRecentMoveCheck=\(skipRecentMoveCheck), hasCurrentItemWindowIDs=\(currentItemWindowIDs != nil))")
        await cacheActor.runCacheTask { [weak self] in
            guard let self else {
                self?.diagLog.warning("cacheItemsRegardless: self is nil, aborting")
                return
            }

            guard skipRecentMoveCheck || !lastMoveOperationOccurred(within: .seconds(1)) else {
                logger.debug("Skipping menu bar item cache due to recent item movement")
                return
            }

            let previousWindowIDs = await cacheActor.cachedItemWindowIDs
            let displayID = Bridging.getActiveMenuBarDisplayID()
            diagLog.debug("cacheItemsRegardless: displayID=\(displayID.map { "\($0)" } ?? "nil"), previousWindowIDs count=\(previousWindowIDs.count)")

            var items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
            diagLog.debug("cacheItemsRegardless: getMenuBarItems returned \(items.count) items")

            if items.isEmpty {
                diagLog.warning("cacheItemsRegardless: getMenuBarItems returned ZERO items — this is likely the root cause of 'Loading menu bar items' being stuck")
            }

            let itemWindowIDs = currentItemWindowIDs ?? items.reversed().map { $0.windowID }
            await cacheActor.updateCachedItemWindowIDs(itemWindowIDs)

            await MainActor.run {
                MenuBarItemTag.Namespace.pruneUUIDCache(keeping: Set(itemWindowIDs))
                self.pruneMoveOperationTimeouts(keeping: Set(items.map(\.tag)))
            }

            guard let controlItems = ControlItemPair(items: &items) else {
                // ???: Is clearing the cache the best thing to do here?
                logger.warning("Missing control item for hidden section, clearing menu bar item cache. Items found: \(items.count), windowIDs: \(itemWindowIDs.count)")
                itemCache = ItemCache(displayID: nil)
                return
            }

            diagLog.debug("cacheItemsRegardless: found control items, hidden windowID=\(controlItems.hidden.windowID), alwaysHidden=\(controlItems.alwaysHidden.map { "\($0.windowID)" } ?? "nil")")

            await enforceControlItemOrder(controlItems: controlItems)

            if await relocateNewLeftmostItems(
                items,
                controlItems: controlItems,
                previousWindowIDs: previousWindowIDs
            ) {
                logger.debug("Relocated new leftmost items; scheduling recache")
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    await self?.cacheItemsRegardless(skipRecentMoveCheck: true)
                }
                return
            }

            if await relocatePendingItems(items, controlItems: controlItems) {
                logger.debug("Relocated pending temporarily-shown items; scheduling recache")
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    await self?.cacheItemsRegardless(skipRecentMoveCheck: true)
                }
                return
            }

            await uncheckedCacheItems(items: items, controlItems: controlItems, displayID: displayID)
            diagLog.debug("cacheItemsRegardless: finished, cache now has \(self.itemCache.managedItems.count) managed items")
        }
    }

    /// Caches the current menu bar items, if the items have changed
    /// since the previous cache.
    ///
    /// Before caching, this method ensures that the control items for
    /// the hidden and always-hidden sections are correctly ordered,
    /// arranging them into valid positions if needed.
    func cacheItemsIfNeeded() async {
        let itemWindowIDs = Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace])
        let cachedIDs = await cacheActor.cachedItemWindowIDs
        if cachedIDs != itemWindowIDs {
            diagLog.debug("cacheItemsIfNeeded: window IDs changed (\(cachedIDs.count) cached vs \(itemWindowIDs.count) current), triggering recache")
            await cacheItemsRegardless(itemWindowIDs)
        }
    }
}

// MARK: - Event Helpers

extension MenuBarItemManager {
    /// An error that can occur during menu bar item event operations.
    enum EventError: CustomStringConvertible, LocalizedError {
        /// A generic indication of a failure.
        case cannotComplete
        /// An event source cannot be created or is otherwise invalid.
        case invalidEventSource
        /// The location of the mouse cannot be found.
        case missingMouseLocation
        /// A failure during the creation of an event.
        case eventCreationFailure(MenuBarItem)
        /// A timeout during an event operation.
        case eventOperationTimeout(MenuBarItem)
        /// A menu bar item is not movable.
        case itemNotMovable(MenuBarItem)
        /// A timeout waiting for a menu bar item to respond to an event.
        case itemResponseTimeout(MenuBarItem)
        /// A menu bar item's bounds cannot be found.
        case missingItemBounds(MenuBarItem)

        var description: String {
            switch self {
            case .cannotComplete:
                "\(Self.self).cannotComplete"
            case .invalidEventSource:
                "\(Self.self).invalidEventSource"
            case .missingMouseLocation:
                "\(Self.self).missingMouseLocation"
            case let .eventCreationFailure(item):
                "\(Self.self).eventCreationFailure(item: \(item.tag))"
            case let .eventOperationTimeout(item):
                "\(Self.self).eventOperationTimeout(item: \(item.tag))"
            case let .itemNotMovable(item):
                "\(Self.self).itemNotMovable(item: \(item.tag))"
            case let .itemResponseTimeout(item):
                "\(Self.self).itemResponseTimeout(item: \(item.tag))"
            case let .missingItemBounds(item):
                "\(Self.self).missingItemBounds(item: \(item.tag))"
            }
        }

        var errorDescription: String? {
            switch self {
            case .cannotComplete:
                "Operation could not be completed"
            case .invalidEventSource:
                "Invalid event source"
            case .missingMouseLocation:
                "Missing mouse location"
            case let .eventCreationFailure(item):
                "Could not create event for \"\(item.displayName)\""
            case let .eventOperationTimeout(item):
                "Event operation timed out for \"\(item.displayName)\""
            case let .itemNotMovable(item):
                "\"\(item.displayName)\" is not movable"
            case let .itemResponseTimeout(item):
                "\"\(item.displayName)\" took too long to respond"
            case let .missingItemBounds(item):
                "Missing bounds rectangle for \"\(item.displayName)\""
            }
        }

        var recoverySuggestion: String? {
            if case .itemNotMovable = self { return nil }
            return "Please try again. If the error persists, please file a bug report."
        }
    }

    /// Returns a Boolean value that indicates whether the user has
    /// paused input for at least the given duration.
    ///
    /// - Parameter duration: The duration that certain types of input
    ///   events must not have occured within in order to return `true`.
    private nonisolated func hasUserPausedInput(for duration: Duration) -> Bool {
        NSEvent.modifierFlags.isEmpty &&
            !MouseHelpers.lastMovementOccurred(within: duration) &&
            !MouseHelpers.lastScrollWheelOccurred(within: duration) &&
            !MouseHelpers.isButtonPressed()
    }

    /// Waits asynchronously for the user to pause input.
    private nonisolated func waitForUserToPauseInput() async throws {
        let waitTask = Task {
            while true {
                try Task.checkCancellation()
                if hasUserPausedInput(for: .milliseconds(50)) {
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        do {
            try await waitTask.value
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Waits between move operations for a dynamic amount of time,
    /// based on the timestamp of the last move operation.
    private nonisolated func waitForMoveOperationBuffer() async throws {
        if let timestamp = await lastMoveOperationTimestamp {
            let buffer = max(.milliseconds(25) - timestamp.duration(to: .now), .zero)
            logger.debug("Move operation buffer: \(buffer)")
            do {
                try await Task.sleep(for: buffer)
            } catch {
                throw EventError.cannotComplete
            }
        }
    }

    /// Waits for the given duration between event operations.
    ///
    /// Since most event operations must perform cleanup or otherwise
    /// run to completion, this method ignores task cancellation.
    private nonisolated func eventSleep(for duration: Duration = .milliseconds(25)) async {
        let task = Task {
            try? await Task.sleep(for: duration)
        }
        await task.value
    }

    /// Returns the current bounds for the given item, with a refresh fallback if the window is missing.
    private nonisolated func getCurrentBounds(for item: MenuBarItem) async throws -> CGRect {
        // First attempt: current windowID.
        if let bounds = Bridging.getWindowBounds(for: item.windowID) {
            return bounds
        }

        // Fallback: refresh on-screen items and pick the matching tag (prefer same windowID, then non-clone).
        let refreshed = await MenuBarItem.getMenuBarItems(option: .onScreen)
        if let refreshedItem = refreshed.first(where: { $0.windowID == item.windowID && $0.tag == item.tag }) ??
            refreshed.first(where: { $0.tag == item.tag && !$0.isSystemClone }) ??
            refreshed.first(where: { $0.tag == item.tag })
        {
            return refreshedItem.bounds
        }

        throw EventError.missingItemBounds(item)
    }

    /// Returns the current mouse location.
    private nonisolated func getMouseLocation() throws -> CGPoint {
        guard let location = MouseHelpers.locationCoreGraphics else {
            throw EventError.missingMouseLocation
        }
        return location
    }

    /// Returns the process identifier that can be used to create
    /// and post a menu bar item event.
    private nonisolated func getEventPID(for item: MenuBarItem) -> pid_t {
        item.sourcePID ?? item.ownerPID
    }

    /// Returns an event source for a menu bar item event operation.
    private nonisolated func getEventSource(
        with stateID: CGEventSourceStateID = .hidSystemState
    ) throws -> CGEventSource {
        enum Context {
            static var cache = [CGEventSourceStateID: CGEventSource]()
        }
        if let source = Context.cache[stateID] {
            return source
        }
        guard let source = CGEventSource(stateID: stateID) else {
            throw EventError.invalidEventSource
        }
        Context.cache[stateID] = source
        return source
    }

    /// Prevents local events from being suppressed.
    private nonisolated func permitLocalEvents() throws {
        let source = try getEventSource(with: .combinedSessionState)
        let states: [CGEventSuppressionState] = [
            .eventSuppressionStateRemoteMouseDrag,
            .eventSuppressionStateSuppressionInterval,
        ]
        for state in states {
            source.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
        }
        source.localEventsSuppressionInterval = 0
    }

    /// Posts an event to the given menu bar item and waits until
    /// it is received before returning.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `postEventWithBarrier`.
    private nonisolated func postEventWithBarrier(
        _ event: CGEvent,
        to item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let pid = getEventPID(for: item)
        event.setTargetPID(pid)

        let firstLocation = EventTap.Location.pid(pid)
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        var eventTaps = [EventTap]()

        defer {
            for tap in eventTaps {
                tap.invalidate()
            }
        }

        let timeoutTask = Task(timeout: timeout * count) {
            try await withCheckedThrowingContinuation { continuation in
                // Listen for the following events at the first location
                // and perform the following actions:
                //
                // - Entry event: Decrement the count and post the real
                //   event to the second location (handled in EventTap 2).
                // - Exit event: Resume the continuation.
                //
                // These events serve as start (or continue) and stop
                // signals, and are discarded.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    type: .null,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        count -= 1
                        event.post(to: secondLocation)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        continuation.resume()
                        return nil
                    }
                    return rEvent
                }

                // Listen for the real event at the second location and,
                // depending on the count, post either the entry or exit
                // event to the first location (handled in EventTap 1).
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                        exitEvent.post(to: firstLocation)
                    } else {
                        entryEvent.post(to: firstLocation)
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Keep the taps alive.
                eventTaps.append(eventTap1)
                eventTaps.append(eventTap2)

                Task {
                    await withTaskCancellationHandler {
                        eventTap1.enable()
                        eventTap2.enable()
                        entryEvent.post(to: firstLocation)
                    } onCancel: {
                        eventTap1.disable()
                        eventTap2.disable()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }
        do {
            try await timeoutTask.value
        } catch is TaskTimeoutError {
            throw EventError.eventOperationTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Casts forbidden magic to make a menu bar item receive and
    /// respond to an event during a move operation.
    ///
    /// - Parameters:
    ///   - event: The event to post.
    ///   - item: The menu bar item that the event targets.
    ///   - timeout: The base duration to wait before throwing an error.
    ///     The value of this parameter is multiplied by `count` to
    ///     produce the actual timeout duration.
    ///   - count: The number of times to repeat the operation. As it
    ///     is considerably more efficient, prefer increasing this value
    ///     over repeatedly calling `scrombleEvent`.
    private nonisolated func scrombleEvent(
        _ event: CGEvent,
        item: MenuBarItem,
        timeout: Duration,
        repeating count: Int = 1
    ) async throws {
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        guard
            let entryEvent = CGEvent.uniqueNullEvent(),
            let exitEvent = CGEvent.uniqueNullEvent()
        else {
            throw EventError.eventCreationFailure(item)
        }

        let pid = getEventPID(for: item)
        event.setTargetPID(pid)

        let firstLocation = EventTap.Location.pid(pid)
        let secondLocation = EventTap.Location.sessionEventTap

        var count = count
        var eventTaps = [EventTap]()

        defer {
            for tap in eventTaps {
                tap.invalidate()
            }
        }

        let timeoutTask = Task(timeout: timeout * count) {
            try await withCheckedThrowingContinuation { continuation in
                // Listen for the following events at the first location
                // and perform the following actions:
                //
                // - Entry event: Decrement the count and post the real
                //   event to the second location (handled in EventTap 2).
                // - Exit event: Resume the continuation.
                //
                // These events serve as start (or continue) and stop
                // signals, and are discarded.
                let eventTap1 = EventTap(
                    label: "EventTap 1",
                    type: .null,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .defaultTap
                ) { tap, rEvent in
                    if rEvent.matches(entryEvent, byIntegerFields: [.eventSourceUserData]) {
                        count -= 1
                        event.post(to: secondLocation)
                        return nil
                    }
                    if rEvent.matches(exitEvent, byIntegerFields: [.eventSourceUserData]) {
                        tap.disable()
                        continuation.resume()
                        return nil
                    }
                    return rEvent
                }

                // Listen for the real event at the second location and
                // post the real event to the first location (handled in
                // EventTap 3).
                let eventTap2 = EventTap(
                    label: "EventTap 2",
                    type: event.type,
                    location: secondLocation,
                    placement: .tailAppendEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                    }
                    event.post(to: firstLocation)
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Listen for the real event at the first location and,
                // depending on the count, post either the entry or exit
                // event to the first location (handled in EventTap 1).
                let eventTap3 = EventTap(
                    label: "EventTap 3",
                    type: event.type,
                    location: firstLocation,
                    placement: .headInsertEventTap,
                    option: .listenOnly
                ) { tap, rEvent in
                    guard rEvent.matches(event, byIntegerFields: CGEventField.menuBarItemEventFields) else {
                        return rEvent
                    }
                    if count <= 0 {
                        tap.disable()
                        exitEvent.post(to: firstLocation)
                    } else {
                        entryEvent.post(to: firstLocation)
                    }
                    rEvent.setTargetPID(pid)
                    return rEvent
                }

                // Keep the taps alive.
                eventTaps.append(eventTap1)
                eventTaps.append(eventTap2)
                eventTaps.append(eventTap3)

                Task {
                    await withTaskCancellationHandler {
                        eventTap1.enable()
                        eventTap2.enable()
                        eventTap3.enable()
                        entryEvent.post(to: firstLocation)
                    } onCancel: {
                        eventTap1.disable()
                        eventTap2.disable()
                        eventTap3.disable()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }
        do {
            try await timeoutTask.value
        } catch is TaskTimeoutError {
            throw EventError.eventOperationTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }
}

// MARK: - Moving Items

extension MenuBarItemManager {
    /// Destinations for menu bar item move operations.
    enum MoveDestination {
        /// The destination to the left of the given target item.
        case leftOfItem(MenuBarItem)
        /// The destination to the right of the given target item.
        case rightOfItem(MenuBarItem)

        /// The destination's target item.
        var targetItem: MenuBarItem {
            switch self {
            case let .leftOfItem(item), let .rightOfItem(item): item
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case let .leftOfItem(item): "left of \(item.logString)"
            case let .rightOfItem(item): "right of \(item.logString)"
            }
        }
    }

    /// Returns the default timeout for move operations associated
    /// with the given item.
    private func getDefaultMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if item.isBentoBox {
            // Bento Boxes (i.e. Control Center groups) generally
            // take a little longer to respond.
            return .milliseconds(100)
        }
        return .milliseconds(50)
    }

    /// Returns the cached timeout for move operations associated
    /// with the given item.
    private func getMoveOperationTimeout(for item: MenuBarItem) -> Duration {
        if let timeout = moveOperationTimeouts[item.tag] {
            return timeout
        }
        return getDefaultMoveOperationTimeout(for: item)
    }

    /// Updates the cached timeout for move operations associated
    /// with the given item.
    private func updateMoveOperationTimeout(_ timeout: Duration, for item: MenuBarItem) {
        let current = getMoveOperationTimeout(for: item)
        let average = (timeout + current) / 2
        let clamped = average.clamped(min: .milliseconds(25), max: .milliseconds(150))
        moveOperationTimeouts[item.tag] = clamped
    }

    /// Prunes the move operation timeouts cache, keeping only the entries
    /// for the given valid tags.
    private func pruneMoveOperationTimeouts(keeping validTags: Set<MenuBarItemTag>) {
        moveOperationTimeouts = moveOperationTimeouts.filter { validTags.contains($0.key) }
    }

    /// Returns the target points for creating the events needed to
    /// move a menu bar item to the given destination.
    private nonisolated func getTargetPoints(
        forMoving item: MenuBarItem,
        to destination: MoveDestination
    ) async throws -> (start: CGPoint, end: CGPoint) {
        let itemBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)

        var start: CGPoint
        var end: CGPoint

        switch destination {
        case .leftOfItem:
            start = CGPoint(x: targetBounds.minX, y: targetBounds.minY)
            end = start
            if itemBounds.maxX <= targetBounds.minX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x -= 1
            }
        case .rightOfItem:
            start = CGPoint(x: targetBounds.maxX, y: targetBounds.minY)
            end = start
            if itemBounds.minX <= targetBounds.maxX {
                // Direction of movement: ->
                end.x -= itemBounds.width
            } else {
                // Direction of movement: <-
                start.x += 1
            }
        }

        // Keep the initial press away from the Apple menu hit region. On macOS 14/15
        // AX can fail to provide the application menu frame; fall back to the leftmost
        // on-screen item to approximate a safe edge.
        if let screen = NSScreen.screenWithActiveMenuBar {
            let padding: CGFloat = 6
            let displayBounds = CGDisplayBounds(screen.displayID)

            var clampSource = "none"
            if #available(macOS 16.0, *) {
                var safeMaxX: CGFloat?
                if let menuFrame = screen.getApplicationMenuFrame() {
                    safeMaxX = menuFrame.maxX
                    clampSource = "axMenuFrame"
                }
                if safeMaxX == nil {
                    let items = await MenuBarItem.getMenuBarItems(option: .onScreen)
                    if let minX = items
                        .filter({ $0.bounds.intersects(displayBounds) })
                        .map(\.bounds.minX)
                        .min()
                    {
                        safeMaxX = max(displayBounds.minX + 60, minX - padding)
                        clampSource = "leftmostItem"
                    }
                }
                let fallback = displayBounds.minX + 80
                start.x = max(start.x, (safeMaxX ?? fallback) + padding)
            } else {
                // macOS 14/15: avoid over-estimating the Apple menu region; clamp only within the target display band.
                let guardMin = displayBounds.minX + 80
                let guardMax = targetBounds.minX - 2
                start.x = min(max(start.x, guardMin), guardMax)
                clampSource = "guardBand"
            }

            // Keep event coordinates away from screen corners to avoid
            // triggering macOS hot corners. Hot corners activate when the
            // cursor reaches both the extreme x and y of a corner
            // simultaneously. Since menu bar events always use y values
            // near the top edge, offsetting y by a few pixels is enough
            // to prevent all top-corner activations without affecting the
            // x range needed for item moves.
            let cornerInset: CGFloat = 5
            start.y = max(start.y, displayBounds.minY + cornerInset)
            end.y = max(end.y, displayBounds.minY + cornerInset)

            let targetDisplay = CGDisplayBounds(screen.displayID).contains(targetBounds.origin) ? screen.displayID : CGMainDisplayID()
            let itemDisplay = CGDisplayBounds(screen.displayID).contains(itemBounds.origin) ? screen.displayID : CGMainDisplayID()
            logger.debug(
                "Move clamp source=\(clampSource, privacy: .public) startX=\(start.x, privacy: .public) targetMinX=\(targetBounds.minX, privacy: .public) itemMinX=\(itemBounds.minX, privacy: .public) targetTag=\(destination.targetItem.tag, privacy: .public) itemTag=\(item.tag, privacy: .public) clampDisplay=\(screen.displayID, privacy: .public) targetDisplay=\(targetDisplay, privacy: .public) itemDisplay=\(itemDisplay, privacy: .public)"
            )
        }
        return (start, end)
    }

    /// Returns a Boolean value that indicates whether the given menu bar
    /// item has the correct position, relative to the given destination.
    private nonisolated func itemHasCorrectPosition(
        item: MenuBarItem,
        for destination: MoveDestination
    ) async throws -> Bool {
        let itemBounds = try await getCurrentBounds(for: item)
        let targetBounds = try await getCurrentBounds(for: destination.targetItem)
        return switch destination {
        case .leftOfItem: itemBounds.maxX == targetBounds.minX
        case .rightOfItem: itemBounds.minX == targetBounds.maxX
        }
    }

    /// Waits for a menu bar item to respond to a series of previously
    /// posted move events.
    ///
    /// - Parameters:
    ///   - item: The item to check for a response.
    ///   - initialOrigin: The origin of the item before the events were posted.
    ///   - timeout: The duration to wait before throwing an error.
    private nonisolated func waitForMoveEventResponse(
        from item: MenuBarItem,
        initialOrigin: CGPoint,
        timeout: Duration
    ) async throws -> CGPoint {
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }
        let responseTask = Task.detached {
            while true {
                try Task.checkCancellation()
                let origin = try await self.getCurrentBounds(for: item).origin
                if origin != initialOrigin {
                    return origin
                }
            }
        }
        let timeoutTask = Task(timeout: timeout) {
            try await withTaskCancellationHandler {
                try await responseTask.value
            } onCancel: {
                responseTask.cancel()
            }
        }
        do {
            let origin = try await timeoutTask.value
            logger.debug(
                """
                Item responded to events with new origin: \
                \(String(describing: origin), privacy: .public)
                """
            )
            return origin
        } catch let error as EventError {
            throw error
        } catch is TaskTimeoutError {
            throw EventError.itemResponseTimeout(item)
        } catch {
            throw EventError.cannotComplete
        }
    }

    /// Creates and posts a series of events to move a menu bar item
    /// to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the menu bar item.
    private func postMoveEvents(item: MenuBarItem, destination: MoveDestination) async throws {
        try await eventSemaphore.wait()
        defer { Task.detached { [eventSemaphore] in await eventSemaphore.signal() } }

        var itemOrigin = try await getCurrentBounds(for: item).origin
        let targetPoints = try await getTargetPoints(forMoving: item, to: destination)
        let mouseLocation = try getMouseLocation()
        let source = try getEventSource()

        try permitLocalEvents()

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .move(.mouseDown),
                location: targetPoints.start
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: destination.targetItem,
                source: source,
                type: .move(.mouseUp),
                location: targetPoints.end
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        var timeout = getMoveOperationTimeout(for: item)
        logger.debug("Move operation timeout: \(timeout)")

        lastMoveOperationTimestamp = .now
        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.warpCursor(to: mouseLocation)
            MouseHelpers.showCursor()
            lastMoveOperationTimestamp = .now
            updateMoveOperationTimeout(timeout, for: item)
        }

        do {
            try await scrombleEvent(
                mouseDown,
                item: item,
                timeout: timeout
            )
            itemOrigin = try await waitForMoveEventResponse(
                from: item,
                initialOrigin: itemOrigin,
                timeout: timeout
            )
            try await scrombleEvent(
                mouseUp,
                item: item,
                timeout: timeout,
                repeating: 2 // Double mouse up prevents invalid item state.
            )
            itemOrigin = try await waitForMoveEventResponse(
                from: item,
                initialOrigin: itemOrigin,
                timeout: timeout
            )
            timeout -= timeout / 4
        } catch {
            do {
                logger.warning("Move events failed, posting fallback")
                try await scrombleEvent(
                    mouseUp,
                    item: item,
                    timeout: .milliseconds(100), // Fixed timeout for fallback.
                    repeating: 2 // Double mouse up prevents invalid item state.
                )
            } catch {
                // Catch this for logging purposes only. We want to propagate
                // the original error.
                logger.error("Fallback failed with error: \(error, privacy: .public)")
            }
            timeout += timeout / 2
            throw error
        }
    }

    /// Moves a menu bar item to the given destination.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to move.
    ///   - destination: The destination to move the item to.
    func move(
        item: MenuBarItem,
        to destination: MoveDestination,
        watchdogTimeout: DispatchTimeInterval? = nil
    ) async throws {
        guard item.isMovable else {
            throw EventError.itemNotMovable(item)
        }
        guard let appState else {
            throw EventError.cannotComplete
        }

        try await waitForUserToPauseInput()

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        try await waitForMoveOperationBuffer()

        logger.log(
            """
            Moving \(item.logString, privacy: .public) to \
            \(destination.logString, privacy: .public)
            """
        )

        guard try await !itemHasCorrectPosition(item: item, for: destination) else {
            logger.debug("Item has correct position, cancelling move")
            return
        }

        MouseHelpers.hideCursor(watchdogTimeout: watchdogTimeout)
        defer {
            MouseHelpers.showCursor()
        }

        let maxAttempts = 8
        for n in 1 ... maxAttempts {
            guard !Task.isCancelled else {
                throw EventError.cannotComplete
            }
            do {
                if try await itemHasCorrectPosition(item: item, for: destination) {
                    logger.debug("Item has correct position, finished with move")
                    return
                }
                try await postMoveEvents(item: item, destination: destination)
                // Verify the item actually reached the correct position. The
                // events may have been accepted but the item might not have
                // landed at the exact destination.
                if try await itemHasCorrectPosition(item: item, for: destination) {
                    logger.debug("Attempt \(n, privacy: .public) succeeded and verified, finished with move")
                    return
                }
                logger.debug("Attempt \(n, privacy: .public) events succeeded but item not at destination, retrying")
                if n < maxAttempts {
                    try await waitForMoveOperationBuffer()
                    continue
                }
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if n < maxAttempts {
                    try await waitForMoveOperationBuffer()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Clicking Items

extension MenuBarItemManager {
    /// Returns the equivalent event subtypes for clicking a menu bar
    /// item with the given mouse button.
    private nonisolated func getClickSubtypes(
        for mouseButton: CGMouseButton
    ) -> (down: MenuBarItemEventType.ClickSubtype, up: MenuBarItemEventType.ClickSubtype) {
        switch mouseButton {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
    }

    /// Creates and posts a series of events to click a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    private func postClickEvents(item: MenuBarItem, mouseButton: CGMouseButton) async throws {
        try await eventSemaphore.wait()
        defer { Task.detached { [eventSemaphore] in await eventSemaphore.signal() } }

        let clickPoint = try await getCurrentBounds(for: item).center
        let mouseLocation = try getMouseLocation()
        let source = try getEventSource()

        try permitLocalEvents()

        let clickTypes = getClickSubtypes(for: mouseButton)
        let timeout = Duration.milliseconds(250)

        guard
            let mouseDown = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.down),
                location: clickPoint
            ),
            let mouseUp = CGEvent.menuBarItemEvent(
                item: item,
                source: source,
                type: .click(clickTypes.up),
                location: clickPoint
            )
        else {
            throw EventError.eventCreationFailure(item)
        }

        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.warpCursor(to: mouseLocation)
            MouseHelpers.showCursor()
        }

        do {
            try await postEventWithBarrier(
                mouseDown,
                to: item,
                timeout: timeout
            )
            try await postEventWithBarrier(
                mouseUp,
                to: item,
                timeout: timeout,
                repeating: 2 // Double mouse up prevents invalid item state.
            )
        } catch {
            do {
                logger.warning("Click events failed, posting fallback")
                try await postEventWithBarrier(
                    mouseUp,
                    to: item,
                    timeout: timeout,
                    repeating: 2 // Double mouse up prevents invalid item state.
                )
            } catch {
                // Catch this for logging purposes only. We want to propagate
                // the original error.
                logger.error("Fallback failed with error: \(error, privacy: .public)")
            }
            throw error
        }
    }

    /// Clicks a menu bar item with the given mouse button.
    ///
    /// - Parameters:
    ///   - item: The menu bar item to click.
    ///   - mouseButton: The mouse button to click the item with.
    func click(item: MenuBarItem, with mouseButton: CGMouseButton) async throws {
        guard let appState else {
            throw EventError.cannotComplete
        }

        try await waitForUserToPauseInput()

        logger.log(
            """
            Clicking \(item.logString, privacy: .public) with \
            \(mouseButton.logString, privacy: .public)
            """
        )

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        let maxAttempts = 4
        for n in 1 ... maxAttempts {
            guard !Task.isCancelled else {
                throw EventError.cannotComplete
            }
            do {
                try await postClickEvents(item: item, mouseButton: mouseButton)
                logger.debug("Attempt \(n, privacy: .public) succeeded, finished with click")
                return
            } catch {
                logger.debug("Attempt \(n, privacy: .public) failed: \(error, privacy: .public)")
                if n < maxAttempts {
                    await eventSleep()
                    continue
                }
                if error is EventError {
                    throw error
                }
                throw EventError.cannotComplete
            }
        }
    }
}

// MARK: - Temporarily Showing Items

extension MenuBarItemManager {
    /// Context for a temporarily shown menu bar item.
    private final class TemporarilyShownItemContext {
        /// The tag associated with the item.
        let tag: MenuBarItemTag

        /// The PID of the application that owns this item, used to detect
        /// nonstandard popup windows that ``shownInterfaceWindow`` may miss.
        let sourcePID: pid_t

        /// The destination to return the item to.
        let returnDestination: MoveDestination

        /// The window of the item's shown interface.
        var shownInterfaceWindow: WindowInfo?

        /// The number of attempts that have been made to rehide the item.
        var rehideAttempts = 0

        /// Timestamp for when the item was first shown so we can honor
        /// a short grace period for menus that use nonstandard windows.
        private let firstShownDate = Date.now

        /// Minimum time to treat the item as "showing" even if we can't
        /// detect a popup window (helps apps with unusual window levels).
        private let graceInterval: TimeInterval = 2

        /// A Boolean value that indicates whether the menu bar item's
        /// interface is showing.
        var isShowingInterface: Bool {
            // First check the tracked popup window — this is the most
            // reliable signal when available.
            if let window = shownInterfaceWindow,
               let current = WindowInfo(windowID: window.windowID)
            {
                if current.layer == CGWindowLevelForKey(.popUpMenuWindow)
                    || current.layer == CGWindowLevelForKey(.popUpMenuWindow) - 1
                    || current.layer == CGWindowLevelForKey(.statusWindow)
                    || current.layer == CGWindowLevelForKey(.mainMenuWindow)
                {
                    return current.isOnScreen
                }
                if let app = current.owningApplication {
                    return app.isActive && current.isOnScreen
                }
                return current.isOnScreen
            }

            // The tracked window is gone or was never captured. During the
            // grace period, assume the interface is still showing to give
            // apps with nonstandard windows time to create them.
            if Date.now.timeIntervalSince(firstShownDate) < graceInterval {
                return true
            }

            // Grace period expired and no tracked window. Check whether the
            // app has any visible popup or overlay window that we missed.
            return appHasVisiblePopup()
        }

        /// Checks whether the item's owning application has any visible
        /// popup, menu, or overlay window on screen.
        private func appHasVisiblePopup() -> Bool {
            let windows = WindowInfo.createWindows(option: .onScreen)
            return windows.contains { window in
                guard window.ownerPID == sourcePID else {
                    return false
                }
                // Menu-level or status-level windows are popups.
                if window.isMenuRelated {
                    return true
                }
                // Above-normal layer windows (overlays, popovers) that
                // belong to the app also count.
                if window.layer > CGWindowLevelForKey(.normalWindow) {
                    return true
                }
                return false
            }
        }

        init(tag: MenuBarItemTag, sourcePID: pid_t, returnDestination: MoveDestination) {
            self.tag = tag
            self.sourcePID = sourcePID
            self.returnDestination = returnDestination
        }
    }

    /// Gets the destination to return the given item to after it is
    /// temporarily shown.
    private func getReturnDestination(for item: MenuBarItem, in items: [MenuBarItem]) -> MoveDestination? {
        guard let index = items.firstIndex(matching: item.tag) else {
            return nil
        }
        if items.indices.contains(index + 1) {
            return .leftOfItem(items[index + 1])
        }
        if items.indices.contains(index - 1) {
            return .rightOfItem(items[index - 1])
        }
        return nil
    }

    /// Waits for a menu bar item's position to stabilize after a move.
    ///
    /// After a Cmd+drag move, the Window Server updates the item's window
    /// position, but the owning app may take additional time to process the
    /// change internally. If we click the item before it has settled, the
    /// app may position its popup at the old location.
    ///
    /// This method polls the item's bounds until two consecutive reads
    /// return the same value, up to a maximum wait time.
    private nonisolated func waitForItemPositionToSettle(item: MenuBarItem) async {
        let maxWait: Duration = .milliseconds(500)
        let pollInterval: Duration = .milliseconds(50)
        let startTime = ContinuousClock.now

        var previousBounds = Bridging.getWindowBounds(for: item.windowID)

        while ContinuousClock.now - startTime < maxWait {
            await eventSleep(for: pollInterval)
            let currentBounds = Bridging.getWindowBounds(for: item.windowID)
            if currentBounds == previousBounds, currentBounds != nil {
                return
            }
            previousBounds = currentBounds
        }
    }

    /// Schedules a timer for the given interval that rehides the
    /// temporarily shown items when fired.
    private func runRehideTimer(for interval: TimeInterval? = nil) {
        guard let appState else {
            return
        }
        let interval = interval ?? appState.settings.advanced.tempShowInterval
        logger.debug("Running rehide timer for interval: \(interval, format: .fixed, privacy: .public)")
        rehideTimer?.invalidate()
        rehideCancellable?.cancel()
        rehideTimer = .scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            logger.debug("Rehide timer fired")
            Task {
                await self.rehideTemporarilyShownItems()
            }
        }
        // Also rehide when frontmost app changes (smart-ish).
        rehideCancellable = NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.rehideTemporarilyShownItems() }
            }
    }

    /// Temporarily shows the given item.
    ///
    /// The item is cached and returned to its original location after the
    /// time interval specified by ``AdvancedSettings/tempShowInterval``.
    ///
    /// - Parameters:
    ///   - item: The item to temporarily show.
    ///   - mouseButton: The mouse button to click the item with.
    func temporarilyShow(item: MenuBarItem, clickingWith mouseButton: CGMouseButton) async {
        guard let appState else {
            logger.error("Missing AppState, so not showing \(item.logString, privacy: .public)")
            return
        }

        // Rehide any previously temporarily shown items before showing a new one.
        // This prevents stale contexts from accumulating when the user opens multiple
        // temporary items in quick succession, which would leave earlier items stranded
        // in the visible section.
        if !temporarilyShownItemContexts.isEmpty {
            rehideTimer?.invalidate()
            rehideCancellable?.cancel()
            await rehideTemporarilyShownItems(force: true)
        }

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

        guard let destination = getReturnDestination(for: item, in: items) else {
            logger.error("No return destination for \(item.logString, privacy: .public)")
            return
        }

        // Prefer inserting to the left of the Thaw/visible control item so the icon appears
        // where users expect. If it’s missing, fall back to the first non-control item.
        let visibleControl = items.first(matching: .visibleControlItem)
        let targetItem = visibleControl ?? items.first(where: { !$0.isControlItem && $0.canBeHidden }) ?? items.first

        // If we couldn’t find any anchor, bail gracefully.
        guard let anchor = targetItem else {
            logger.warning("Not enough room or no anchor to show \(item.logString, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Not enough room to show \"\(item.displayName)\"")
            alert.runModal()
            return
        }

        let moveDestination: MoveDestination = .leftOfItem(anchor)

        // Record the item's original section so we can relocate it if its app
        // quits before we get a chance to rehide it (macOS persists the
        // physical position set by the Cmd+drag, so on relaunch the icon
        // would otherwise stay in the visible section).
        let tagIdentifier = "\(item.tag.namespace):\(item.tag.title)"
        if let originalSection = itemCache.address(for: item.tag)?.section {
            pendingRelocations[tagIdentifier] = sectionKey(for: originalSection)
            persistPendingRelocations()
        }

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        logger.debug("Temporarily showing \(item.logString, privacy: .public)")

        do {
            try await move(item: item, to: moveDestination)
        } catch {
            logger.error("Error showing item: \(error, privacy: .public)")
            pendingRelocations.removeValue(forKey: tagIdentifier)
            persistPendingRelocations()
            return
        }

        let context = TemporarilyShownItemContext(
            tag: item.tag,
            sourcePID: item.sourcePID ?? item.ownerPID,
            returnDestination: destination
        )
        temporarilyShownItemContexts.append(context)

        rehideTimer?.invalidate()
        defer {
            runRehideTimer()
        }

        // Wait for the item's position to stabilize after the move. Some
        // apps need time to process the window relocation before they can
        // correctly position their popup in response to a click.
        await waitForItemPositionToSettle(item: item)

        // Re-fetch the item from the live window list so we click using the
        // most up-to-date window information. Fall back to the original item
        // if it can't be found (the window ID is the same after a Cmd+drag,
        // but some apps recreate their status item in response to the move).
        let refreshedItems = await MenuBarItem.getMenuBarItems(option: .onScreen)
        let clickItem = refreshedItems.first(where: { $0.tag == item.tag }) ?? item

        // Give the owning app a little extra time to finish processing the
        // move internally. Some apps (e.g. OneDrive) need more than just a
        // stable window position before they can respond to clicks.
        await eventSleep(for: .milliseconds(75))

        let idsBeforeClick = Set(Bridging.getWindowList(option: .onScreen))

        do {
            try await click(item: clickItem, with: mouseButton)
        } catch {
            logger.error("Error clicking item: \(error, privacy: .public)")
            return
        }

        await eventSleep(for: .milliseconds(250))
        let windowsAfterClick = WindowInfo.createWindows(option: .onScreen)

        let clickPID = clickItem.sourcePID ?? clickItem.ownerPID
        context.shownInterfaceWindow = windowsAfterClick.first { window in
            window.ownerPID == clickPID && !idsBeforeClick.contains(window.windowID)
        }
    }

    /// Rehides all temporarily shown items.
    ///
    /// If an item is currently showing its interface, this method waits
    /// for the interface to close before hiding the items, unless `force`
    /// is `true`, in which case all items are rehidden immediately.
    ///
    /// - Parameter force: If `true`, skip the interface-showing and
    ///   user-input guards and rehide all items immediately.
    func rehideTemporarilyShownItems(force: Bool = false) async {
        guard let appState else {
            logger.error("Missing AppState, so not rehiding")
            return
        }
        guard !temporarilyShownItemContexts.isEmpty else {
            return
        }
        if !force {
            guard !temporarilyShownItemContexts.contains(where: { $0.isShowingInterface }) else {
                logger.debug("Menu bar item interface is shown, so waiting to rehide")
                runRehideTimer(for: 3)
                return
            }
            guard hasUserPausedInput(for: .milliseconds(250)) else {
                logger.debug("Found recent user input, so waiting to rehide")
                runRehideTimer(for: 1)
                return
            }
        }

        var currentContexts = temporarilyShownItemContexts
        temporarilyShownItemContexts.removeAll()

        let items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        var failedContexts = [TemporarilyShownItemContext]()

        appState.hidEventManager.stopAll()
        defer {
            appState.hidEventManager.startAll()
        }

        await eventSleep(for: .milliseconds(250))

        logger.debug("Rehiding temporarily shown items")

        MouseHelpers.hideCursor()
        defer {
            MouseHelpers.showCursor()
        }

        while let context = currentContexts.popLast() {
            guard let item = items.first(matching: context.tag) else {
                context.rehideAttempts += 1
                logger.debug(
                    """
                    Missing temporarily shown item \(context.tag, privacy: .public) on active space \
                    (attempt \(context.rehideAttempts, privacy: .public)); will retry
                    """
                )
                if context.rehideAttempts < 3 {
                    failedContexts.append(context)
                } else {
                    context.rehideAttempts = 0
                }
                continue
            }
            do {
                try await move(item: item, to: context.returnDestination)
                // Successfully rehidden — remove the pending relocation entry.
                let tagIdentifier = "\(context.tag.namespace):\(context.tag.title)"
                pendingRelocations.removeValue(forKey: tagIdentifier)
            } catch {
                context.rehideAttempts += 1
                logger.warning(
                    """
                    Attempt \(context.rehideAttempts, privacy: .public) to rehide \
                    \(item.logString, privacy: .public) failed with error: \
                    \(error, privacy: .public)
                    """
                )
                if context.rehideAttempts < 3 {
                    currentContexts.append(context) // Try again.
                } else {
                    // Failed contexts are ultimately added back to the array
                    // and rehidden after a longer delay, so reset the count.
                    context.rehideAttempts = 0
                    failedContexts.append(context)
                }
            }
        }

        persistPendingRelocations()

        if failedContexts.isEmpty {
            logger.debug("All items were successfully rehidden")
        } else {
            logger.error(
                """
                Some items failed to rehide or were missing; retrying: \
                \(failedContexts.map { $0.tag }, privacy: .public)
                """
            )
            temporarilyShownItemContexts.append(contentsOf: failedContexts.reversed())
            runRehideTimer(for: 3)
        }
    }

    /// Removes a temporarily shown item from the cache, ensuring that
    /// the item is _not_ returned to its original location.
    func removeTemporarilyShownItemFromCache(with tag: MenuBarItemTag) {
        while let index = temporarilyShownItemContexts.firstIndex(where: { $0.tag == tag }) {
            logger.debug(
                """
                Removing temporarily shown item from cache: \
                \(tag, privacy: .public)
                """
            )
            temporarilyShownItemContexts.remove(at: index)
        }
        // Also clear any pending relocation since the user explicitly
        // placed the item in a new position.
        let tagIdentifier = "\(tag.namespace):\(tag.title)"
        if pendingRelocations.removeValue(forKey: tagIdentifier) != nil {
            persistPendingRelocations()
        }
    }
}

// MARK: - Control Item Order

extension MenuBarItemManager {
    /// Relocates any newly appearing items that macOS placed to the left
    /// of our control items back into the visible section.
    ///
    /// Returns true if a relocation was performed.
    private func relocateNewLeftmostItems(
        _ items: [MenuBarItem],
        controlItems: ControlItemPair,
        previousWindowIDs: [CGWindowID]
    ) async -> Bool {
        guard appState != nil else { return false }

        if suppressNextNewLeftmostItemRelocation {
            // Seed known identifiers so these baseline items won't be treated as "new"
            // on subsequent cache passes, then clear the suppression flag.
            let identifiers = items
                .filter { !$0.isControlItem }
                .map { "\($0.tag.namespace):\($0.tag.title)" }
            knownItemIdentifiers.formUnion(identifiers)
            persistKnownItemIdentifiers()
            suppressNextNewLeftmostItemRelocation = false
            return false
        }

        // Avoid relocating items already assigned to hidden/always-hidden sections.
        let hiddenTags = Set(itemCache[.hidden].map(\.tag))
        let alwaysHiddenTags = Set(itemCache[.alwaysHidden].map(\.tag))

        /// Track bundle IDs for pinned items in hidden/always-hidden.
        func bundleID(for item: MenuBarItem) -> String? {
            item.sourceApplication?.bundleIdentifier ?? item.owningApplication?.bundleIdentifier
        }

        for item in itemCache[.hidden] {
            if let id = bundleID(for: item) {
                pinnedHiddenBundleIDs.insert(id)
            }
        }
        for item in itemCache[.alwaysHidden] {
            if let id = bundleID(for: item) {
                pinnedAlwaysHiddenBundleIDs.insert(id)
            }
        }
        persistPinnedBundleIDs()

        // Identify items that are to the left of the hidden control item bounds.
        let hiddenBounds = bestBounds(for: controlItems.hidden)
        let leftmostItems = items
            .filter {
                // Must be left of hidden divider, movable, hideable, non-control, and on-screen.
                $0.bounds.maxX <= hiddenBounds.minX &&
                    $0.isMovable &&
                    $0.canBeHidden &&
                    !$0.isControlItem
            }
            .sorted { $0.bounds.minX < $1.bounds.minX }

        guard !leftmostItems.isEmpty else {
            return false
        }

        // Identify a candidate that is new (windowID or tag/namespace) and not already placed/pinned in hidden areas.
        let previousIDs = Set(previousWindowIDs)
        let candidate = leftmostItems.first { item in
            let identifier = "\(item.tag.namespace):\(item.tag.title)"
            let isNewIdentity = !knownItemIdentifiers.contains(identifier)
            let isNewID = previousIDs.isEmpty ? isNewIdentity : !previousIDs.contains(item.windowID)
            let notPlacedHidden = !hiddenTags.contains(item.tag) && !alwaysHiddenTags.contains(item.tag)
            let bundle = bundleID(for: item)
            let notPinnedHidden = bundle.map { !pinnedHiddenBundleIDs.contains($0) && !pinnedAlwaysHiddenBundleIDs.contains($0) } ?? true
            return notPlacedHidden && notPinnedHidden && (isNewID || isNewIdentity)
        }
        guard let candidate else { return false }

        // Track this item so we don't move it again unless it truly appears new.
        let identifier = "\(candidate.tag.namespace):\(candidate.tag.title)"
        knownItemIdentifiers.insert(identifier)
        persistKnownItemIdentifiers()

        // Move only the offending item to the right of the hidden control item (i.e., into visible section).
        do {
            try await move(item: candidate, to: .rightOfItem(controlItems.hidden))
        } catch {
            logger.error("Failed to relocate \(candidate.logString, privacy: .public): \(error, privacy: .public)")
            return false
        }

        return true
    }

    /// Relocates items whose apps quit while they were temporarily shown
    /// in the visible section back to their original section.
    ///
    /// When `temporarilyShow` moves an item to the visible section, macOS
    /// persists that position. If the app quits before rehide can move it
    /// back, the icon will reappear in the visible section on relaunch.
    /// This method checks for such items and moves them back.
    ///
    /// Returns `true` if any items were relocated.
    private func relocatePendingItems(
        _ items: [MenuBarItem],
        controlItems: ControlItemPair
    ) async -> Bool {
        guard !pendingRelocations.isEmpty else {
            return false
        }

        // Don't interfere with items that are currently temporarily shown —
        // those are handled by the normal rehide flow.
        let activelyShownTags = Set(temporarilyShownItemContexts.map {
            "\($0.tag.namespace):\($0.tag.title)"
        })

        let hiddenBounds = bestBounds(for: controlItems.hidden)
        var didRelocate = false

        for (tagIdentifier, sectionString) in pendingRelocations {
            guard !activelyShownTags.contains(tagIdentifier) else {
                continue
            }
            guard let targetSection = sectionName(for: sectionString),
                  targetSection != .visible
            else {
                // Nothing to do if the original section was visible.
                pendingRelocations.removeValue(forKey: tagIdentifier)
                continue
            }

            // Find the item in the current menu bar items.
            guard let item = items.first(where: {
                tagIdentifier == "\($0.tag.namespace):\($0.tag.title)"
            }) else {
                // Item not present yet (app hasn't relaunched). Keep the entry.
                continue
            }

            // Check if the item is currently in the visible section (to the
            // right of the hidden control item).
            let itemBounds = bestBounds(for: item)
            guard itemBounds.minX >= hiddenBounds.maxX else {
                // Item is already in a hidden section — clean up.
                pendingRelocations.removeValue(forKey: tagIdentifier)
                continue
            }

            // Move the item back to the left of the hidden control item
            // (into the hidden section).
            let destination: MoveDestination
            switch targetSection {
            case .hidden:
                destination = .leftOfItem(controlItems.hidden)
            case .alwaysHidden:
                if let alwaysHidden = controlItems.alwaysHidden {
                    destination = .leftOfItem(alwaysHidden)
                } else {
                    destination = .leftOfItem(controlItems.hidden)
                }
            case .visible:
                continue
            }

            logger.info(
                """
                Relocating \(item.logString, privacy: .public) back to \
                \(targetSection.logString, privacy: .public) after app relaunch
                """
            )

            do {
                try await move(item: item, to: destination)
                pendingRelocations.removeValue(forKey: tagIdentifier)
                didRelocate = true
            } catch {
                logger.error(
                    """
                    Failed to relocate \(item.logString, privacy: .public) back to \
                    \(targetSection.logString, privacy: .public): \(error, privacy: .public)
                    """
                )
            }
        }

        persistPendingRelocations()
        return didRelocate
    }

    /// Returns the best-known bounds for a menu bar item.
    private func bestBounds(for item: MenuBarItem) -> CGRect {
        Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
    }

    /// Enforces the order of the given control items, ensuring that the
    /// control item for the always-hidden section is positioned to the
    /// left of control item for the hidden section.
    private func enforceControlItemOrder(controlItems: ControlItemPair) async {
        let hidden = controlItems.hidden

        guard
            let alwaysHidden = controlItems.alwaysHidden,
            hidden.bounds.maxX <= alwaysHidden.bounds.minX
        else {
            return
        }

        do {
            logger.debug("Control items have incorrect order")
            try await move(item: alwaysHidden, to: .leftOfItem(hidden))
        } catch {
            logger.error("Error enforcing control item order: \(error, privacy: .public)")
        }
    }

    /// Returns a Boolean value that indicates whether any menu bar item
    /// currently has a menu open.
    func isAnyMenuBarItemMenuOpen() async -> Bool {
        // Get all menu bar items that are currently on screen.
        let items = await MenuBarItem.getMenuBarItems(option: .onScreen)
        let sourcePIDs = Set(items.compactMap { $0.sourcePID })

        // Get all on-screen windows.
        let windows = WindowInfo.createWindows(option: .onScreen)

        logger.debug("Checking for open menus - Found \(items.count) menu bar items with PIDs: \(sourcePIDs)")

        // Check if any of the items' owning applications have a menu-related window.
        let result = windows.contains { window in
            // Skip Control Center windows as they can be falsely detected when hovering
            guard window.owningApplication?.bundleIdentifier != MenuBarItemTag.Namespace.controlCenter.description else {
                logger.debug("Skipping Control Center window: PID \(window.ownerPID), title: \(window.title ?? "nil")")
                return false
            }

            let isMenuOpen = sourcePIDs.contains(window.ownerPID) && window.isMenuRelated && (window.title?.isEmpty ?? true)
            if isMenuOpen {
                logger.debug("Found open menu window: PID \(window.ownerPID), owner: \(window.ownerName as NSObject?), title: \(window.title ?? "nil"), isMenuRelated: \(window.isMenuRelated)")
            }
            return isMenuOpen
        }

        logger.debug("Menu open check result: \(result)")
        return result
    }
}

// MARK: - MenuBarItemEventType

/// Event types for menu bar item events.
private enum MenuBarItemEventType {
    /// The event type for moving a menu bar item.
    case move(MoveSubtype)
    /// The event type for clicking a menu bar item.
    case click(ClickSubtype)

    var cgEventType: CGEventType {
        switch self {
        case let .move(subtype): subtype.cgEventType
        case let .click(subtype): subtype.cgEventType
        }
    }

    var cgEventFlags: CGEventFlags {
        switch self {
        case .move(.mouseDown): .maskCommand
        case .move, .click: []
        }
    }

    var cgMouseButton: CGMouseButton {
        switch self {
        case .move: .left
        case let .click(subtype): subtype.cgMouseButton
        }
    }

    // MARK: Subtypes

    /// Subtype for menu bar item move events.
    enum MoveSubtype {
        case mouseDown
        case mouseUp

        var cgEventType: CGEventType {
            switch self {
            case .mouseDown: .leftMouseDown
            case .mouseUp: .leftMouseUp
            }
        }
    }

    /// Subtype for menu bar item click events.
    enum ClickSubtype {
        case leftMouseDown
        case leftMouseUp
        case rightMouseDown
        case rightMouseUp
        case otherMouseDown
        case otherMouseUp

        var cgEventType: CGEventType {
            switch self {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .rightMouseDown: .rightMouseDown
            case .rightMouseUp: .rightMouseUp
            case .otherMouseDown: .otherMouseDown
            case .otherMouseUp: .otherMouseUp
            }
        }

        var cgMouseButton: CGMouseButton {
            switch self {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            case .otherMouseDown, .otherMouseUp: .center
            }
        }

        var clickState: Int64 {
            switch self {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: 1
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: 0
            }
        }
    }
}

// MARK: Layout Reset

extension MenuBarItemManager {
    /// Errors that can occur during a layout reset.
    enum LayoutResetError: LocalizedError {
        case missingAppState
        case missingControlItems

        var errorDescription: String? {
            switch self {
            case .missingAppState:
                "Unable to access app state"
            case .missingControlItems:
                "Couldn't find section dividers in the menu bar"
            }
        }

        var recoverySuggestion: String? {
            "Make sure \(Constants.displayName) is running and try again."
        }
    }

    /// Resets menu bar layout data to a fresh-install state and moves all
    /// movable, hideable items (except the Thaw icon) to the
    /// Hidden section.
    ///
    /// - Returns: The number of items that failed to move.
    func resetLayoutToFreshState() async throws -> Int {
        logger.info("Resetting menu bar layout to fresh state")

        guard let appState else {
            throw LayoutResetError.missingAppState
        }

        // Reset persisted state so macOS treats section dividers like new.
        ControlItemDefaults[.preferredPosition, ControlItem.Identifier.visible.rawValue] = 0
        ControlItemDefaults.resetChevronPositions()
        ControlItemDefaults[.preferredPosition, ControlItem.Identifier.alwaysHidden.rawValue] = nil

        // Forget previously seen/pinned items so we treat everything as new.
        knownItemIdentifiers.removeAll()
        pinnedHiddenBundleIDs.removeAll()
        pinnedAlwaysHiddenBundleIDs.removeAll()
        pendingRelocations.removeAll()
        persistKnownItemIdentifiers()
        persistPinnedBundleIDs()
        persistPendingRelocations()
        temporarilyShownItemContexts.removeAll()

        // Prevent the first post-reset cache pass from treating the freshly reset items as "new".
        suppressNextNewLeftmostItemRelocation = true

        var items = await MenuBarItem.getMenuBarItems(option: .activeSpace)

        guard let controlItems = ControlItemPair(items: &items) else {
            logger.error("Layout reset aborted: missing hidden section control item")

            // Attempt a forced restore by re-enabling the always hidden section flag and
            // nudging macOS to recreate control items, then retry once.
            if appState.settings.advanced.enableAlwaysHiddenSection {
                appState.settings.advanced.enableAlwaysHiddenSection = false
                try? await Task.sleep(for: .milliseconds(50))
                appState.settings.advanced.enableAlwaysHiddenSection = true
                try? await Task.sleep(for: .milliseconds(150))

                items = await MenuBarItem.getMenuBarItems(option: .activeSpace)
                if let retryControlItems = ControlItemPair(items: &items) {
                    logger.info("Recovered hidden section control item after re-enabling always-hidden section")
                    return try await resetLayoutWithControlItems(controlItems: retryControlItems, items: items)
                }
            }

            throw LayoutResetError.missingControlItems
        }

        await enforceControlItemOrder(controlItems: controlItems)

        return try await resetLayoutWithControlItems(controlItems: controlItems, items: items)
    }

    private func resetLayoutWithControlItems(controlItems: ControlItemPair, items: [MenuBarItem]) async throws -> Int {
        let items = items

        func movePass(_ items: [MenuBarItem], anchor: MenuBarItem) async -> Int {
            var failed = 0
            for item in items {
                if item.tag == .visibleControlItem {
                    continue // Keep the Thaw icon in the visible section if enabled.
                }

                guard item.isMovable, item.canBeHidden, !item.isControlItem else {
                    continue
                }

                do {
                    try await move(
                        item: item,
                        to: .leftOfItem(anchor),
                        watchdogTimeout: Self.layoutWatchdogTimeout
                    )
                } catch {
                    failed += 1
                    logger.error("Failed to move \(item.logString, privacy: .public) during layout reset: \(error, privacy: .public)")
                }
            }
            return failed
        }

        _ = await movePass(items, anchor: controlItems.hidden)

        // Re-fetch and retry only items that are NOT yet in the hidden
        // section. This covers items still in the visible section (to the
        // right of the hidden control item) as well as items stuck in the
        // always-hidden section (to the left of the always-hidden control
        // item) when that section is enabled.
        var refreshedItems = await MenuBarItem.getMenuBarItems(option: .activeSpace)
        var failedMoves = 0
        if let refreshedControls = ControlItemPair(items: &refreshedItems) {
            let hiddenControlBounds = Bridging.getWindowBounds(for: refreshedControls.hidden.windowID)
                ?? refreshedControls.hidden.bounds
            let alwaysHiddenControlBounds = refreshedControls.alwaysHidden.flatMap {
                Bridging.getWindowBounds(for: $0.windowID) ?? $0.bounds
            }

            let notYetInHidden = refreshedItems.filter { item in
                guard item.isMovable, item.canBeHidden, !item.isControlItem,
                      item.tag != .visibleControlItem
                else {
                    return false
                }
                let bounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds

                // Still in the visible section (to the right of hidden control item).
                if bounds.minX >= hiddenControlBounds.maxX {
                    return true
                }
                // Still in the always-hidden section (to the left of always-hidden control item).
                if let ahBounds = alwaysHiddenControlBounds,
                   bounds.maxX <= ahBounds.minX
                {
                    return true
                }
                return false
            }
            if !notYetInHidden.isEmpty {
                logger.debug("Layout reset pass 2: \(notYetInHidden.count) items not yet in hidden section")
                failedMoves = await movePass(notYetInHidden, anchor: refreshedControls.hidden)
            }
        }

        await cacheActor.clearCachedItemWindowIDs()
        itemCache = ItemCache(displayID: nil)
        await cacheItemsRegardless(skipRecentMoveCheck: true)
        suppressNextNewLeftmostItemRelocation = false

        if let appState {
            await MainActor.run {
                appState.imageCache.clearAll()
                appState.imageCache.performCacheCleanup()
            }
            await appState.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)

            await MainActor.run {
                appState.objectWillChange.send()
            }
        }

        return failedMoves
    }

    /// Wrapper for UI callers; kept separate for clarity in call sites.
    @MainActor
    func resetLayoutFromSettingsPane() async throws -> Int {
        try await resetLayoutToFreshState()
    }
}

// MARK: - CGEventField Helpers

private extension CGEventField {
    /// Key to access a field that contains the event's window identifier.
    static let windowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    /// Fields that can be used to compare menu bar item events.
    static let menuBarItemEventFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .windowID,
    ]
}

// MARK: - CGEventFilterMask Helpers

private extension CGEventFilterMask {
    /// Specifies that all events should be permitted during event suppression states.
    static let permitAllEvents: CGEventFilterMask = [
        .permitLocalMouseEvents,
        .permitLocalKeyboardEvents,
        .permitSystemDefinedEvents,
    ]
}

// MARK: - CGEventType Helpers

private extension CGEventType {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .null: "null event"
        case .leftMouseDown: "leftMouseDown event"
        case .leftMouseUp: "leftMouseUp event"
        case .rightMouseDown: "rightMouseDown event"
        case .rightMouseUp: "rightMouseUp event"
        case .mouseMoved: "mouseMoved event"
        case .leftMouseDragged: "leftMouseDragged event"
        case .rightMouseDragged: "rightMouseDragged event"
        case .keyDown: "keyDown event"
        case .keyUp: "keyUp event"
        case .flagsChanged: "flagsChanged event"
        case .scrollWheel: "scrollWheel event"
        case .tabletPointer: "tabletPointer event"
        case .tabletProximity: "tabletProximity event"
        case .otherMouseDown: "otherMouseDown event"
        case .otherMouseUp: "otherMouseUp event"
        case .otherMouseDragged: "otherMouseDragged event"
        case .tapDisabledByTimeout: "tapDisabledByTimeout event"
        case .tapDisabledByUserInput: "tapDisabledByUserInput event"
        @unknown default: "unknown event"
        }
    }
}

// MARK: - CGMouseButton Helpers

private extension CGMouseButton {
    /// A string to use for logging purposes.
    var logString: String {
        switch self {
        case .left: "left mouse button"
        case .right: "right mouse button"
        case .center: "center mouse button"
        @unknown default: "unknown mouse button"
        }
    }
}

// MARK: - CGEvent Helpers

private extension CGEvent {
    /// Returns an event that can be sent to a menu bar item.
    ///
    /// - Parameters:
    ///   - item: The event's target item.
    ///   - source: The event's source.
    ///   - type: The event's specialized type.
    ///   - location: The event's location. Does not need to be
    ///     within the bounds of the item.
    static func menuBarItemEvent(
        item: MenuBarItem,
        source: CGEventSource,
        type: MenuBarItemEventType,
        location: CGPoint
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type.cgEventType,
            mouseCursorPosition: location,
            mouseButton: type.cgMouseButton
        ) else {
            return nil
        }
        event.setFlags(for: type)
        event.setUserData(ObjectIdentifier(event))
        event.setWindowID(item.windowID, for: type)
        event.setClickState(for: type)
        return event
    }

    /// Returns a null event with unique user data.
    static func uniqueNullEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else {
            return nil
        }
        event.setUserData(ObjectIdentifier(event))
        return event
    }

    /// Posts the event to the given event tap location.
    ///
    /// - Parameter location: The event tap location to post the event to.
    func post(to location: EventTap.Location) {
        let type = self.type
        Logger.menuBarItemManager.debug(
            """
            Posting \(type.logString, privacy: .public) \
            to \(location.logString, privacy: .public)
            """
        )
        switch location {
        case .hidEventTap: post(tap: .cghidEventTap)
        case .sessionEventTap: post(tap: .cgSessionEventTap)
        case .annotatedSessionEventTap: post(tap: .cgAnnotatedSessionEventTap)
        case let .pid(pid): postToPid(pid)
        }
    }

    /// Returns a Boolean value that indicates whether the given integer
    /// fields from this event are equivalent to the same integer fields
    /// from the specified event.
    ///
    /// - Parameters:
    ///   - other: The event to compare with this event.
    ///   - fields: The integer fields to check.
    func matches(_ other: CGEvent, byIntegerFields fields: [CGEventField]) -> Bool {
        fields.allSatisfy { field in
            getIntegerValueField(field) == other.getIntegerValueField(field)
        }
    }

    func setTargetPID(_ pid: pid_t) {
        let targetPID = Int64(pid)
        setIntegerValueField(.eventTargetUnixProcessID, value: targetPID)
    }

    private func setFlags(for type: MenuBarItemEventType) {
        flags = type.cgEventFlags
    }

    private func setUserData(_ bitPattern: ObjectIdentifier) {
        let userData = Int64(Int(bitPattern: bitPattern))
        setIntegerValueField(.eventSourceUserData, value: userData)
    }

    private func setWindowID(_ windowID: CGWindowID, for type: MenuBarItemEventType) {
        let windowID = Int64(windowID)

        setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowID)
        setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowID)

        if case .move = type {
            setIntegerValueField(.windowID, value: windowID)
        }
    }

    private func setClickState(for type: MenuBarItemEventType) {
        if case let .click(subtype) = type {
            setIntegerValueField(.mouseEventClickState, value: subtype.clickState)
        }
    }
}

// MARK: - Logger Helpers

private extension Logger {
    /// Logger for the menu bar item manager.
    static let menuBarItemManager = Logger(category: "MenuBarItemManager")
}
