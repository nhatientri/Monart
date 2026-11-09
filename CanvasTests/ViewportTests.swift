import XCTest
@testable import Canvas

final class ViewportTests: XCTestCase {
    func testZoomStepsThroughPresetLevels() {
        XCTAssertEqual(Viewport.nextLevel(after: 1, direction: 1), 1.5)
        XCTAssertEqual(Viewport.nextLevel(after: 1, direction: -1), 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(Viewport.nextLevel(after: 0.44, direction: 1), 0.5, "from a fitted zoom to the next preset")
        XCTAssertEqual(Viewport.nextLevel(after: 0.44, direction: -1), 1.0 / 3, accuracy: 0.0001)
    }

    func testZoomStepsStopAtTheLimits() {
        XCTAssertEqual(Viewport.nextLevel(after: 64, direction: 1), Viewport.zoomRange.upperBound)
        XCTAssertEqual(Viewport.nextLevel(after: 0.02, direction: -1), Viewport.zoomRange.lowerBound)
    }
}
