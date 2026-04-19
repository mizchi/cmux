import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ChromiumCDPInputRouterTests: XCTestCase {

    func test_modifiersBitmaskMatchesCDPConvention() {
        // CDP: Alt=1, Ctrl=2, Meta=4, Shift=8. Verify each independently
        // and a few combinations.
        XCTAssertEqual(ChromiumCDPInputRouter.modifiers(from: []), 0)
        XCTAssertEqual(ChromiumCDPInputRouter.modifiers(from: .option), 1)
        XCTAssertEqual(ChromiumCDPInputRouter.modifiers(from: .control), 2)
        XCTAssertEqual(ChromiumCDPInputRouter.modifiers(from: .command), 4)
        XCTAssertEqual(ChromiumCDPInputRouter.modifiers(from: .shift), 8)
        XCTAssertEqual(
            ChromiumCDPInputRouter.modifiers(from: [.command, .shift]),
            4 | 8
        )
        XCTAssertEqual(
            ChromiumCDPInputRouter.modifiers(from: [.option, .control, .shift]),
            1 | 2 | 8
        )
    }

    func test_cdpButtonForMouseTypes() {
        // Use the event constructors directly — we only exercise the
        // `.type` property which is read-only and set by the constructor.
        let loc = NSPoint(x: 10, y: 10)
        let now = Date().timeIntervalSince1970
        _ = now // silence unused warning on some toolchains

        let leftDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: loc,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        XCTAssertEqual(ChromiumCDPInputRouter.cdpButton(for: leftDown), "left")

        let rightDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: loc,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        XCTAssertEqual(ChromiumCDPInputRouter.cdpButton(for: rightDown), "right")

        let otherDown = NSEvent.mouseEvent(
            with: .otherMouseDown,
            location: loc,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        XCTAssertEqual(ChromiumCDPInputRouter.cdpButton(for: otherDown), "middle")

        let moved = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: loc,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
        XCTAssertEqual(ChromiumCDPInputRouter.cdpButton(for: moved), "none")
    }
}
