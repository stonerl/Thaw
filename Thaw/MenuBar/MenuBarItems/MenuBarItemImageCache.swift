//
//  MenuBarItemImageCache.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa
import Combine
import OSLog

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// A representation of a captured menu bar item image.
    struct CapturedImage: Hashable {
        /// The base image.
        let cgImage: CGImage

        /// The scale factor of the image at the time of capture.
        let scale: CGFloat

        /// The image's size, applying ``scale``.
        var scaledSize: CGSize {
            CGSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        }

        /// The base image, converted to an `NSImage` and applying ``scale``.
        var nsImage: NSImage {
            NSImage(cgImage: cgImage, size: scaledSize)
        }
    }

    /// The result of an image capture operation.
    private struct CaptureResult {
        /// The successfully captured images.
        var images = [MenuBarItemTag: CapturedImage]()

        /// The menu bar items excluded from the capture.
        var excluded = [MenuBarItem]()
    }

    /// The cached item images, keyed by their corresponding tags.
    @Published private(set) var images = [MenuBarItemTag: CapturedImage]()

    /// Maximum number of images to cache to prevent memory growth
    private static let maxCacheSize = 200

    /// LRU tracking for cache entries
    private var accessOrder: [MenuBarItemTag] = []

    /// Failed capture tracking to skip repeatedly failing items
    private struct FailedCapture: Hashable {
        let tag: MenuBarItemTag
        let failureCount: Int
        let lastFailureTime: Date
    }

    private var failedCaptures: [MenuBarItemTag: FailedCapture] = [:]

    /// Configuration for failed capture handling
    private static let maxFailuresBeforeBlacklist = 3
    private static let blacklistCooldownSeconds: TimeInterval = 300 // 5 minutes

    /// Logger for the menu bar item image cache.
    private let logger = Logger(
        subsystem: "com.stonerl.Thaw",
        category: "MenuBarItemImageCache"
    )

    private let diagLog = DiagLog(category: "MenuBarItemImageCache")

    /// Queue to run cache operations.
    private let queue = DispatchQueue(
        label: "MenuBarItemImageCache",
        qos: .background
    )

    /// Image capture options.
    private let captureOption: CGWindowImageOption = [
        .boundsIgnoreFraming, .bestResolution,
    ]

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    // MARK: Setup

    /// Sets up the cache.
    @MainActor
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            // Monitor system memory pressure
            DispatchQueue.main.async {
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical],
                    queue: .main
                )
                source.setEventHandler { [weak self] in
                    self?.handleMemoryPressure()
                }
                source.resume()
                // Store source in a way that keeps it alive but allows cancellation?
                // For now, just let it run as long as the app is alive since it's global
            }

            Publishers.Merge3(
                // Update every 500ms at minimum.
                Timer.publish(every: 0.5, on: .main, in: .default).autoconnect()
                    .replace(with: ()),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(
                        for: NSWorkspace.activeSpaceDidChangeNotification
                    ),
                    NotificationCenter.default.publisher(
                        for: NSApplication.didChangeScreenParametersNotification
                    )
                )
                .replace(with: ()),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates()
                        .replace(with: ()),
                    appState.itemManager.$itemCache.removeDuplicates().replace(
                        with: ()
                    )
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.updateCache()
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Capturing Images

    /// Captures a composite image of the given items, then crops out an image
    /// for each item and returns the result.
    private nonisolated func compositeCapture(
        _ items: [MenuBarItem],
        scale: CGFloat
    ) -> CaptureResult {
        var result = CaptureResult()

        var windowIDs = [CGWindowID]()
        var storage = [CGWindowID: (MenuBarItem, CGRect)]()
        var boundsUnion = CGRect.null
        var boundsFailCount = 0

        for item in items {
            let windowID = item.windowID

            // Don't use `item.bounds`, it could be out of date.
            guard let bounds = Bridging.getWindowBounds(for: windowID) else {
                boundsFailCount += 1
                result.excluded.append(item)
                continue
            }

            windowIDs.append(windowID)
            storage[windowID] = (item, bounds)
            boundsUnion = boundsUnion.union(bounds)
        }

        if boundsFailCount > 0 {
            diagLog.warning("compositeCapture: \(boundsFailCount)/\(items.count) items had no bounds (getWindowBounds returned nil)")
        }

        let compositeImage = ScreenCapture.captureWindows(
            with: windowIDs,
            option: captureOption
        )

        guard let compositeImage else {
            diagLog.warning("compositeCapture: ScreenCapture.captureWindows returned nil for \(windowIDs.count) windows")
            result.excluded = items
            return result
        }

        let expectedWidth = boundsUnion.width * scale
        let actualWidth = CGFloat(compositeImage.width)
        guard actualWidth == expectedWidth else {
            diagLog.warning("compositeCapture: width mismatch — expected \(expectedWidth) (boundsUnion.width=\(boundsUnion.width) * scale=\(scale)) but got \(actualWidth). Image dimensions: \(compositeImage.width)x\(compositeImage.height)")
            result.excluded = items
            return result
        }

        guard !compositeImage.isTransparent() else {
            diagLog.warning("compositeCapture: composite image is fully transparent (\(compositeImage.width)x\(compositeImage.height)) — screen recording permission may not be effective")
            result.excluded = items
            return result
        }

        // Crop out each item from the composite.
        for windowID in windowIDs {
            guard let (item, bounds) = storage[windowID] else {
                continue
            }

            // Check if this item should be skipped due to repeated failures
            if shouldSkipCapture(for: item) {
                logger.debug(
                    "Skipping composite capture for repeatedly failing item: \(item.logString)"
                )
                result.excluded.append(item)
                continue
            }

            let cropRect = CGRect(
                x: (bounds.origin.x - boundsUnion.origin.x) * scale,
                y: (bounds.origin.y - boundsUnion.origin.y) * scale,
                width: bounds.width * scale,
                height: bounds.height * scale
            )

            guard
                let image = compositeImage.cropping(to: cropRect),
                !image.isTransparent()
            else {
                // Record failure
                recordCaptureFailure(for: item)
                result.excluded.append(item)
                continue
            }

            // Record success
            recordCaptureSuccess(for: item)
            result.images[item.tag] = CapturedImage(
                cgImage: image,
                scale: scale
            )
        }

        return result
    }

    /// Captures an image of each of the given items individually, then
    /// returns the result.
    private nonisolated func individualCapture(
        _ items: [MenuBarItem],
        scale: CGFloat
    ) -> CaptureResult {
        var result = CaptureResult()
        var capturedCount = 0
        var nilImageCount = 0
        var transparentCount = 0
        var skippedCount = 0

        for item in items {
            // Check if this item should be skipped due to repeated failures
            if shouldSkipCapture(for: item) {
                logger.debug(
                    "Skipping capture for repeatedly failing item: \(item.logString)"
                )
                skippedCount += 1
                result.excluded.append(item)
                continue
            }

            let image = ScreenCapture.captureWindow(
                with: item.windowID,
                option: captureOption
            )

            guard let image else {
                diagLog.debug("individualCapture: captureWindow returned nil for \(item.logString)")
                nilImageCount += 1
                recordCaptureFailure(for: item)
                result.excluded.append(item)
                continue
            }

            guard !image.isTransparent() else {
                diagLog.debug("individualCapture: captured image is transparent for \(item.logString) (\(image.width)x\(image.height))")
                transparentCount += 1
                recordCaptureFailure(for: item)
                result.excluded.append(item)
                continue
            }

            // Record success and cache
            capturedCount += 1
            recordCaptureSuccess(for: item)
            result.images[item.tag] = CapturedImage(
                cgImage: image,
                scale: scale
            )
        }

        diagLog.debug("individualCapture: \(items.count) items -> \(capturedCount) captured, \(nilImageCount) nil, \(transparentCount) transparent, \(skippedCount) skipped (blacklisted)")
        return result
    }

    /// Captures the images of the given menu bar items and returns the result.
    private nonisolated func captureImages(
        of items: [MenuBarItem],
        scale: CGFloat,
        appState: AppState
    ) async -> CaptureResult {
        // Use individual capture after a move operation, since composite capture
        // doesn't account for overlapping items.
        if await appState.itemManager.lastMoveOperationOccurred(
            within: .seconds(2)
        ) {
            logger.debug("Capturing individually due to recent item movement")
            return individualCapture(items, scale: scale)
        }

        let compositeResult = compositeCapture(items, scale: scale)

        if compositeResult.excluded.isEmpty {
            return compositeResult // All items captured successfully.
        }

        logger.notice(
            """
            Some items were excluded from composite capture. Attempting to capture \
            excluded items individually: \(compositeResult.excluded, privacy: .public)
            """
        )

        var individualResult = individualCapture(
            compositeResult.excluded,
            scale: scale
        )

        // Merge the successfully captured images from each result. Keep excluded
        // items as part of the result, so they can be logged elsewhere.
        individualResult.images.merge(compositeResult.images) { _, new in new }

        return individualResult
    }

    /// Captures the images of the menu bar items in the given section and returns
    /// a dictionary containing the images, keyed by their menu bar item tags.
    private func captureImages(
        for section: MenuBarSection.Name,
        scale: CGFloat,
        appState: AppState
    ) async -> [MenuBarItemTag: CapturedImage] {
        let items = await appState.itemManager.itemCache.managedItems(
            for: section
        )
        let captureResult = await captureImages(
            of: items,
            scale: scale,
            appState: appState
        )
        if !captureResult.excluded.isEmpty {
            logger.error(
                "Some items failed capture: \(captureResult.excluded, privacy: .public)"
            )
        }
        return captureResult.images
    }

    // MARK: Failed Capture Management

    /// Checks if an item should be skipped due to repeated capture failures.
    private func shouldSkipCapture(for item: MenuBarItem) -> Bool {
        guard let failed = failedCaptures[item.tag] else {
            return false
        }

        // If failed too many times and within cooldown period, skip
        if failed.failureCount >= Self.maxFailuresBeforeBlacklist {
            let timeSinceFailure = Date().timeIntervalSince(
                failed.lastFailureTime
            )
            if timeSinceFailure < Self.blacklistCooldownSeconds {
                return true
            } else {
                // Cooldown expired, reset failure count
                failedCaptures.removeValue(forKey: item.tag)
                return false
            }
        }

        return false
    }

    /// Records a capture failure for an item.
    private func recordCaptureFailure(for item: MenuBarItem) {
        let now = Date()
        let existing = failedCaptures[item.tag]

        if let existing = existing {
            failedCaptures[item.tag] = FailedCapture(
                tag: item.tag,
                failureCount: existing.failureCount + 1,
                lastFailureTime: now
            )
        } else {
            failedCaptures[item.tag] = FailedCapture(
                tag: item.tag,
                failureCount: 1,
                lastFailureTime: now
            )
        }

        // Clean up old failed entries
        cleanupOldFailedEntries()
    }

    /// Records a successful capture for an item (resets failure count).
    private func recordCaptureSuccess(for item: MenuBarItem) {
        failedCaptures.removeValue(forKey: item.tag)
    }

    /// Cleans up old failed capture entries that have expired.
    private func cleanupOldFailedEntries() {
        let cutoff = Date().addingTimeInterval(-Self.blacklistCooldownSeconds)
        failedCaptures = failedCaptures.filter { _, failed in
            failed.lastFailureTime > cutoff
        }
    }

    /// Handles memory pressure events
    private func handleMemoryPressure() {
        // Clear half the cache on memory warning
        if !images.isEmpty {
            let targetSize = images.count / 2
            let tagsToRemove = Array(
                accessOrder.prefix(images.count - targetSize)
            )

            for tag in tagsToRemove {
                images.removeValue(forKey: tag)
                accessOrder.removeAll { $0 == tag }
            }
            logger.info(
                "Memory pressure: Cleared \(tagsToRemove.count) items from cache"
            )
        }
    }

    // MARK: Cache Access

    /// Updates the access order for a given tag to mark it as most recently used.
    private func updateAccessOrder(for tag: MenuBarItemTag) {
        accessOrder.removeAll { $0 == tag }
        accessOrder.append(tag)
    }

    /// Gets an image from the cache and updates its access order.
    func image(for tag: MenuBarItemTag) -> CapturedImage? {
        guard let image = images[tag] else {
            return nil
        }
        updateAccessOrder(for: tag)
        return image
    }

    /// Returns the current cache size for monitoring purposes.
    var cacheSize: Int {
        images.count
    }

    /// Returns the current LRU order count for debugging.
    var accessOrderCount: Int {
        accessOrder.count
    }

    /// Validates cache entries and removes items with invalid window IDs.
    /// Returns the number of items removed during cleanup.
    @MainActor
    private func validateAndCleanupInvalidEntries() -> Int {
        guard let appState else { return 0 }

        var removedCount = 0
        let allValidTags = Set(
            appState.itemManager.itemCache.managedItems.map(\.tag)
        )

        // Remove cache entries for items that don't exist in the item cache
        // or have invalid/missing window information
        let invalidTags = images.keys.filter { tag in
            !allValidTags.contains(tag)
        }

        for invalidTag in invalidTags {
            images.removeValue(forKey: invalidTag)
            accessOrder.removeAll { $0 == invalidTag }
            removedCount += 1
        }

        if removedCount > 0 {
            logger.info(
                "Cache cleanup: removed \(removedCount) invalid entries with missing window information"
            )
        }

        return removedCount
    }

    /// Manually triggers cleanup of invalid cache entries.
    /// This can be called when you suspect memory issues with orphaned entries.
    @MainActor
    func performCacheCleanup() {
        let removedCount = validateAndCleanupInvalidEntries()
        let failedCleared = failedCaptures.count
        failedCaptures.removeAll()
        logger.info(
            "Manual cache cleanup completed: removed \(removedCount) invalid entries, cleared \(failedCleared) failed captures"
        )
    }

    /// Logs detailed cache information for debugging memory issues.
    /// This method is NOT called automatically - you must call it explicitly.
    func logCacheStatus(_ context: String = "Manual check") {
        let imageSize = images.count
        let lruSize = accessOrder.count
        let maxSize = Self.maxCacheSize
        let usagePercent = (imageSize * 100) / maxSize
        let failedCount = failedCaptures.count
        let blacklistedCount = failedCaptures.values.filter {
            $0.failureCount >= Self.maxFailuresBeforeBlacklist
        }.count

        logger.info(
            """
            === Image Cache Status: \(context) ===
            Cache size: \(imageSize)/\(maxSize) (\(usagePercent)% full)
            LRU order count: \(lruSize)
            Failed captures: \(failedCount) (blacklisted: \(blacklistedCount))
            Memory impact: ~\(imageSize * 100)KB (estimated)
            LRU order: \(self.accessOrder.map(\.description).joined(separator: ", "))
            ======================================
            """
        )
    }

    // MARK: Update Cache

    /// Updates the cache for the given sections, without checking whether
    /// caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            diagLog.warning("updateCacheWithoutChecks: appState is nil, aborting")
            return
        }

        let hasScreenRecording = await appState.hasPermission(.screenRecording)
        guard hasScreenRecording else {
            diagLog.debug("updateCacheWithoutChecks: no screen recording permission, aborting")
            return
        }

        guard let displayID = await appState.itemManager.itemCache.displayID else {
            diagLog.warning("updateCacheWithoutChecks: itemCache.displayID is nil, aborting")
            return
        }

        guard let screen = NSScreen.screens.first(where: {
            $0.displayID == displayID
        }) else {
            diagLog.warning("updateCacheWithoutChecks: no screen found for displayID \(displayID)")
            return
        }

        let scale = screen.backingScaleFactor
        var newImages = [MenuBarItemTag: CapturedImage]()

        for section in sections {
            guard await !appState.itemManager.itemCache[section].isEmpty else {
                continue
            }

            let sectionImages = await captureImages(
                for: section,
                scale: scale,
                appState: appState
            )

            guard !sectionImages.isEmpty else {
                logger.warning(
                    "Failed item image cache for \(section.logString, privacy: .public)"
                )
                continue
            }

            newImages.merge(sectionImages) { _, new in new }
        }

        // Get the set of valid item tags from all sections to clean up stale entries
        let allValidTags = await Set(
            appState.itemManager.itemCache.managedItems.map(\.tag)
        )

        await MainActor.run { [newImages, allValidTags] in
            let beforeCount = images.count

            // Remove images for items that no longer exist in the item cache
            images = images.filter { allValidTags.contains($0.key) }

            // Additional cleanup: Remove entries with invalid window information
            _ = validateAndCleanupInvalidEntries()

            // Update access order for existing items that are being refreshed
            for tag in newImages.keys {
                if images.contains(where: { $0.key == tag }) {
                    // Move to end (most recently used)
                    accessOrder.removeAll { $0 == tag }
                    accessOrder.append(tag)
                } else {
                    // New entry - add to access order
                    accessOrder.append(tag)
                }
            }

            // Merge in the new images
            images.merge(newImages) { _, new in new }

            // Enforce cache size limit using LRU eviction, but never evict
            // items that belong to the sections we just captured (i.e. the
            // sections currently being displayed).
            if images.count > Self.maxCacheSize {
                let protectedTags = Set(newImages.keys)
                let evictionCandidates = accessOrder.filter { !protectedTags.contains($0) }
                let excessCount = images.count - Self.maxCacheSize
                let tagsToRemove = Array(evictionCandidates.prefix(excessCount))

                for tag in tagsToRemove {
                    images.removeValue(forKey: tag)
                    accessOrder.removeAll { $0 == tag }
                }

                if !tagsToRemove.isEmpty {
                    logger.info(
                        "LRU cache eviction: removed \(tagsToRemove.count) least recently used images (\(protectedTags.count) protected)"
                    )
                }
            }

            // Clean up access order for any remaining inconsistencies and
            // de-duplicate while preserving most recent usage order
            var seen = Set<MenuBarItemTag>()
            accessOrder = accessOrder
                .reversed()
                .filter { tag in
                    guard images.keys.contains(tag) else { return false }
                    if seen.contains(tag) {
                        return false
                    }
                    seen.insert(tag)
                    return true
                }
                .reversed()

            let afterCount = images.count
            let finalAccessOrderCount = accessOrder.count
            let totalRemoved = beforeCount - afterCount

            // Log cache status for monitoring (verbose only when needed)
            if afterCount > 30 || totalRemoved > 0 {
                logger.info(
                    "Image cache: \(afterCount) images, LRU order: \(finalAccessOrderCount) entries (removed \(totalRemoved) stale+invalid images)"
                )
            }

            // Warning if cache and access order are out of sync
            if afterCount != finalAccessOrderCount {
                logger.warning(
                    "Cache inconsistency: \(afterCount) cached images vs \(finalAccessOrderCount) LRU entries"
                )
            }
        }
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name], skipRecentMoveCheck: Bool = false) async {
        guard let appState else {
            diagLog.debug("updateCache: appState is nil, skipping")
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented

        if !isIceBarPresented, !isSearchPresented {
            let isAppFrontmost = await appState.navigationState.isAppFrontmost
            let isSettingsPresented = await appState.navigationState.isSettingsPresented
            let settingsNavID = await appState.navigationState.settingsNavigationIdentifier

            guard isAppFrontmost, isSettingsPresented, settingsNavID == .menuBarLayout else {
                // This is the normal path when IceBar/search/settings are not visible — not an error
                return
            }
        }

        if !skipRecentMoveCheck {
            guard
                await !appState.itemManager.lastMoveOperationOccurred(
                    within: .seconds(1)
                )
            else {
                logger.debug(
                    "Skipping item image cache due to recent item movement"
                )
                return
            }
        }

        diagLog.debug("updateCache: proceeding with cache update for \(sections.count) sections (iceBar=\(isIceBarPresented), search=\(isSearchPresented))")
        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented = await appState.navigationState
            .isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()

        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if isIceBarPresented, let section = await appState.menuBarManager.iceBarPanel
            .currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(
            sections: sectionsNeedingDisplay,
            skipRecentMoveCheck: isIceBarPresented
        )
    }

    /// Clears the images for the given section.
    @MainActor
    func clearImages(for section: MenuBarSection.Name) {
        guard let appState else {
            return
        }
        let tags = Set(appState.itemManager.itemCache[section].map(\.tag))
        images = images.filter { !tags.contains($0.key) }
        accessOrder.removeAll { tags.contains($0) }
    }

    /// Clears all cached images and failure tracking.
    @MainActor
    func clearAll() {
        images.removeAll()
        accessOrder.removeAll()
        failedCaptures.removeAll()
    }

    // MARK: Cache Failed

    /// Returns a Boolean value that indicates whether caching menu bar items
    /// failed for the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        let hasPermission = ScreenCapture.cachedCheckPermissions()
        guard hasPermission else {
            diagLog.debug("cacheFailed(\(section.logString)): no screen recording permission (cachedCheckPermissions=false)")
            return true
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.tag) {
            return false
        }
        diagLog.debug("cacheFailed(\(section.logString)): no cached images found for \(items.count) items in section (total cached images: \(self.images.count))")
        return true
    }
}
