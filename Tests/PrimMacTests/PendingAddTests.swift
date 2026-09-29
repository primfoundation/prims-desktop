import XCTest
@testable import PrimMacCore

final class PendingAddTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-add-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("prims"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let desktop = """
        {"active_profile":"personal","profiles":{"personal":{"folder":"\(profile.path)"}}}
        """
        try desktop.write(to: home.appendingPathComponent("prims/desktop.json"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("case.prim")
        try Data("prim-one".utf8).write(to: source)
        return (home, profile, source)
    }

    func testRequestApproveIsHashBoundAndProfileScoped() throws {
        let (home, profile, source) = try fixture()
        let req = try PendingAdd.request(source: source, relativeTarget: "orf/case.prim", home: home)
        XCTAssertEqual(req.status, "pending")
        XCTAssertEqual(try PendingAdd.list(home: home).count, 1)

        try Data("changed".utf8).write(to: source)
        XCTAssertThrowsError(try PendingAdd.approve(id: req.id, home: home))

        try Data("prim-one".utf8).write(to: source)
        let dest = try PendingAdd.approve(id: req.id, home: home)
        XCTAssertEqual(dest.path, profile.appendingPathComponent("orf/case.prim").path)
        XCTAssertEqual(try Data(contentsOf: dest), Data("prim-one".utf8))
        XCTAssertEqual(try PendingAdd.list(home: home).first?.status, "approved")
        XCTAssertThrowsError(try PendingAdd.approve(id: req.id, home: home))
    }

    func testRejectsTraversalAndCanDeny() throws {
        let (home, _, source) = try fixture()
        XCTAssertThrowsError(try PendingAdd.request(source: source, relativeTarget: "../escape.prim", home: home))
        let req = try PendingAdd.request(source: source, home: home)
        try PendingAdd.deny(id: req.id, home: home)
        XCTAssertEqual(try PendingAdd.list(home: home).first?.status, "denied")
    }

    func testDuplicatePendingRequestIsIdempotent() throws {
        let (home, _, source) = try fixture()
        let a = try PendingAdd.request(source: source, home: home)
        let b = try PendingAdd.request(source: source, home: home)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(try PendingAdd.list(home: home).count, 1)
    }
}
