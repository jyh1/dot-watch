import XCTest

final class DotPageTests: XCTestCase {
    let id = "00000000-0000-4000-8000-000000000001"
    func testAcceptsPageURLAndBareID() throws {
        XCTAssertEqual(try DotPage.identifier(from: "https://chatgpt.com/dots/\(id)"), id)
        XCTAssertEqual(try DotPage.identifier(from: " \(id)\n"), id)
    }
    func testRejectsOtherOriginsAndAmbiguousLinks() {
        for input in ["", "https://example.com/dots/\(id)", "http://chatgpt.com/dots/\(id)", "https://chatgpt.com/c/\(id)", "https://user@chatgpt.com/dots/\(id)", "https://chatgpt.com/dots/\(id)?token=test"] {
            XCTAssertThrowsError(try DotPage.identifier(from: input))
        }
    }
}
