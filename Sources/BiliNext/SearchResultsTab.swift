import Foundation

enum SearchResultsTab {
    static func id(_ keyword: String) -> String {
        "search:" + Data(keyword.utf8).base64EncodedString()
    }

    static func keyword(_ id: String) -> String? {
        guard id.hasPrefix("search:"),
            let data = Data(base64Encoded: String(id.dropFirst(7))),
            let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    static func url(_ id: String) -> String? {
        guard let keyword = keyword(id) else { return nil }
        var components = URLComponents(string: "https://search.bilibili.com/all")!
        components.queryItems = [URLQueryItem(name: "keyword", value: keyword)]
        return components.url?.absoluteString
    }
}
