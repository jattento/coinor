import AppKit
import Testing

@testable import Coinor

@Suite
struct GhosttyMouseCoordinateTests {
    @Test
    func flippedViewUsesLogicalTopLeftCoordinatesWithoutBackingScale() {
        let point = GhosttyMouseCoordinateMapper.surfacePoint(
            viewPoint: CGPoint(x: 45, y: 40),
            bounds: CGRect(x: 5, y: 10, width: 200, height: 120),
            isFlipped: true
        )

        #expect(point == CGPoint(x: 40, y: 30))
    }

    @Test
    func unflippedViewConvertsBottomLeftToTopLeftCoordinates() {
        let point = GhosttyMouseCoordinateMapper.surfacePoint(
            viewPoint: CGPoint(x: 45, y: 40),
            bounds: CGRect(x: 5, y: 10, width: 200, height: 120),
            isFlipped: false
        )

        #expect(point == CGPoint(x: 40, y: 90))
    }
}
