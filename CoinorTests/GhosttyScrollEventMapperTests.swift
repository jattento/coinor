import AppKit
import Testing

@testable import Coinor

@Suite
struct GhosttyScrollEventMapperTests {
    @Test
    func preciseScrollPreservesUnamplifiedDeltas() {
        let event = GhosttyScrollEventMapper.event(
            deltaX: -0.75,
            deltaY: 1.25,
            hasPreciseScrollingDeltas: true,
            momentumPhase: []
        )

        #expect(event.deltaX == -0.75)
        #expect(event.deltaY == 1.25)
        #expect(event.modifiers == 0b0000_0001)
    }

    @Test
    func discreteScrollDoesNotSetPrecision() {
        let event = GhosttyScrollEventMapper.event(
            deltaX: 0,
            deltaY: -1,
            hasPreciseScrollingDeltas: false,
            momentumPhase: []
        )

        #expect(event.modifiers == 0)

        let momentumEvent = GhosttyScrollEventMapper.event(
            deltaX: 0,
            deltaY: -1,
            hasPreciseScrollingDeltas: false,
            momentumPhase: .changed
        )

        #expect(momentumEvent.modifiers == 0b0000_0110)
    }

    @Test
    func momentumPhasesUseGhosttysPackedBitLayout() {
        #expect(modifiers(for: .began) == 0b0000_0011)
        #expect(modifiers(for: .stationary) == 0b0000_0101)
        #expect(modifiers(for: .changed) == 0b0000_0111)
        #expect(modifiers(for: .ended) == 0b0000_1001)
        #expect(modifiers(for: .cancelled) == 0b0000_1011)
        #expect(modifiers(for: .mayBegin) == 0b0000_1101)
    }

    private func modifiers(
        for momentumPhase: NSEvent.Phase
    ) -> Int32 {
        GhosttyScrollEventMapper.event(
            deltaX: 0,
            deltaY: 0,
            hasPreciseScrollingDeltas: true,
            momentumPhase: momentumPhase
        ).modifiers
    }
}
