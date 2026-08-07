import Testing
@testable import Coinor

@Suite
struct TerminalSessionFocusTests {
    @Test
    func defersAndConsumesFocusExactlyOnce() {
        var latch = TerminalFocusLatch()
        var focusCount = 0

        latch.request(perform: nil)
        latch.consumeOnAttachment {
            focusCount += 1
        }
        latch.consumeOnAttachment {
            focusCount += 1
        }

        #expect(focusCount == 1)
    }

    @Test
    func keepsImmediateFocusBehaviorWhenAttached() {
        var latch = TerminalFocusLatch()
        var focusCount = 0

        latch.request {
            focusCount += 1
        }

        #expect(focusCount == 1)
    }
}
