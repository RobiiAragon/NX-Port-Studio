import Foundation
import XCTest
@testable import PortStudio

@MainActor
final class BuildProgressModelTests: XCTestCase {
    private func model() -> StudioModel {
        let preferences = UserDefaults(suiteName: "org.nxnative.tests.progress." + UUID().uuidString)!
        return StudioModel(nextendoPreferences: preferences)
    }

    func testUncountedFinishingStepDiscardsPreviousFraction() async {
        let model = model()
        model.receive(#"{"ev":"progress","step":"preparing base artifacts","frac":0.75}"#)
        XCTAssertEqual(model.progress, 0.75)
        model.receive(#"{"ev":"step","step":"finishing variants and reflection"}"#)
        XCTAssertNil(model.progress)
        model.receive(#"{"ev":"progress","step":"finishing variants and reflection","frac":null}"#)
        XCTAssertNil(model.progress)
        XCTAssertEqual(model.stepName, "finishing variants and reflection")
    }

    func testProgressWithoutFractionClearsAnEarlierCount() async {
        let model = model()
        model.receive(#"{"ev":"progress","frac":0.5}"#)
        model.receive(#"{"ev":"progress","frac":null}"#)
        XCTAssertNil(model.progress)
    }

    func testUnrelatedEventsPreserveFractionAndNewStageResetsIt() async {
        let model = model()
        model.receive(#"{"ev":"progress","frac":0.25}"#)
        model.receive(#"{"ev":"say","msg":"synthetic child output"}"#)
        XCTAssertEqual(model.progress, 0.25)
        model.receive(#"{"ev":"stage","name":"host build"}"#)
        XCTAssertNil(model.progress)
        model.receive(#"{"ev":"progress","frac":0.1}"#)
        XCTAssertEqual(model.progress, 0.1)
    }
}
