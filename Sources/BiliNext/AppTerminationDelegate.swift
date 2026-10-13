import AppKit

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
