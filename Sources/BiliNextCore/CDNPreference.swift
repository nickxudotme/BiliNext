import Foundation

/// Orders a stream's mirror URLs so playback opens on Bilibili's own CDN first.
///
/// playurl often lists PCDN mirrors first (`xy….mcdn.bilivideo.cn`, `*.mountaintoys.cn`,
/// `szbdyd.com`). Their wildcard hostnames frequently take seconds to resolve on first use,
/// which stalls the start of playback; the official `upos-…`/`cn-…` hosts resolve at once.
/// PCDN mirrors are kept as later fallbacks rather than dropped.
public enum CDNPreference {
    /// Official mirrors a stream may be moved to. Any official `/upgcxcode/` URL is valid on
    /// each of them, since the media signature does not cover the host.
    public static let mirrors: [(id: String, title: String, host: String)] = [
        ("ali", "阿里云", "upos-sz-mirrorali.bilivideo.com"),
        ("alio1", "阿里云 o1", "upos-sz-mirroralio1.bilivideo.com"),
        ("cos", "腾讯云", "upos-sz-mirrorcos.bilivideo.com"),
        ("hw", "华为云", "upos-sz-mirrorhw.bilivideo.com"),
    ]

    public static func host(forMirror id: String) -> String? {
        mirrors.first { $0.id == id }?.host
    }

    /// 0 for the official CDN, 1 for unknown hosts, 2 for PCDN mirrors.
    public static func rank(_ url: URL) -> Int {
        let host = (url.host ?? "").lowercased()
        let query = url.query?.lowercased() ?? ""
        let peer =
            host.hasSuffix(".mcdn.bilivideo.cn") || host.hasSuffix("mountaintoys.cn")
            || host.hasSuffix("szbdyd.com") || host.first?.isNumber == true
            || (url.port.map { $0 != 443 } ?? false)
            || ["os=mcdn", "os=pcdn", "os=bdyd", "os=stcdn"].contains { query.contains($0) }
        if peer { return 2 }
        let official =
            (host.hasPrefix("upos-") || host.hasPrefix("cn-")) && host.hasSuffix(".bilivideo.com")
            || host.hasSuffix(".akamaized.net")
        return official ? 0 : 1
    }

    /// Official mirrors first, keeping the service's order within each rank.
    public static func ordered(_ urls: [URL]) -> [URL] {
        urls.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Puts a copy of the first movable URL on `host` ahead of the list, keeping the rest as
    /// fallbacks. A fixed host stays in the DNS cache across videos, where per-node hosts such
    /// as `cn-zjjh-ct-04-05` each cost a lookup that can take seconds on a slow resolver.
    public static func preferring(_ host: String?, in urls: [URL]) -> [URL] {
        guard let host,
            let source = urls.first(where: movable),
            var components = URLComponents(url: source, resolvingAgainstBaseURL: false)
        else { return urls }
        components.scheme = "https"
        components.host = host
        components.port = nil
        guard let moved = components.url else { return urls }
        return [moved] + urls.filter { $0 != moved }
    }

    /// Official `/upgcxcode/` media; `-302` hosts are redirectors, not mirrors.
    static func movable(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return rank(url) == 0 && url.path.hasPrefix("/upgcxcode/") && !host.contains("-302")
    }
}

extension Playback {
    /// The same playback with both streams starting on `host` (see `CDNPreference`).
    public func preferringMirror(_ host: String?) -> Playback {
        func move(_ stream: PlaybackStream?) -> PlaybackStream? {
            stream.map {
                PlaybackStream(
                    urls: CDNPreference.preferring(host, in: $0.urls), codec: $0.codec,
                    bandwidth: $0.bandwidth, initialization: $0.initialization, index: $0.index)
            }
        }
        let videoStream = move(videoStream)
        return Playback(
            url: videoStream?.urls.first
                ?? CDNPreference.preferring(host, in: [url]).first ?? url,
            quality: quality, qualityID: qualityID, qualities: qualities,
            videoStream: videoStream, audioStream: move(audioStream))
    }
}
