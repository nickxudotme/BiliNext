import AppKit
import SwiftUI
import Testing

@testable import BiliNext

@MainActor
@Test func inactiveRetainedPageDefersViewportUntilActivation() {
    _ = NSApplication.shared
    let host = RetainedPageHost<Color>.Host(content: .black, isActive: true)
    host.frame = NSRect(x: 0, y: 0, width: 1580, height: 1100)
    host.layout()
    let content = host.content
    let previousViewport = content.frame
    host.update(content: .gray, isActive: false)
    for width in stride(from: 1580, through: 1800, by: 22) {
        host.frame.size.width = CGFloat(width)
        host.layout()
        host.update(content: .gray, isActive: false)
        #expect(content.frame == previousViewport)
        #expect(host.isHidden)
    }
    host.update(content: .gray, isActive: true)
    #expect(host.content === content)
    #expect(content.frame == host.bounds)
    #expect(!host.isHidden)
    host.frame.size.width = 1200
    host.layout()
    #expect(content.frame == host.bounds)
}
