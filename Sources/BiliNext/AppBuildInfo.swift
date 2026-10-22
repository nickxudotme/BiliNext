import AppKit

enum AppBuildInfo {
    static var credits: NSAttributedString {
        let commit = Bundle.main.object(forInfoDictionaryKey: "BiliNextGitCommit") as? String
        var text =
            commit.map { $0 == "unknown" ? "Commit：未记录" : "Commit：\($0)" }
            ?? "Commit：未记录"
        if Bundle.main.object(forInfoDictionaryKey: "BiliNextGitDirty") as? String == "dirty" {
            text += "\n包含未提交改动"
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
    }
}
