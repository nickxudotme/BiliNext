import Foundation
import Testing

@testable import BiliNext

@Test func playbackActivityReleasesSystemAssertions() throws {
    func assertions() throws -> Int {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            .filter { $0.contains("BiliNext video playback") }.count
    }
    let baseline = try assertions()
    var activity: PlaybackActivity? = PlaybackActivity()
    activity?.setActive(true)
    let active = try assertions()
    #expect(active >= baseline + 2)
    activity?.setActive(true)
    #expect(try assertions() == active)
    activity?.setActive(false)
    #expect(try assertions() == baseline)
    activity?.setActive(true)
    activity = nil
    #expect(try assertions() == baseline)
}
