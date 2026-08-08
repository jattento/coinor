import CoreGraphics
import Testing
@testable import Coinor

@Suite
struct GhosttySurfaceResizePolicyTests {
    @Test
    func visibleSurfaceAppliesOnlyChangedSizes() {
        var policy = GhosttySurfaceResizePolicy()
        let size = CGSize(width: 1200, height: 800)

        #expect(policy.requestedSize(size, hostVisible: true) == size)
        #expect(policy.requestedSize(size, hostVisible: true) == nil)
    }

    @Test
    func hiddenSurfaceDefersEveryIntermediateResize() {
        var policy = GhosttySurfaceResizePolicy()
        let first = CGSize(width: 1200, height: 800)
        let latest = CGSize(width: 980, height: 800)

        #expect(policy.requestedSize(first, hostVisible: false) == nil)
        #expect(policy.requestedSize(latest, hostVisible: false) == nil)
        #expect(policy.pendingSize == latest)
        #expect(policy.lastAppliedSize == .zero)
    }

    @Test
    func becomingVisibleAppliesCurrentGeometryOnce() {
        var policy = GhosttySurfaceResizePolicy()
        let hiddenSize = CGSize(width: 980, height: 800)
        let visibleSize = CGSize(width: 1020, height: 800)

        #expect(
            policy.requestedSize(hiddenSize, hostVisible: false) == nil
        )
        #expect(
            policy.requestedSize(visibleSize, hostVisible: true)
                == visibleSize
        )
        #expect(policy.pendingSize == nil)
        #expect(
            policy.requestedSize(visibleSize, hostVisible: true) == nil
        )
    }
}
