import AppKit
import XCTest

@testable import SwiftFeedback

@MainActor
final class FeedbackCaptureTests: XCTestCase {
    func testScreenCaptureRejectsWrongWindowGeometryAndAllowsPixelRounding() {
        XCTAssertFalse(
            FeedbackCapture.compatibleCaptureSize(
                CGSize(width: 266, height: 241), CGSize(width: 1695, height: 1011)))
        XCTAssertTrue(
            FeedbackCapture.compatibleCaptureSize(
                CGSize(width: 1695, height: 1011), CGSize(width: 1695, height: 1011)))
        XCTAssertTrue(
            FeedbackCapture.compatibleCaptureSize(
                CGSize(width: 1695.5, height: 1010.5), CGSize(width: 1695, height: 1011)))
        XCTAssertFalse(FeedbackCapture.compatibleCaptureSize(CGSize(width: 0, height: 0), .zero))
    }

    func testModernGettersWithoutFullProtocolCaptureSwiftUISemanticsAndFrame() {
        let fixture = GetterOnlyAccessibilityFixture()
        XCTAssertFalse(fixture is any NSAccessibilityProtocol)

        let result = FeedbackCapture.collectAccessibility(root: fixture, timeBudget: 10)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.role, "AXButton")
        XCTAssertEqual(result.nodes.first?.label, "Getter-only Play")
        XCTAssertEqual(result.nodes.first?.value, "Paused")
        XCTAssertEqual(
            result.nodes.first?.frame?.cgRect, CGRect(x: 12, y: 34, width: 56, height: 78))
        XCTAssertEqual(result.nodes.first?.enabled, false)
        XCTAssertEqual(result.nodes.first?.focused, true)
        XCTAssertEqual(result.nodes.first?.selected, true)
        XCTAssertEqual(result.nodes.first?.accessMethod, "NSAccessibility object getters")
    }

    func testSecureInputAndDescendantsNeverReadTheirValues() {
        let secure = ProbeAccessibilityElement()
        secure.setAccessibilityRole(.textField)
        secure.setAccessibilitySubrole(.secureTextField)
        secure.setAccessibilityLabel("must not expose secure label")
        let child = ProbeAccessibilityElement()
        child.setAccessibilityRole(.staticText)
        secure.setAccessibilityChildren([child])

        let result = FeedbackCapture.collectAccessibility(root: secure, timeBudget: 10)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertNil(result.nodes.first?.value)
        XCTAssertNil(result.nodes.first?.label)
        XCTAssertEqual(result.nodes.first?.valueStatus, "redacted: secure input")
        XCTAssertEqual(secure.valueReadCount, 0)
        XCTAssertEqual(child.valueReadCount, 0)
        XCTAssertEqual(result.metadata["accessibility.redactedSecureInputs"], "1")
    }

    func testEditableInputValuesAndEditorChildrenAreOmitted() {
        let input = ProbeAccessibilityElement()
        input.setAccessibilityRole(.textArea)
        let child = ProbeAccessibilityElement()
        child.setAccessibilityRole(.staticText)
        input.setAccessibilityChildren([child])

        let result = FeedbackCapture.collectAccessibility(root: input, timeBudget: 10)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes.first?.valueStatus, "redacted: editable input")
        XCTAssertEqual(input.valueReadCount, 0)
        XCTAssertEqual(child.valueReadCount, 0)
    }

    func testHierarchyPreservesParentIndicesAndStopsAtBudget() {
        let root = NSAccessibilityElement()
        root.setAccessibilityRole(.group)
        let first = NSAccessibilityElement()
        first.setAccessibilityRole(.button)
        first.setAccessibilityLabel("Play video")
        let second = NSAccessibilityElement()
        second.setAccessibilityRole(.staticText)
        root.setAccessibilityChildren([first, second])
        // Include a cycle to verify that custom app accessibility cannot recurse forever.
        first.setAccessibilityChildren([root])

        let result = FeedbackCapture.collectAccessibility(root: root, maxNodes: 2, timeBudget: 10)

        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertNil(result.nodes[0].parentIndex)
        XCTAssertEqual(result.nodes[1].parentIndex, 0)
        XCTAssertEqual(result.nodes[1].depth, 1)
        XCTAssertEqual(result.nodes[1].label, "Play video")
        XCTAssertEqual(result.metadata["accessibility.status"], "partial")
        XCTAssertTrue(
            result.metadata["accessibility.truncationReasons"]?.contains("node limit") == true)
        first.setAccessibilityChildren([])
    }

    func testDepthAndTextLimitsAreReported() {
        let root = NSAccessibilityElement()
        root.setAccessibilityRole(.staticText)
        root.setAccessibilityValue("abcdefghij")
        root.setAccessibilityChildren([NSAccessibilityElement()])

        let result = FeedbackCapture.collectAccessibility(
            root: root, maxDepth: 0, maxTextLength: 4, timeBudget: 10)

        XCTAssertEqual(result.nodes.first?.value, "abcd")
        XCTAssertEqual(result.nodes.first?.valueStatus, "truncated")
        XCTAssertEqual(result.metadata["accessibility.truncatedTextCount"], "1")
        XCTAssertTrue(
            result.metadata["accessibility.truncationReasons"]?.contains("depth limit") == true)
    }

    func testLogRedactionRemovesCredentialFieldsAndURLSecrets() {
        let inputs = [
            "Authorization: Bearer secret", "{\"cookie\":\"secret\"}", "SESSDATA=secret",
            "token = secret",
        ]
        for input in inputs {
            XCTAssertEqual(
                FeedbackCapture.sanitizedLogMessage(input),
                "[redacted: credential-bearing log entry]")
        }
        let result = FeedbackCapture.sanitizedLogMessage(
            "GET https://name:secret@example.test/api?session=private#fragment failed")
        XCTAssertEqual(result, "GET https://example.test/api [URL parameters removed] failed")
        XCTAssertFalse(result.contains("private"))
        XCTAssertFalse(result.contains("secret"))
    }

    func testInformalProtocolProxyCapturesSemanticsGeometryAndChildren() {
        let child = LegacyAccessibilityFixture(attributes: [
            .role: NSAccessibility.Role.button.rawValue,
            .title: "SwiftUI proxy button",
            .identifier: "playback.play",
            .position: NSValue(point: NSPoint(x: 25, y: 35)),
            .size: NSValue(size: NSSize(width: 45, height: 55)),
            .enabled: true,
        ])
        let root = LegacyAccessibilityFixture(attributes: [
            .role: NSAccessibility.Role.group.rawValue,
            .children: [child],
        ])

        let result = FeedbackCapture.collectAccessibility(root: root, timeBudget: 10)

        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[1].role, NSAccessibility.Role.button.rawValue)
        XCTAssertEqual(result.nodes[1].label, "SwiftUI proxy button")
        XCTAssertEqual(result.nodes[1].identifier, "playback.play")
        XCTAssertEqual(result.nodes[1].frame?.cgRect, CGRect(x: 25, y: 35, width: 45, height: 55))
        XCTAssertEqual(result.nodes[1].parentIndex, 0)
        XCTAssertEqual(result.nodes[1].accessMethod, "NSAccessibility informal protocol")
        XCTAssertEqual(result.metadata["accessibility.legacyNodeCount"], "2")
        XCTAssertEqual(result.metadata["accessibility.unsupportedCount"], "0")
        XCTAssertTrue(child.requestedAttributes.allSatisfy { child.attributes[$0] != nil })
    }

    func testInformalProtocolSecureInputNeverReadsValueOrChildren() {
        let secure = LegacyAccessibilityFixture(attributes: [
            .role: NSAccessibility.Role.textField.rawValue,
            .subrole: NSAccessibility.Subrole.secureTextField.rawValue,
            .value: "secret",
            .description: "secret label",
            .children: [
                LegacyAccessibilityFixture(attributes: [
                    .role: NSAccessibility.Role.staticText.rawValue, .value: "secret",
                ])
            ],
        ])

        let result = FeedbackCapture.collectAccessibility(root: secure, timeBudget: 10)

        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertNil(result.nodes.first?.value)
        XCTAssertNil(result.nodes.first?.label)
        XCTAssertFalse(secure.requestedAttributes.contains(.value))
        XCTAssertFalse(secure.requestedAttributes.contains(.description))
        XCTAssertFalse(secure.requestedAttributes.contains(.children))
    }
}

