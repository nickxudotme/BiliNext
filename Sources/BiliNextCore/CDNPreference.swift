import Foundation

/// Orders a stream's mirror URLs so playback opens on Bilibili's own CDN first.
///
/// playurl often lists PCDN mirrors first (`xy….mcdn.bilivideo.cn`, `*.mountaintoys.cn`,
/// `szbdyd.com`). Their wildcard hostnames frequently take seconds to resolve on first use,
/// which stalls the start of playback; the official `upos-…`/`cn-…` hosts resolve at once.
/// PCDN mirrors are kept as later fallbacks rather than dropped.
enum CDNPreference {
    /// 0 for the official CDN, 1 for unknown hosts, 2 for PCDN mirrors.
    static func rank(_ url: URL) -> Int {
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
    static func ordered(_ urls: [URL]) -> [URL] {
        urls.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}
