import CoreGraphics
import Foundation
@testable import Lume
import Testing

struct EPGRealizeWindowTests {
    @Test func `window covers the viewport plus one block on each side, snapped to blocks`() {
        let window = EPGRealizeWindow.around(offset: 4400, viewport: 1680, blockLength: 360)
        #expect(window.start == 3960)
        #expect(window.end == 6480)
    }

    @Test func `window clamps to zero at the leading edge`() {
        let window = EPGRealizeWindow.around(offset: 0, viewport: 1680, blockLength: 360)
        #expect(window.start == 0)
        #expect(window.end == 2160)
    }

    @Test func `window is stable between block crossings`() {
        let blockLength: CGFloat = 360
        let base = EPGRealizeWindow.around(offset: 800, viewport: 1800, blockLength: blockLength)
        let withinBlock = EPGRealizeWindow.around(offset: 1000, viewport: 1800, blockLength: blockLength)
        let nextBlock = EPGRealizeWindow.around(offset: 1100, viewport: 1800, blockLength: blockLength)
        #expect(base == withinBlock)
        #expect(base != nextBlock)
    }
}
