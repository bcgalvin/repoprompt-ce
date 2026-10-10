import Foundation
@testable import RepoPromptProcess
import XCTest

final class LineFramerTests: XCTestCase {
    func testCompletedOversizedLineFailsWithoutDispatchingSuffix() {
        var framer = LineFramer(limits: .init(maxLineBytes: 16, maxCarryBytes: 16, tailRetainBytes: 0))
        var lines: [Data] = []
        let failure = framer.feed(Data((String(repeating: "x", count: 17) + "\n{}\n").utf8)) { lines.append($0) }
        XCTAssertEqual(failure?.limitBytes, 16)
        XCTAssertTrue(lines.isEmpty)
        framer.flush { lines.append($0) }
        XCTAssertTrue(lines.isEmpty, "A failed feed must not retain a truncated suffix")
    }

    func testSplitLogicalRecordCountsEmbeddedNewlineAgainstBudget() {
        var framer = LineFramer(limits: .init(maxLineBytes: 16, maxCarryBytes: 16, tailRetainBytes: 0))
        var lines: [Data] = []
        XCTAssertNil(framer.feed(Data("{\"text\":\"123\n".utf8)) { lines.append($0) })
        XCTAssertEqual(framer.feed(Data("45678\"}\n{}\n".utf8)) { lines.append($0) }?.limitBytes, 16)
        XCTAssertTrue(lines.isEmpty)
    }

    func testExactBudgetLineAndLegacyTailRecoveryRemainSupported() {
        var strict = LineFramer(limits: .init(maxLineBytes: 16, maxCarryBytes: 16, tailRetainBytes: 0))
        var lines: [Data] = []
        XCTAssertNil(strict.feed(Data((String(repeating: "x", count: 16) + "\n{}\n").utf8)) { lines.append($0) })
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [String(repeating: "x", count: 16), "{}"])

        var legacy = LineFramer(limits: .init(maxLineBytes: 16, maxCarryBytes: 32, tailRetainBytes: 4))
        var diagnosed = false
        XCTAssertNil(legacy.feed(Data(String(repeating: "x", count: 17).utf8), onDiagnostic: {
            if case let .overflow(dropped, retained) = $0 {
                XCTAssertEqual(dropped, 13)
                XCTAssertEqual(retained, 4)
                diagnosed = true
            }
        }, onLine: { _ in XCTFail("Incomplete line emitted") }))
        XCTAssertTrue(diagnosed)
        legacy.flush { XCTAssertEqual($0, Data("xxxx".utf8)) }
    }
}
