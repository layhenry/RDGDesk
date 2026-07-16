import XCTest
@testable import RdcCore

final class RemoteInputTests: XCTestCase {
    func testCommittedTextProducesUTF16DownUpEventsIncludingSurrogatePair() {
        var state = RemoteTextInputState()

        XCTAssertEqual(state.selectedRange, NSRange(location: 0, length: 0))

        let events = state.commit("A中😀", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual(events, [
            RemoteUnicodeKeyEvent(codeUnit: 0x0041, phase: .down),
            RemoteUnicodeKeyEvent(codeUnit: 0x0041, phase: .up),
            RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .down),
            RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .up),
            RemoteUnicodeKeyEvent(codeUnit: 0xD83D, phase: .down),
            RemoteUnicodeKeyEvent(codeUnit: 0xD83D, phase: .up),
            RemoteUnicodeKeyEvent(codeUnit: 0xDE00, phase: .down),
            RemoteUnicodeKeyEvent(codeUnit: 0xDE00, phase: .up)
        ])
        XCTAssertEqual(state.selectedRange, NSRange(location: 0, length: 0))
    }

    func testUnmarkCommitsMarkedTextOnceWhileDiscardResetDoesNotCommit() {
        var state = RemoteTextInputState()
        state.setMarkedText(
            "中😀",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertEqual(state.commitMarkedText(), [
            RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .down),
            RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .up),
            RemoteUnicodeKeyEvent(codeUnit: 0xD83D, phase: .down),
            RemoteUnicodeKeyEvent(codeUnit: 0xD83D, phase: .up),
            RemoteUnicodeKeyEvent(codeUnit: 0xDE00, phase: .down),
            RemoteUnicodeKeyEvent(codeUnit: 0xDE00, phase: .up)
        ])
        XCTAssertFalse(state.hasMarkedText)
        XCTAssertEqual(state.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertTrue(state.commitMarkedText().isEmpty)

        state.setMarkedText(
            "discard me",
            selectedRange: NSRange(location: 10, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        state.discardMarkedText()
        XCTAssertFalse(state.hasMarkedText)
        XCTAssertEqual(state.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertTrue(state.commitMarkedText().isEmpty)
    }

    func testInsertCommitClearsMarkedTextSoLaterUnmarkDoesNotDoubleCommit() {
        var state = RemoteTextInputState()
        state.setMarkedText(
            "zhong",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        let inserted = state.commit("中", replacementRange: NSRange(location: 0, length: 5))

        XCTAssertEqual(inserted.map(\.codeUnit), [0x4E2D, 0x4E2D])
        XCTAssertTrue(state.commitMarkedText().isEmpty)
        XCTAssertEqual(state.selectedRange, NSRange(location: 0, length: 0))
    }

    func testMarkedCompositionStaysLocalUntilCommitAndResetClearsIt() {
        var state = RemoteTextInputState()

        state.setMarkedText(
            "zhong",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(state.hasMarkedText)
        XCTAssertEqual(state.markedText, "zhong")
        XCTAssertEqual(state.markedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(state.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertEqual(state.replacementRange, NSRange(location: NSNotFound, length: 0))

        let events = state.commit(
            "中", replacementRange: NSRange(location: 0, length: 5)
        )
        XCTAssertFalse(state.hasMarkedText)
        XCTAssertEqual(events.map(\.codeUnit), [0x4E2D, 0x4E2D])

        state.setMarkedText(
            "wen", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        state.reset()
        XCTAssertFalse(state.hasMarkedText)
        XCTAssertEqual(state.markedRange.location, NSNotFound)
        XCTAssertEqual(state.selectedRange, NSRange(location: 0, length: 0))
    }

    func testAspectFitRectCentersRemoteImageInsideView() {
        XCTAssertEqual(
            RemoteInputTranslator.aspectFitRect(
                viewWidth: 1280,
                viewHeight: 900,
                remoteWidth: 1920,
                remoteHeight: 1080
            ),
            RemoteRect(x: 0, y: 90, width: 1280, height: 720)
        )
    }

    func testRenderGeometryKeepsCGImageUprightAndTopLeftMapsToRemoteOrigin() throws {
        let geometry = try XCTUnwrap(RemoteInputTranslator.renderGeometry(
            viewWidth: 1280,
            viewHeight: 900,
            remoteWidth: 1920,
            remoteHeight: 1080
        ))

        XCTAssertEqual(
            geometry,
            RemoteRenderGeometry(
                contentRect: RemoteRect(x: 0, y: 90, width: 1280, height: 720),
                cgImageNeedsVerticalFlip: false
            )
        )
        XCTAssertEqual(
            RemoteInputTranslator.remotePoint(
                localX: geometry.contentRect.x,
                localY: geometry.contentRect.y + geometry.contentRect.height,
                viewWidth: 1280,
                viewHeight: 900,
                remoteWidth: 1920,
                remoteHeight: 1080
            ),
            RemotePoint(x: 0, y: 0)
        )
    }

    func testPointerCoordinatesScaleFromViewToRemotePixels() {
        let point = RemoteInputTranslator.remotePoint(
            localX: 640,
            localY: 450,
            viewWidth: 1280,
            viewHeight: 900,
            remoteWidth: 1920,
            remoteHeight: 1080
        )

        XCTAssertEqual(point, RemotePoint(x: 960, y: 540))
    }

    func testPointerCoordinatesFlipAppKitYAxis() {
        let nearTop = RemoteInputTranslator.remotePoint(
            localX: 50,
            localY: 90,
            viewWidth: 100,
            viewHeight: 100,
            remoteWidth: 100,
            remoteHeight: 100
        )
        let nearBottom = RemoteInputTranslator.remotePoint(
            localX: 50,
            localY: 10,
            viewWidth: 100,
            viewHeight: 100,
            remoteWidth: 100,
            remoteHeight: 100
        )

        XCTAssertEqual(nearTop, RemotePoint(x: 50, y: 10))
        XCTAssertEqual(nearBottom, RemotePoint(x: 50, y: 90))
    }

    func testPointerMappingIgnoresAspectFitLetterboxBars() {
        XCTAssertNil(RemoteInputTranslator.remotePoint(
            localX: 640,
            localY: 50,
            viewWidth: 1280,
            viewHeight: 900,
            remoteWidth: 1920,
            remoteHeight: 1080
        ))
        XCTAssertNil(RemoteInputTranslator.remotePoint(
            localX: 640,
            localY: 850,
            viewWidth: 1280,
            viewHeight: 900,
            remoteWidth: 1920,
            remoteHeight: 1080
        ))
    }

    func testPointerMappingClampsDrawnEdgesToRemotePixelBounds() {
        let topRight = RemoteInputTranslator.remotePoint(
            localX: 100,
            localY: 78.125,
            viewWidth: 100,
            viewHeight: 100,
            remoteWidth: 1920,
            remoteHeight: 1080
        )
        let bottomLeft = RemoteInputTranslator.remotePoint(
            localX: 0,
            localY: 21.875,
            viewWidth: 100,
            viewHeight: 100,
            remoteWidth: 1920,
            remoteHeight: 1080
        )

        XCTAssertEqual(topRight, RemotePoint(x: 1919, y: 0))
        XCTAssertEqual(bottomLeft, RemotePoint(x: 0, y: 1079))
    }

    func testPointerMappingIsIndependentOfRetinaBackingScale() {
        let oneX = RemoteInputTranslator.remotePoint(
            localX: 300,
            localY: 250,
            viewWidth: 600,
            viewHeight: 500,
            remoteWidth: 1200,
            remoteHeight: 1000
        )
        let twoX = RemoteInputTranslator.remotePoint(
            localX: 600,
            localY: 500,
            viewWidth: 1200,
            viewHeight: 1000,
            remoteWidth: 1200,
            remoteHeight: 1000
        )

        XCTAssertEqual(oneX, twoX)
    }

    func testMouseButtonDownAndUpProduceExplicitFlags() {
        let point = RemotePoint(x: 10, y: 20)

        XCTAssertEqual(
            RemotePointerEvent(point: point, action: .button(.left, phase: .down)).flags,
            0x9000
        )
        XCTAssertEqual(
            RemotePointerEvent(point: point, action: .button(.left, phase: .up)).flags,
            0x1000
        )
    }

    func testWheelDirectionProducesPositiveAndNegativeFlags() {
        let point = RemotePoint(x: 10, y: 20)
        let up = RemotePointerEvent(point: point, action: .verticalWheel(delta: 120))
        let down = RemotePointerEvent(point: point, action: .verticalWheel(delta: -120))

        XCTAssertEqual(up.flags, 0x0278)
        XCTAssertEqual(down.flags, 0x0388)
    }

    func testWheelMagnitudeUsesSignedNineBitBoundaries() {
        let point = RemotePoint(x: 10, y: 20)

        XCTAssertEqual(
            RemotePointerEvent(point: point, action: .verticalWheel(delta: 255)).flags,
            0x02FF
        )
        XCTAssertEqual(
            RemotePointerEvent(point: point, action: .verticalWheel(delta: -255)).flags,
            0x0301
        )
        XCTAssertEqual(
            RemotePointerEvent(point: point, action: .verticalWheel(delta: 256)).flags,
            0x02FF
        )
        XCTAssertEqual(
            RemotePointerEvent(point: point, action: .verticalWheel(delta: -256)).flags,
            0x0301
        )
    }

    func testDeleteKeyProducesFreeRDPScanCode() {
        XCTAssertEqual(RemoteInputTranslator.scanCode(forMacKeyCode: 51), 0x0E)
    }

    func testKeyDownAndUpKeepReleaseSemanticsExplicit() {
        let down = RemoteInputTranslator.keyEvent(forMacKeyCode: 51, phase: .down)
        let up = RemoteInputTranslator.keyEvent(forMacKeyCode: 51, phase: .up)

        XCTAssertEqual(down, RemoteKeyEvent(scanCode: 0x0E, phase: .down))
        XCTAssertEqual(up, RemoteKeyEvent(scanCode: 0x0E, phase: .up))
        XCTAssertEqual(down?.flags, 0)
        XCTAssertEqual(up?.flags, 0x8000)
    }

    func testUnicodeDownAndUpKeepReleaseSemanticsExplicit() {
        XCTAssertEqual(RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .down).flags, 0)
        XCTAssertEqual(RemoteUnicodeKeyEvent(codeUnit: 0x4E2D, phase: .up).flags, 0x8000)
    }

    func testTextHandledPhysicalKeySuppressesExactlyOneRawKeyUp() {
        var routing = RemoteTextKeyRoutingState()

        routing.recordTextHandledKeyDown(0)

        XCTAssertTrue(routing.consumeTextHandledKeyUp(0))
        XCTAssertFalse(routing.consumeTextHandledKeyUp(0))
        XCTAssertFalse(routing.consumeTextHandledKeyUp(1))
    }

    func testModifierTransitionsMapToTheirOwnKeyEvents() {
        XCTAssertEqual(
            RemoteInputTranslator.keyEvent(forMacKeyCode: 56, phase: .down),
            RemoteKeyEvent(scanCode: 0x2A, phase: .down)
        )
        XCTAssertEqual(
            RemoteInputTranslator.keyEvent(forMacKeyCode: 56, phase: .up),
            RemoteKeyEvent(scanCode: 0x2A, phase: .up)
        )
        XCTAssertEqual(
            RemoteInputTranslator.keyEvent(forMacKeyCode: 59, phase: .down),
            RemoteKeyEvent(scanCode: 0x1D, phase: .down)
        )
    }

    func testExtendedKeyIncludesExtendedFlag() {
        let event = RemoteInputTranslator.keyEvent(forMacKeyCode: 123, phase: .down)

        XCTAssertEqual(event, RemoteKeyEvent(scanCode: 0x4B, phase: .down, isExtended: true))
        XCTAssertEqual(event?.flags, 0x0100)
    }

    func testUnsupportedKeyReturnsNil() {
        XCTAssertNil(RemoteInputTranslator.scanCode(forMacKeyCode: UInt16.max))
        XCTAssertNil(RemoteInputTranslator.keyEvent(forMacKeyCode: UInt16.max, phase: .down))
    }

    func testKeyWithoutDefinedRDPScanCodeReturnsNil() {
        XCTAssertNil(RemoteInputTranslator.scanCode(forMacKeyCode: 81))
    }

    func testModifierStateDerivesDownAndUpFromReportedFlagState() {
        var state = RemoteModifierState()

        XCTAssertEqual(
            state.transition(forMacKeyCode: 56, isActive: true),
            [RemoteKeyEvent(scanCode: 0x2A, phase: .down)]
        )
        XCTAssertEqual(state.transition(forMacKeyCode: 56, isActive: true), [])
        XCTAssertEqual(
            state.transition(forMacKeyCode: 56, isActive: false),
            [RemoteKeyEvent(scanCode: 0x2A, phase: .up)]
        )
    }

    func testModifierStateIgnoresFirstObservedRelease() {
        var state = RemoteModifierState()

        XCTAssertEqual(state.transition(forMacKeyCode: 59, isActive: false), [])
    }

    func testModifierStateTracksBothPhysicalShiftKeysWithAggregateFlags() {
        var state = RemoteModifierState()

        XCTAssertEqual(
            state.transition(forMacKeyCode: 56, isActive: true),
            [RemoteKeyEvent(scanCode: 0x2A, phase: .down)]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 60, isActive: true),
            [RemoteKeyEvent(scanCode: 0x36, phase: .down)]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 56, isActive: true),
            [RemoteKeyEvent(scanCode: 0x2A, phase: .up)]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 60, isActive: false),
            [RemoteKeyEvent(scanCode: 0x36, phase: .up)]
        )
    }

    func testModifierStateTracksBothPhysicalControlKeysWithAggregateFlags() {
        var state = RemoteModifierState()

        XCTAssertEqual(
            state.transition(forMacKeyCode: 59, isActive: true),
            [RemoteKeyEvent(scanCode: 0x1D, phase: .down)]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 62, isActive: true),
            [RemoteKeyEvent(scanCode: 0x1D, phase: .down, isExtended: true)]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 59, isActive: true),
            [RemoteKeyEvent(scanCode: 0x1D, phase: .up)]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 62, isActive: false),
            [RemoteKeyEvent(scanCode: 0x1D, phase: .up, isExtended: true)]
        )
    }

    func testModifierStateResynchronizesBothShiftKeysBeforeAggregateReleases() {
        var state = RemoteModifierState()

        XCTAssertEqual(
            state.synchronize(physicallyActive: [56, 60]),
            [
                RemoteKeyEvent(scanCode: 0x2A, phase: .down),
                RemoteKeyEvent(scanCode: 0x36, phase: .down)
            ]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 56, isActive: true),
            [RemoteKeyEvent(scanCode: 0x2A, phase: .up)]
        )
        XCTAssertEqual(
            state.transition(forMacKeyCode: 60, isActive: false),
            [RemoteKeyEvent(scanCode: 0x36, phase: .up)]
        )
        XCTAssertEqual(state.releaseAll(), [])
    }

    func testModifierStateFocusGainWithoutPhysicalKeysIsIdempotentAndReleasesStaleKeys() {
        var state = RemoteModifierState()

        XCTAssertEqual(state.synchronize(physicallyActive: []), [])
        XCTAssertEqual(state.synchronize(physicallyActive: []), [])
        XCTAssertEqual(
            state.synchronize(physicallyActive: [59]),
            [RemoteKeyEvent(scanCode: 0x1D, phase: .down)]
        )
        XCTAssertEqual(
            state.synchronize(physicallyActive: []),
            [RemoteKeyEvent(scanCode: 0x1D, phase: .up)]
        )
        XCTAssertEqual(state.synchronize(physicallyActive: []), [])
    }

    func testModifierStateSynchronizationExcludesCapsLock() {
        var state = RemoteModifierState()

        XCTAssertEqual(state.synchronize(physicallyActive: [57]), [])
    }

    func testFocusPolicySynchronizesModifiersOnlyForFirstResponderInKeyWindow() {
        XCTAssertFalse(
            RemoteInputFocusPolicy.shouldSynchronizeModifiers(
                didBecomeFirstResponder: true,
                isKeyWindow: false
            )
        )
        XCTAssertTrue(
            RemoteInputFocusPolicy.shouldSynchronizeModifiers(
                didBecomeFirstResponder: true,
                isKeyWindow: true
            )
        )
        XCTAssertFalse(
            RemoteInputFocusPolicy.shouldSynchronizeModifiers(
                didBecomeFirstResponder: false,
                isKeyWindow: true
            )
        )
    }

    func testModifierStateReleasesEveryActiveModifierOnFocusLoss() {
        var state = RemoteModifierState()
        _ = state.transition(forMacKeyCode: 56, isActive: true)
        _ = state.transition(forMacKeyCode: 59, isActive: true)

        XCTAssertEqual(
            state.releaseAll(),
            [
                RemoteKeyEvent(scanCode: 0x2A, phase: .up),
                RemoteKeyEvent(scanCode: 0x1D, phase: .up)
            ]
        )
        XCTAssertEqual(state.releaseAll(), [])
    }

    func testCapsLockIsADiscreteDownUpSequenceAndNeverStaysActive() {
        var state = RemoteModifierState()

        XCTAssertEqual(
            state.capsLockToggle(forMacKeyCode: 57),
            [
                RemoteKeyEvent(scanCode: 0x3A, phase: .down),
                RemoteKeyEvent(scanCode: 0x3A, phase: .up)
            ]
        )
        XCTAssertEqual(state.releaseAll(), [])
    }

    func testRemoteFramesHaveCheapStablePerFrameIdentity() {
        let first = RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [0, 0, 0, 0])
        let copied = first
        let second = RemoteFrame(width: 1, height: 1, stride: 4, bgraBytes: [0, 0, 0, 0])

        XCTAssertEqual(copied.identity, first.identity)
        XCTAssertNotEqual(second.identity, first.identity)
    }

    func testPointerStateReleasesMultipleButtonsAtLastValidPoint() {
        var state = RemotePointerState()
        let firstPoint = RemotePoint(x: 10, y: 20)
        let lastPoint = RemotePoint(x: 30, y: 40)

        XCTAssertEqual(
            state.buttonEvent(.left, phase: .down, at: firstPoint),
            RemotePointerEvent(point: firstPoint, action: .button(.left, phase: .down))
        )
        XCTAssertEqual(
            state.buttonEvent(.right, phase: .down, at: lastPoint),
            RemotePointerEvent(point: lastPoint, action: .button(.right, phase: .down))
        )
        XCTAssertEqual(
            state.releaseAllButtons(),
            [
                RemotePointerEvent(point: lastPoint, action: .button(.left, phase: .up)),
                RemotePointerEvent(point: lastPoint, action: .button(.right, phase: .up))
            ]
        )
        XCTAssertEqual(state.releaseAllButtons(), [])
    }

    func testPointerStateFocusLossIsIdempotentAndOutsideReleaseUsesLastPoint() {
        var state = RemotePointerState()
        let point = RemotePoint(x: 30, y: 40)
        _ = state.buttonEvent(.middle, phase: .down, at: point)

        XCTAssertEqual(
            state.buttonEvent(.middle, phase: .up, at: nil),
            RemotePointerEvent(point: point, action: .button(.middle, phase: .up))
        )
        XCTAssertEqual(state.releaseAllButtons(), [])
        XCTAssertEqual(state.releaseAllButtons(), [])
    }

    func testResizeDebounceStateCoalescesAndCompletesOnlyLatestRequest() throws {
        var state = RemoteResizeDebounceState()
        state.attach()
        let first = try XCTUnwrap(state.schedule(width: 800, height: 600))
        let latest = try XCTUnwrap(state.schedule(width: 1600, height: 1200))

        XCTAssertNil(state.complete(first))
        XCTAssertEqual(
            state.complete(latest),
            RemoteSize(width: 1600, height: 1200)
        )
        XCTAssertNil(state.complete(latest))
    }

    func testResizeDebounceStateDetachCancelsPendingRequest() throws {
        var state = RemoteResizeDebounceState()

        XCTAssertNil(state.schedule(width: 800, height: 600))
        state.attach()
        let pending = try XCTUnwrap(state.schedule(width: 800, height: 600))
        state.detach()

        XCTAssertNil(state.complete(pending))
        state.attach()
        let replacement = try XCTUnwrap(state.schedule(width: 800, height: 600))
        XCTAssertNotEqual(replacement, pending)
        XCTAssertEqual(
            state.complete(replacement),
            RemoteSize(width: 800, height: 600)
        )
    }

    func testResizeDebounceStateCancelsPendingChangeWhenSizeReturnsToCurrent() throws {
        var state = RemoteResizeDebounceState()
        state.attach()
        let initial = try XCTUnwrap(state.schedule(width: 800, height: 600))
        XCTAssertEqual(state.complete(initial), RemoteSize(width: 800, height: 600))

        let changed = try XCTUnwrap(state.schedule(width: 1600, height: 1200))
        let returned = try XCTUnwrap(state.schedule(width: 800, height: 600))

        XCTAssertNil(state.complete(changed))
        XCTAssertNil(state.complete(returned))
    }
}
