import XCTest
@testable import RoadsAndRunesCore

final class FightCopyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testWhatGotAwaySaysHowNearAndHowLongItStays() {
        let stag = FightReport(id: UUID(), name: "Grey Stag", tier: 3, outcome: "LOOSENED", holdMax: 400, holdBefore: 400, holdAfter: 31,
                               wouldHaveDone: WouldHaveDone(kind: "CLIMB", units: 13, unit: "m"),
                               expiresAt: t0.addingTimeInterval(3 * 86_400 + 600))
        XCTAssertEqual(FightCopy.line(stag, now: t0),
                       "Grey Stag escaped, weakened. Health 31 / 400. 13 m more climbing would have defeated it. It stays three more days.")
    }

    func testDefeatedSaysWhatDidIt() {
        let troll = FightReport(id: UUID(), name: "Fen Troll", outcome: "SEEN_OFF", holdMax: 100, holdBefore: 100, holdAfter: 0, finisher: "WORD")
        XCTAssertEqual(FightCopy.line(troll), "Fen Troll defeated! Finished with a note.")
        let ground = WouldHaveDone(kind: "GROUND", units: 2, unit: "cells")
        XCTAssertEqual(FightCopy.wouldHaveDone(ground), "Two more unexplored tiles would have defeated it.")
        let untouched = FightReport(id: UUID(), name: "Mire Hag", outcome: "UNTOUCHED", holdMax: 100, holdBefore: 100, holdAfter: 100)
        XCTAssertEqual(FightCopy.line(untouched), "You passed Mire Hag without a fight.")
    }

    func testTheQuarryLeads() {
        let quarry = UUID()
        let reports = [
            FightReport(id: UUID(), name: "a", outcome: "UNTOUCHED", holdMax: 100, holdBefore: 100, holdAfter: 100),
            FightReport(id: UUID(), name: "b", outcome: "SEEN_OFF", holdMax: 100, holdBefore: 100, holdAfter: 0),
            FightReport(id: quarry, name: "c", outcome: "LOOSENED", holdMax: 100, holdBefore: 100, holdAfter: 40),
        ]
        XCTAssertEqual(FightCopy.ordered(reports, quarryId: quarry.uuidString.lowercased()).map(\.name), ["c", "b", "a"])
        XCTAssertEqual(FightCopy.ordered(reports, quarryId: nil).map(\.name), ["b", "c", "a"])
    }

    /// docs/VOICE.md: the glossary's "Not" words, and no gore.
    func testNoFightLineUsesAForbiddenWord() {
        let forbidden = ["seen off", "loosened", "hold", "beaten", "slain", "killed", "wounded", "HP", "the word", "height"]
        let lines = [
            FightCopy.line(FightReport(id: UUID(), name: "X", outcome: "SEEN_OFF", holdMax: 1, holdBefore: 1, holdAfter: 0)),
            FightCopy.line(FightReport(id: UUID(), name: "X", outcome: "LOOSENED", holdMax: 9, holdBefore: 9, holdAfter: 3)),
            FightCopy.line(FightReport(id: UUID(), name: "X", outcome: "UNTOUCHED", holdMax: 9, holdBefore: 9, holdAfter: 9)),
        ]
        for line in lines { for word in forbidden { XCTAssertFalse(line.contains(word), line) } }
    }
}
