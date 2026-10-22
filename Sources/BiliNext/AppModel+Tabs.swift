import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Tabs and session

    func open(_ video: Video, background: Bool = false) {
        if let tabOwner {
            tabOwner.open(video, background: background)
            return
        }
        #if DEBUG
            DevelopmentFeedback.record(
                "navigation.openVideo",
                fields: [
                    "videoID": video.id, "background": String(background),
                ])
        #endif
        if !tabs.contains(where: { $0.id == video.id }) {
            tabs.append(
                SessionTab(
                    video: video, cid: video.historyCID, position: max(0, video.progress ?? 0)))
        }
        if background {
            if selected != video.id { unseenTabs.insert(video.id) }
            if !sidebarPinned { toast = "已在后台打开「\(video.title)」" }
            saveSession()
        } else {
            activate(video.id, autoplay: true)
        }
    }
    func close(_ id: String) {
        saveSession()
        closed = tabs.filter { $0.id == id }
        unseenTabs.remove(id)
        let index = tabs.firstIndex(where: { $0.id == id }) ?? 0
        tabs.removeAll { $0.id == id }
        releasePlaybackTab(id)
        if mediaID == id { stopMedia() }
        if selected == id {
            selected = nil
            if !tabs.isEmpty {
                activate(tabs[min(index, tabs.count - 1)].id)
            } else {
                loadBrowseIfNeeded()
            }
        }
        saveSession()
    }
    func clearTabs() {
        saveSession()
        if let selected, tabs.contains(where: { $0.id == selected }) {
            closed = tabs.filter { $0.id != selected }
            for tab in closed { releasePlaybackTab(tab.id) }
            tabs.removeAll { $0.id != selected }
            saveSession()
        } else {
            closed = tabs
            for tab in closed { releasePlaybackTab(tab.id) }
            tabs = []
            selected = nil
            stopMedia()
            saveSession()
            loadBrowseIfNeeded()
        }
    }
    /// Closes every tab except one, or every tab after it; both stay undoable.
    func closeOtherTabs(keeping id: String, onlyBelow: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        saveSession()
        let closing = tabs.enumerated().filter { offset, _ in
            onlyBelow ? offset > index : offset != index
        }.map(\.element)
        guard !closing.isEmpty else { return }
        closed = closing
        for tab in closing {
            releasePlaybackTab(tab.id)
            unseenTabs.remove(tab.id)
        }
        tabs.removeAll { tab in closing.contains { $0.id == tab.id } }
        if let selected, !tabs.contains(where: { $0.id == selected }) { activate(id) }
        saveSession()
    }

    func toggleWindowPin() {
        if let tabOwner {
            tabOwner.toggleWindowPin()
            return
        }
        windowPinned.toggle()
    }

    /// Enters or leaves 小窗, restoring the sidebar and pinning. Detail panels are hidden by
    /// the mini layout itself, so switching tabs inside 小窗 changes no tab's theater state.
    func toggleMiniPlayer() {
        if let tabOwner {
            tabOwner.toggleMiniPlayer()
            return
        }
        if miniPlayer {
            let previous = stateBeforeMiniPlayer
            miniPlayer = false
            sidebarPinned = previous?.sidebarPinned ?? true
            windowPinned = previous?.windowPinned ?? false
            stateBeforeMiniPlayer = nil
        } else {
            // 小窗 only shows media; a space page has none.
            guard let selected, MemberSpace.mid(selected) == nil,
                SearchResultsTab.keyword(selected) == nil
            else { return }
            stateBeforeMiniPlayer = (sidebarPinned, windowPinned)
            sidebarPinned = false
            windowPinned = true
            miniPlayer = true
        }
    }

    /// Plays another video in place of a tab, as when moving through a 合集. A video that is
    /// already open elsewhere is selected instead of duplicated.
    func replace(_ id: String, with video: Video) {
        if let tabOwner {
            tabOwner.replace(id, with: video)
            return
        }
        guard video.id != id else { return }
        if tabs.contains(where: { $0.id == video.id }) {
            activate(video.id, autoplay: true)
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            open(video)
            return
        }
        saveSession()
        var trail = tabs[index].trail
        trail.leave(tabs[index])
        swapTab(at: index, to: SessionTab(video: video, cid: video.historyCID, trail: trail))
    }

    /// Steps the selected tab back or forward through the videos it played in place.
    /// Returns false when that tab has nowhere to go, so 后退 can leave it instead.
    func stepTabTrail(_ delta: Int) -> Bool {
        guard let id = selected, let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        saveSession()
        var trail = tabs[index].trail
        guard let target = trail.step(delta, from: tabs[index]) else { return false }
        // A video already open in another tab is selected there instead.
        if tabs.contains(where: { $0.id == target.video.bvid }) {
            activate(target.video.bvid, autoplay: true)
            return true
        }
        swapTab(at: index, to: SessionTab(target, trail: trail))
        return true
    }

    /// Puts `tab` in place of the tab at `index`.
    private func swapTab(at index: Int, to tab: SessionTab) {
        let id = tabs[index].id
        let wasSelected = selected == id
        tabs[index] = tab
        releasePlaybackTab(id)
        unseenTabs.remove(id)
        if wasSelected {
            selected = nil
            activate(tab.id, autoplay: true)
        }
        saveSession()
    }

    /// ⌘1–8 pick a tab by position and ⌘9 the last one, as in browsers.
    func activateTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index].id, autoplay: true)
    }

    /// ⌃Tab and ⌃⇧Tab step through tabs, wrapping, starting from browsing when none is open.
    func cycleTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let current = selected.flatMap { id in tabs.firstIndex { $0.id == id } }
        let next = Self.tabIndex(after: current, count: tabs.count, delta: delta)
        activate(tabs[next].id, autoplay: true)
    }

    nonisolated static func tabIndex(after current: Int?, count: Int, delta: Int) -> Int {
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return ((current + delta) % count + count) % count
    }

    func undoClose() {
        for tab in closed where !tabs.contains(where: { $0.id == tab.id }) { tabs.append(tab) }
        closed = []
        saveSession()
    }
    func saveSession(updateTabs: Bool = true) {
        if let tabOwner {
            tabOwner.saveSession(updateTabs: updateTabs)
            return
        }
        var snapshot = tabs
        for index in snapshot.indices {
            guard let instance = playbackInstances[snapshot[index].id] else { continue }
            let localIndex = instance.tabs.firstIndex(where: { $0.id == snapshot[index].id })
            // A newly selected part may not have loaded yet. Its local record already
            // has the new CID and zero position; the workspace still has the old part.
            if let localIndex {
                snapshot[index].cid = instance.tabs[localIndex].cid ?? snapshot[index].cid
                snapshot[index].position = instance.tabs[localIndex].position
            }
            if let video = instance.detail?.video { snapshot[index].video = video }
            snapshot[index].cid = instance.pageID ?? snapshot[index].cid
            let seconds =
                instance.officialCore
                ? instance.time : instance.mpv?.time ?? instance.player.currentTime().seconds
            if !instance.officialCore
                && (instance.awaitingMPVLoad || instance.playbackRecovery?.recovering == true)
            {
                snapshot[index].position = instance.recoveryPosition
            } else if instance.officialCore || instance.mpv?.loaded == true
                || instance.player.currentItem?.status == .readyToPlay,
                seconds.isFinite
            {
                snapshot[index].position = max(0, seconds)
            }
            // A forced reload reads the retained page's own record. Keep it current,
            // while periodic saves continue avoiding published tab changes.
            if updateTabs, let localIndex { instance.tabs[localIndex] = snapshot[index] }
        }
        if updateTabs { tabs = snapshot }
        if officialCore || mpv?.loaded == true || player.currentItem?.status == .readyToPlay,
            let index = snapshot.firstIndex(where: { $0.id == mediaID })
        {
            let seconds = officialCore ? time : (mpv?.time ?? player.currentTime().seconds)
            if seconds.isFinite { snapshot[index].position = max(0, seconds) }
            snapshot[index].cid = pageID
            if updateTabs { tabs = snapshot }
        }
        do {
            try sessionStore.write(snapshot)
            lastSaved = Date()
            for instance in playbackInstances.values { instance.lastSaved = lastSaved }
        } catch { toast = "标签恢复记录保存失败：\(error.localizedDescription)" }
    }

    func suspendPlaybackTabs(except id: String? = nil) {
        for (key, instance) in playbackInstances where key != id {
            instance.watchHistoryReporter.flush()
            instance.playbackTabActive = false
            if let state = instance.qualitySwitchState {
                instance.qualitySwitchState = (state.position, false)
            }
            instance.player.pause()
            instance.mpv?.pause()
            instance.liveSession?.suspend()
            instance.officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
            instance.playbackIntent = false
            instance.playing = false
        }
    }

    func releasePlaybackTab(_ id: String) {
        playbackInstances[id]?.browseTask?.cancel()
        playbackInstances[id]?.officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
        playbackInstances[id]?.stopMedia()
        if let instance = playbackInstances[id], let observer = instance.observer {
            instance.player.removeTimeObserver(observer)
            instance.observer = nil
        }
        playbackInstances.removeValue(forKey: id)
        tabSubscriptions.removeValue(forKey: id)
    }

    private func connectPage(_ instance: AppModel, key: String) {
        instance.tabOwner = self
        instance.playbackPrefetch = playbackPrefetch
        instance.profile = profile
        instance.libraryBusy = watchLaterSynchronization.busy
        var subscriptions = Set<AnyCancellable>()
        instance.$loginPresented.dropFirst().sink { [weak self] value in
            if value { self?.loginPresented = true }
        }.store(in: &subscriptions)
        instance.$downloadsPresented.dropFirst().sink { [weak self] value in
            if value { self?.downloadsPresented = true }
        }.store(in: &subscriptions)
        instance.$toast.dropFirst().sink { [weak self] value in
            if let value { self?.toast = value }
        }.store(in: &subscriptions)
        instance.$playing.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        instance.$liveSession.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        tabSubscriptions[key] = subscriptions
    }

    func browsePageID(for destination: BrowseDestination) -> String {
        switch destination {
        case .home: return "首页:\(homeSection)"
        case .dynamic: return "动态:\(dynamicMode)"
        case .favorites:
            let key = "收藏:\(folderID)"
            if browseInstances[key] != nil { return key }
            // The default folder's original key remains stable after its real ID arrives.
            if folderID != 0, let defaultPage = browseInstances["收藏:0"],
                defaultPage.folderID == folderID
            {
                return "收藏:0"
            }
            if folderID != 0,
                let loaded = browseInstances.sorted(by: { $0.key < $1.key }).first(where: {
                    $0.value.menu == .favorites && $0.value.folderID == folderID
                })
            {
                return loaded.key
            }
            return key
        case .search, .history, .watchLater: return destination.rawValue
        }
    }

    func loadedBrowseInstance(for destination: BrowseDestination) -> AppModel? {
        browseInstances[browsePageID(for: destination)]
    }

    func browseInstance(for destination: BrowseDestination) -> AppModel {
        let key = browsePageID(for: destination)
        if let existing = browseInstances[key] { return existing }
        let instance = AppModel(
            sessionStore: sessionStore, managesPlaybackTabs: false, downloads: downloads, api: api,
            hoverPreview: hoverPreview, browsePageLoader: browsePageLoader,
            profileLoader: profileLoader)
        instance.menu = destination
        instance.homeSection = homeSection
        instance.dynamicMode = dynamicMode
        instance.folderID = folderID
        instance.playbackTabActive = false
        if destination == .favorites {
            instance.folders =
                folders.isEmpty
                ? browseInstances.values.first(where: {
                    $0.menu == .favorites && !$0.folders.isEmpty
                })?
                .folders ?? []
                : folders
        }
        connectPage(instance, key: "browse:" + key)
        browseInstances[key] = instance
        return instance
    }

    func playbackInstance(for tab: SessionTab) -> AppModel {
        if let existing = playbackInstances[tab.id] { return existing }
        let instance = AppModel(
            sessionStore: sessionStore, managesPlaybackTabs: false, downloads: downloads, api: api,
            hoverPreview: hoverPreview, browsePageLoader: browsePageLoader,
            profileLoader: profileLoader, favoriteFolderLoader: favoriteFolderLoader)
        instance.tabs = [tab]
        instance.menu = menu
        connectPage(instance, key: tab.id)
        playbackInstances[tab.id] = instance
        return instance
    }

    func activatePlaybackTab(_ id: String, force: Bool, autoplay: Bool) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        #if DEBUG
            DevelopmentFeedback.record(
                "navigation.activateTab",
                fields: [
                    "from": selected ?? menu.rawValue, "to": id, "autoplay": String(autoplay),
                ])
        #endif
        hoverPreview.stop()
        saveSession()
        suspendPlaybackTabs(except: id)
        unseenTabs.remove(id)
        let instance = playbackInstance(for: tab)
        instance.menu = menu
        selected = id
        instance.profile = profile
        instance.playbackTabActive = true
        instance.activate(id, force: force, autoplay: autoplay)
    }

}
