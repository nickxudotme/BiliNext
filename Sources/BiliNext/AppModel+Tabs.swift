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
        if !tabs.contains(where: { $0.id == video.id }) {
            tabs.append(
                SessionTab(
                    video: video, cid: video.historyCID, position: max(0, video.progress ?? 0)))
        }
        if background {
            toast = "已加入侧栏"
            saveSession()
        } else {
            activate(video.id, autoplay: true)
        }
    }
    func close(_ id: String) {
        saveSession()
        closed = tabs.filter { $0.id == id }
        let index = tabs.firstIndex(where: { $0.id == id }) ?? 0
        tabs.removeAll { $0.id == id }
        releasePlaybackTab(id)
        if mediaID == id { stopMedia() }
        if selected == id {
            selected = nil
            if !tabs.isEmpty {
                activate(tabs[min(index, tabs.count - 1)].id)
            } else if browseInstances[menu] == nil {
                refresh()
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
            if browseInstances[menu] == nil { refresh() }
        }
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
            if let video = instance.detail?.video { snapshot[index].video = video }
            snapshot[index].cid = instance.pageID ?? snapshot[index].cid
            let seconds =
                instance.officialCore
                ? instance.time : instance.mpv?.time ?? instance.player.currentTime().seconds
            if instance.officialCore || instance.mpv?.loaded == true
                || instance.player.currentItem?.status == .readyToPlay,
                seconds.isFinite
            {
                snapshot[index].position = max(0, seconds)
            }
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
            instance.officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
            instance.playbackIntent = false
            instance.playing = false
        }
    }

    func releasePlaybackTab(_ id: String) {
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
        instance.profile = profile
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
        tabSubscriptions[key] = subscriptions
    }

    func browseInstance(for destination: String) -> AppModel {
        if let existing = browseInstances[destination] { return existing }
        let instance = AppModel(
            sessionStore: sessionStore, managesPlaybackTabs: false, downloads: downloads, api: api,
            hoverPreview: hoverPreview)
        instance.menu = destination
        connectPage(instance, key: "browse:" + destination)
        browseInstances[destination] = instance
        return instance
    }

    func playbackInstance(for tab: SessionTab) -> AppModel {
        if let existing = playbackInstances[tab.id] { return existing }
        let instance = AppModel(
            sessionStore: sessionStore, managesPlaybackTabs: false, downloads: downloads, api: api,
            hoverPreview: hoverPreview)
        instance.tabs = [tab]
        instance.menu = menu
        connectPage(instance, key: tab.id)
        playbackInstances[tab.id] = instance
        return instance
    }

    func activatePlaybackTab(_ id: String, force: Bool, autoplay: Bool) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        hoverPreview.stop()
        saveSession()
        suspendPlaybackTabs(except: id)
        let instance = playbackInstance(for: tab)
        selected = id
        instance.profile = profile
        instance.playbackTabActive = true
        instance.activate(id, force: force, autoplay: autoplay)
    }

}