@MainActor
private final class ProbeAccessibilityElement: NSAccessibilityElement {
    private(set) var valueReadCount = 0

    override func accessibilityValue() -> Any? {
        valueReadCount += 1
        return "sensitive input"
    }
}

/// Models the public informal-protocol surface used by AppKit's reparenting proxies.
@MainActor
private final class LegacyAccessibilityFixture: NSObject {
    let attributes: [NSAccessibility.Attribute: Any]
    private(set) var requestedAttributes: [NSAccessibility.Attribute] = []

    init(attributes: [NSAccessibility.Attribute: Any]) {
        self.attributes = attributes
        super.init()
    }

    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        Array(attributes.keys)
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        requestedAttributes.append(attribute)
        return attributes[attribute]
    }
}

/// Matches SwiftUI.AccessibilityNode's runtime surface: element protocol plus modern getters,
/// with no full NSAccessibilityProtocol conformance and an empty informal-protocol interface.
private final class GetterOnlyAccessibilityFixture: NSObject, NSAccessibilityElementProtocol {
    func accessibilityFrame() -> NSRect { CGRect(x: 12, y: 34, width: 56, height: 78) }
    func accessibilityParent() -> Any? { nil }
    @objc func accessibilityRole() -> NSString { "AXButton" }
    @objc func accessibilityLabel() -> NSString { "Getter-only Play" }
    @objc func accessibilityValue() -> NSString { "Paused" }
    @objc func accessibilityChildren() -> [Any] { [] }
    @objc func isAccessibilityEnabled() -> Bool { false }
    @objc func isAccessibilityFocused() -> Bool { true }
    @objc func isAccessibilitySelected() -> Bool { true }
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] { [] }
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        nil
    }
}
