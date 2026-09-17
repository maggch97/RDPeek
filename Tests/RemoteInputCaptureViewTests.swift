import AppKit
import RDPKit
import XCTest

@MainActor
final class RemoteInputCaptureViewTests: XCTestCase {
    private struct Harness {
        let window: NSWindow
        let view: RemoteInputCaptureNSView
        let recorder: InputEventRecorder
    }

    // MARK: - Modifier state derived from event flags

    func testModifierPressAndReleaseFollowDeviceFlags() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: true)])
    }

    func testRepeatedFlagsStateSendsNoDuplicateEvents() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testMissedModifierReleaseDoesNotInvertPhase() {
        // Hold Cmd, then Cmd+Tab away: the release happens while another
        // app is active, so the view only sees the window resign key.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()
        resignKey(harness)
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: true)])

        // The next physical Cmd press must be sent as a press, not as the
        // inverted release the old toggle-based logic produced.
        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .leftWindows, isReleased: false)])
    }

    func testKeyDownResyncsStaleModifier() {
        // Cmd-down is tracked, then released without the view ever seeing
        // a flagsChanged. The next keystroke carries the truth in its
        // modifier flags and must repair the remote state first.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 0, characters: "a"))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftWindows, isReleased: true),
            .keyboard(scancode: .letterA, isReleased: false),
        ])
    }

    func testMouseDownResyncsStaleModifier() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.mouseDown(with: mouseEvent(.leftMouseDown, location: NSPoint(x: 100, y: 50)))
        XCTAssertEqual(harness.recorder.events.first, .keyboard(scancode: .leftWindows, isReleased: true))
        XCTAssertTrue(isPointerButton(harness.recorder.events.last, button: .left, isDown: true))
    }

    // MARK: - Window resigning key

    func testResignKeyReleasesPressedKeysAndButtons() {
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.mouseDown(with: mouseEvent(
            .leftMouseDown,
            location: NSPoint(x: 100, y: 50),
            flags: .leftCommandDown
        ))
        harness.recorder.events.removeAll()

        resignKey(harness)
        XCTAssertTrue(harness.recorder.events.contains { isPointerButton($0, button: .left, isDown: false) })
        XCTAssertTrue(harness.recorder.events.contains(.keyboard(scancode: .leftWindows, isReleased: true)))
    }

    // MARK: - Swallowed keyUp while Command is held

    func testCommandReleaseFlushesSwallowedKeyUp() {
        // AppKit never delivers the keyUp for W while Cmd is held, so the
        // flush on Cmd-up must release it.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 13, characters: "w", flags: .leftCommandDown))
        harness.recorder.events.removeAll()

        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x0011), isReleased: true),
            .keyboard(scancode: .leftWindows, isReleased: true),
        ])
    }

    func testKeyRepeatAfterFlushIsRetrackedAndReleased() {
        // Hold Cmd+Left-arrow, release Cmd first: the flush releases the
        // arrow, but auto-repeat keeps pressing it. The repeat must be
        // re-tracked so the final physical keyUp reaches the remote.
        let harness = makeHarness()
        let leftArrow = RDPKeyboardScancode(code: 0x004B, isExtended: true)
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: .leftCommandDown))
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 123, flags: .leftCommandDown))
        harness.view.flagsChanged(with: flagsEvent(keyCode: .leftCommand, flags: []))
        harness.recorder.events.removeAll()

        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 123, isARepeat: true))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftArrow, isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: 123))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: leftArrow, isReleased: true)])
    }

    // MARK: - Key equivalents while controlling the desktop

    func testPerformKeyEquivalentClaimsCommandChordForRemote() {
        // ⌘R must reach the remote as Win+R instead of triggering the
        // Session menu's Reconnect shortcut.
        let harness = makeHarness()
        harness.window.makeFirstResponder(harness.view)

        let handled = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: 15, characters: "r", flags: .leftCommandDown)
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: .leftWindows, isReleased: false),
            .keyboard(scancode: RDPKeyboardScancode(code: 0x0013), isReleased: false),
        ])
    }

    func testPerformKeyEquivalentDefersWithoutInputSession() {
        let harness = makeHarness()
        harness.window.makeFirstResponder(harness.view)
        harness.view.inputSession = nil

        let handled = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: 15, characters: "r", flags: .leftCommandDown)
        )
        XCTAssertFalse(handled)
    }

    func testPerformKeyEquivalentDefersWhenNotFirstResponder() {
        let harness = makeHarness()
        XCTAssertNotIdentical(harness.window.firstResponder, harness.view)

        let handled = harness.view.performKeyEquivalent(
            with: keyEvent(.keyDown, keyCode: 15, characters: "r", flags: .leftCommandDown)
        )
        XCTAssertFalse(handled)
        XCTAssertEqual(harness.recorder.events, [])
    }

    // MARK: - Typing that matches the US layout travels as scancodes

    func testPlainTypingSendsScancodePressReleasePairs() {
        // The remote input method (Chinese, Japanese, Korean) only sees keys
        // that arrive as scancodes, so plain typing must not take the Unicode
        // path it used to, and the physical keyUp has to release the key.
        let harness = makeHarness()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 0, characters: "a"))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .letterA, isReleased: false)])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: 0, characters: "a"))
        XCTAssertEqual(harness.recorder.events, [.keyboard(scancode: .letterA, isReleased: true)])
    }

    func testShiftedCharacterMatchingUSLayoutSendsScancode() {
        // Shift reaches the remote as a modifier of its own, so the shifted
        // character only has to agree with what a US layout prints on the key.
        let harness = makeHarness()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 18, characters: "!", flags: .shift))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x0002), isReleased: false),
        ])
    }

    func testSpaceSendsScancode() {
        // Space types the same character on every layout, so it is one of the
        // keys that always takes the scancode path.
        let harness = makeHarness()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 49, characters: " "))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x0039), isReleased: false),
        ])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: 49, characters: " "))
        XCTAssertEqual(harness.recorder.events, [
            .keyboard(scancode: RDPKeyboardScancode(code: 0x0039), isReleased: true),
        ])
    }

    // MARK: - Keys the local layout moves fall back to Unicode

    func testKeyDisagreeingWithUSLayoutSendsUnicode() {
        // RDPKit announces a US layout, so the server would resolve the Y key
        // position to "y" — a German layout typing "z" there must keep the
        // Unicode path, and its keyUp must stay silent because no scancode was
        // ever pressed.
        let harness = makeHarness()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 16, characters: "z"))
        XCTAssertEqual(harness.recorder.events, [
            .unicode(codeUnit: 0x7A, isReleased: false),
            .unicode(codeUnit: 0x7A, isReleased: true),
        ])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(.keyUp, keyCode: 16, characters: "z"))
        XCTAssertEqual(harness.recorder.events, [])
    }

    func testShiftedCharacterDisagreeingWithUSLayoutSendsUnicode() {
        // A German layout puts " where a US layout puts @, so the shifted
        // character decides the path even though the unshifted digit agrees.
        let harness = makeHarness()
        harness.view.keyDown(with: keyEvent(.keyDown, keyCode: 19, characters: "\"", flags: .shift))
        XCTAssertEqual(harness.recorder.events, [
            .unicode(codeUnit: 0x22, isReleased: false),
            .unicode(codeUnit: 0x22, isReleased: true),
        ])
    }

    func testDeadKeyCompositionSendsUnicode() {
        // ⌥e arms the acute accent, so the next E press arrives composed as
        // “é” while the key position still reports “e”. A scancode would
        // type a bare “e” on the remote, which keeps no dead-key state, so
        // the composed character has to fall back to Unicode — and its keyUp
        // stays silent because no scancode was ever pressed.
        let harness = makeHarness()
        harness.view.keyDown(with: keyEvent(
            .keyDown,
            keyCode: 14,
            characters: "é",
            charactersIgnoringModifiers: "e"
        ))
        XCTAssertEqual(harness.recorder.events, [
            .unicode(codeUnit: 0xE9, isReleased: false),
            .unicode(codeUnit: 0xE9, isReleased: true),
        ])

        harness.recorder.events.removeAll()
        harness.view.keyUp(with: keyEvent(
            .keyUp,
            keyCode: 14,
            characters: "é",
            charactersIgnoringModifiers: "e"
        ))
        XCTAssertEqual(harness.recorder.events, [])
    }

    // MARK: - Lock keys

    func testCapsLockTransitionSynchronizesToggleKeys() {
        // Caps Lock latches as a flag and never arrives as a key event, so the
        // remote learns about it only from a synchronize event. Num Lock rides
        // along unconditionally because the Mac keypad always types digits.
        let harness = makeHarness()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .capsLock, flags: .capsLock))
        XCTAssertEqual(harness.recorder.events, [.synchronize(toggleFlags: [.numLock, .capsLock])])

        harness.recorder.events.removeAll()
        harness.view.flagsChanged(with: flagsEvent(keyCode: .capsLock, flags: []))
        XCTAssertEqual(harness.recorder.events, [.synchronize(toggleFlags: [.numLock])])
    }

    // MARK: - Helpers

    private func makeHarness() -> Harness {
        let recorder = InputEventRecorder()
        let view = RemoteInputCaptureNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.rdpFrame = makeFrameMetadata(width: 200, height: 100)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.inputSession = recorder
        return Harness(window: window, view: view, recorder: recorder)
    }

    private func resignKey(_ harness: Harness) {
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: harness.window
        )
    }

    private func keyEvent(
        _ type: NSEvent.EventType,
        keyCode: UInt16,
        characters: String = "",
        charactersIgnoringModifiers: String? = nil,
        flags: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ) else {
            preconditionFailure("Failed to synthesize key event")
        }
        return event
    }

    private func flagsEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        keyEvent(.flagsChanged, keyCode: keyCode, flags: flags)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        location: NSPoint,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            preconditionFailure("Failed to synthesize mouse event")
        }
        return event
    }

    private func isPointerButton(
        _ event: RDPSlowPathInputEvent?,
        button: RDPPointerButton,
        isDown: Bool
    ) -> Bool {
        guard case let .pointerButton(eventButton, eventIsDown, _, _) = event else {
            return false
        }
        return eventButton == button && eventIsDown == isDown
    }

    private func makeFrameMetadata(width: UInt16, height: UInt16) -> RDPFrameMetadata {
        RDPFrameMetadata(RDPGraphicsFrameSnapshot(
            frameID: 1,
            surfaceID: 0,
            codecID: 0,
            codecName: "test",
            pixelFormat: 0,
            destinationRect: RDPFrameRect(left: 0, top: 0, right: width, bottom: height),
            regionRects: [],
            h264AnnexBData: Data()
        ))
    }
}

@MainActor
private final class InputEventRecorder: RemoteInputEventSink {
    var events: [RDPSlowPathInputEvent] = []

    nonisolated func send(_ events: [RDPSlowPathInputEvent]) {
        MainActor.assumeIsolated {
            self.events += events
        }
    }
}

private extension UInt16 {
    static let leftCommand: UInt16 = 55
    static let capsLock: UInt16 = 57
}

private extension NSEvent.ModifierFlags {
    /// `.command` plus the NX_DEVICELCMDKEYMASK device-dependent bit.
    static let leftCommandDown = NSEvent.ModifierFlags(
        rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0000_0008
    )
}

private extension RDPKeyboardScancode {
    static let leftWindows = RDPKeyboardScancode(code: 0x005B, isExtended: true)
    static let letterA = RDPKeyboardScancode(code: 0x001E)
}
