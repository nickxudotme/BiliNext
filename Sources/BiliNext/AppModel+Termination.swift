import Foundation

extension AppModel {
    func prepareForTermination(timeout: TimeInterval = 2) async {
        saveSession()
        let instances = Array(playbackInstances.values) + [self]
        for instance in instances {
            if !instance.officialCore, let id = instance.mediaID, let cid = instance.pageID {
                let position: Double
                if let mpv = instance.mpv {
                    position =
                        mpv.loaded && mpv.failure == nil ? mpv.time : instance.recoveryPosition
                } else {
                    position = instance.time
                }
                instance.watchHistoryReporter.update(
                    bvid: id, cid: cid, position: position,
                    playing: false, buffering: false)
            }
            instance.stopMedia()
        }
        for instance in instances { await instance.watchHistoryReporter.waitForPendingReports() }
        await historyOutbox.drain(timeout: timeout)
    }
}
