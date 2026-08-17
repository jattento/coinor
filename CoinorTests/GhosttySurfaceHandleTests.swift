import Foundation
import Testing

@testable import Coinor

@Suite
struct GhosttySurfaceHandleTests {
    @Test
    func withHandleStopsRunningOnceTheSurfaceIsFreed() {
        let address: UInt = 0xF00D
        let probe = GhosttySurfaceHandleProbe(expectedAddress: address)
        let owner = GhosttySurfaceHandle { _ in probe.recordFree() }
        owner.adopt(UnsafeMutableRawPointer(bitPattern: address)!)

        #expect(owner.isValid)
        #expect(owner.withHandle { UInt(bitPattern: $0) } == address)

        owner.invalidate()

        #expect(!owner.isValid)
        #expect(owner.withHandle { UInt(bitPattern: $0) } == nil)
        #expect(probe.snapshot.frees == 1)
    }

    @Test
    func repeatedInvalidationFreesTheSurfaceOnce() {
        let address: UInt = 0xBEEF
        let probe = GhosttySurfaceHandleProbe(expectedAddress: address)
        let owner = GhosttySurfaceHandle { _ in probe.recordFree() }
        owner.adopt(UnsafeMutableRawPointer(bitPattern: address)!)

        owner.invalidate()
        owner.invalidate()
        owner.invalidate()

        #expect(probe.snapshot.frees == 1)
    }

    @Test
    func neverFreesASurfaceItDidNotAdopt() {
        let probe = GhosttySurfaceHandleProbe(expectedAddress: 0)
        let owner = GhosttySurfaceHandle { _ in probe.recordFree() }

        #expect(!owner.isValid)
        #expect(owner.withHandle { UInt(bitPattern: $0) } == nil)

        owner.invalidate()

        #expect(probe.snapshot.frees == 0)
    }

    /// Reproduces the clipboard callback racing shutdown: readers hammer the
    /// handle from every thread while one of them frees the surface.
    @Test
    func concurrentUseNeverRunsAfterInvalidation() {
        let address: UInt = 0xCAFE
        let probe = GhosttySurfaceHandleProbe(expectedAddress: address)
        let owner = GhosttySurfaceHandle { _ in probe.recordFree() }
        owner.adopt(UnsafeMutableRawPointer(bitPattern: address)!)

        let workers = 64
        DispatchQueue.concurrentPerform(iterations: workers) { index in
            guard index != workers / 2 else {
                owner.invalidate()
                return
            }
            for _ in 0..<500 {
                owner.withHandle { handle in
                    probe.recordUse(address: UInt(bitPattern: handle))
                }
            }
        }

        let snapshot = probe.snapshot
        #expect(snapshot.frees == 1)
        #expect(snapshot.usesAfterFree == 0)
        #expect(snapshot.foreignHandles == 0)
        #expect(snapshot.uses > 0)
        #expect(!owner.isValid)
    }

    /// Paste goes `ghostty_surface_key` → clipboard callback →
    /// `withHandle` again on the same thread. A non-recursive lock deadlocks.
    @Test
    func nestedWithHandleReentersOnTheSameThread() {
        let address: UInt = 0xFEED
        let probe = GhosttySurfaceHandleProbe(expectedAddress: address)
        let owner = GhosttySurfaceHandle { _ in probe.recordFree() }
        owner.adopt(UnsafeMutableRawPointer(bitPattern: address)!)

        let inner = owner.withHandle { outer in
            probe.recordUse(address: UInt(bitPattern: outer))
            return owner.withHandle { inner in
                probe.recordUse(address: UInt(bitPattern: inner))
                return UInt(bitPattern: inner)
            }
        }

        #expect(inner == address)
        #expect(probe.snapshot.uses == 2)
        #expect(probe.snapshot.usesAfterFree == 0)
        owner.invalidate()
        #expect(probe.snapshot.frees == 1)
    }
}

/// Stands in for `ghostty_surface_free` so the handle's lifecycle can be
/// exercised without a live Ghostty surface. The counters are locked because
/// the owner is driven from several threads at once.
private final class GhosttySurfaceHandleProbe: @unchecked Sendable {
    struct Snapshot {
        let uses: Int
        let frees: Int
        let usesAfterFree: Int
        let foreignHandles: Int
    }

    private let expectedAddress: UInt
    private let lock = NSLock()
    private var uses = 0
    private var frees = 0
    private var usesAfterFree = 0
    private var foreignHandles = 0

    init(expectedAddress: UInt) {
        self.expectedAddress = expectedAddress
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            uses: uses,
            frees: frees,
            usesAfterFree: usesAfterFree,
            foreignHandles: foreignHandles
        )
    }

    func recordUse(address: UInt) {
        lock.lock()
        defer { lock.unlock() }
        uses += 1
        if frees > 0 { usesAfterFree += 1 }
        if address != expectedAddress { foreignHandles += 1 }
    }

    func recordFree() {
        lock.lock()
        defer { lock.unlock() }
        frees += 1
    }
}
