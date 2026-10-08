import Foundation
import XCTest
@testable import RoadsAndRunesCore

final class QuickStartTests: XCTestCase {
    func testEveryKindRoundTripsThroughJSON() throws {
        let starts: [QuickStart] = [
            .loop(minutes: 40, activity: .run), .bounty, .sealed(minutes: 90),
            .quest(id: UUID(uuidString: "2F1B9C2E-6B7A-4C1D-9E0F-0A1B2C3D4E5F")!),
        ]
        for start in starts {
            let data = try JSONEncoder().encode(start)
            XCTAssertEqual(try JSONDecoder().decode(QuickStart.self, from: data), start)
        }
    }

    func testMinutesBecomeADistanceAtTheActivitysPace() {
        XCTAssertEqual(Activity.ride.distanceMeters(forMinutes: 40), 10_000, accuracy: 0.001)
        XCTAssertEqual(Activity.run.distanceMeters(forMinutes: 60), 9_500, accuracy: 0.001)
        XCTAssertEqual(Activity.walk.distanceMeters(forMinutes: 30), 2_400, accuracy: 0.001)
        XCTAssertEqual(Activity.unknown.usualSpeedKmh, Activity.ride.usualSpeedKmh)

        XCTAssertEqual(QuickStart.loop(minutes: 40, activity: .ride).loopDistanceKm, 10)
        XCTAssertEqual(QuickStart.loop(minutes: 20, activity: .run).loopDistanceKm, 3.2)
        // Never a loop under a kilometre.
        XCTAssertEqual(QuickStart.loopDistanceKm(minutes: 5, activity: .walk), 1)
        XCTAssertNil(QuickStart.bounty.loopDistanceKm)
    }

    func testSealedLengthsSnapToWhatTheBoardOffers() {
        XCTAssertEqual(QuickStart.sealedMinutes(nearest: 40), 40)
        XCTAssertEqual(QuickStart.sealedMinutes(nearest: 45), 40)
        XCTAssertEqual(QuickStart.sealedMinutes(nearest: 10), 20)
        XCTAssertEqual(QuickStart.sealedMinutes(nearest: 70), 90)
        XCTAssertEqual(QuickStart.sealedMinutes(nearest: 300), 90)
        XCTAssertEqual(QuickStart.sealed(minutes: 20).minutes, 20)
        XCTAssertNil(QuickStart.bounty.minutes)
    }

    func testDeepLinksParse() {
        func link(_ text: String) -> DeepLink? { DeepLink(url: URL(string: text)!) }
        XCTAssertEqual(link("roadsandrunes://world"), .world)
        XCTAssertEqual(link("roadsandrunes://bounty"), .bounty)
        XCTAssertEqual(link("roadsandrunes://quests"), .quests)
        XCTAssertEqual(link("roadsandrunes://ride"), .ride)
        XCTAssertEqual(link("RoadsAndRunes://World"), .world)
        XCTAssertEqual(link("roadsandrunes://quickstart?minutes=40"), .quickStart(.sealed(minutes: 40)))
        XCTAssertEqual(link("roadsandrunes://quickstart?minutes=35"), .quickStart(.sealed(minutes: 40)))
        XCTAssertEqual(link("roadsandrunes://quickstart"), .quickStart(.sealed(minutes: 40)))
        XCTAssertEqual(link("roadsandrunes://quickstart?kind=loop&minutes=20&activity=RUN"), .quickStart(.loop(minutes: 20, activity: .run)))
        XCTAssertEqual(link("roadsandrunes://quickstart?kind=loop&activity=swim"), .quickStart(.loop(minutes: 40, activity: .ride)))
        XCTAssertEqual(link("roadsandrunes://quickstart?kind=bounty"), .quickStart(.bounty))
        let id = UUID()
        XCTAssertEqual(link("roadsandrunes://quickstart?kind=quest&id=\(id.uuidString)"), .quickStart(.quest(id: id)))
        XCTAssertNil(link("roadsandrunes://quickstart?kind=quest&id=nope"))
        XCTAssertNil(link("roadsandrunes://quickstart?kind=dance"))
        // Strava's OAuth return is not ours to take.
        XCTAssertNil(link("roadsandrunes://strava?code=abc"))
        XCTAssertNil(link("https://world"))
    }

    func testDeepLinksRoundTrip() {
        let links: [DeepLink] = [
            .world, .bounty, .quests, .ride, .quickStart(.sealed(minutes: 90)), .quickStart(.bounty),
            .quickStart(.loop(minutes: 60, activity: .walk)), .quickStart(.quest(id: UUID())),
        ]
        for link in links {
            XCTAssertEqual(DeepLink(url: link.url), link, link.url.absoluteString)
        }
        XCTAssertEqual(DeepLink.quickStart(.sealed(minutes: 40)).url.absoluteString, "roadsandrunes://quickstart?minutes=40")
        XCTAssertEqual(DeepLink.world.url.absoluteString, "roadsandrunes://world")
    }
}
