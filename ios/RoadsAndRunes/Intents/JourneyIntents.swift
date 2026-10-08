import AppIntents
import Foundation
import RoadsAndRunesCore

/// Quick starts for Siri, the Shortcuts app and the Action Button (0.7.3). Each
/// opens the app and hands a `QuickStart` to its `QuickStartCoordinator`, which
/// plans the route and shows it ready with Start: nothing begins without the
/// rider seeing where.

/// Ride, run or walk, as Siri says it.
enum JourneyKind: String, AppEnum {
    case ride, run, walk

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Journey"
    static let caseDisplayRepresentations: [JourneyKind: DisplayRepresentation] = [
        .ride: "ride",
        .run: "run",
        .walk: "walk",
    ]

    var activity: Activity {
        switch self {
        case .ride: return .ride
        case .run: return .run
        case .walk: return .walk
        }
    }
}

/// How long a sealed quest lasts: the three the quest board offers.
enum QuestLength: String, AppEnum {
    case twenty = "20", forty = "40", ninety = "90"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Length"
    static let caseDisplayRepresentations: [QuestLength: DisplayRepresentation] = [
        .twenty: "20 minutes",
        .forty: "40 minutes",
        .ninety: "90 minutes",
    ]

    var minutes: Int { Int(rawValue) ?? 40 }

    init(minutes: Int) {
        self = QuestLength(rawValue: String(QuickStart.sealedMinutes(nearest: minutes))) ?? .forty
    }
}

/// "Start a ride": a loop from here that lasts about as long as asked.
struct StartJourneyIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a journey"
    static let description: IntentDescription? = IntentDescription("Plans a loop from where you are and shows it with Start ready.")
    static let openAppWhenRun = true

    @Parameter(title: "Journey")
    var kind: JourneyKind?

    @Parameter(title: "Minutes", default: 40, inclusiveRange: (10, 240))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$kind) for \(\.$minutes) minutes")
    }

    /// With no activity said, the coordinator uses the player's usual one.
    var quickStart: QuickStart {
        .loop(minutes: minutes, activity: kind?.activity ?? .unknown)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickStartCoordinator.shared.handle(quickStart, autoStart: false)
        return .result()
    }
}

/// "Go out for the bounty": a route to today's bounty.
struct BountyJourneyIntent: AppIntent {
    static let title: LocalizedStringResource = "Go out for the bounty"
    static let description: IntentDescription? = IntentDescription("Plans a route to today's bounty and shows it with Start ready.")
    static let openAppWhenRun = true

    var quickStart: QuickStart { .bounty }

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickStartCoordinator.shared.handle(quickStart, autoStart: false)
        return .result()
    }
}

/// "Give me something for 40 minutes": a sealed quest. The board picks the way
/// and the goal opens halfway.
struct QuickQuestIntent: AppIntent {
    static let title: LocalizedStringResource = "Sealed quest"
    static let description: IntentDescription? = IntentDescription("The board picks the way. Your goal opens halfway.")
    static let openAppWhenRun = true

    @Parameter(title: "Length", default: .forty)
    var length: QuestLength

    static var parameterSummary: some ParameterSummary {
        Summary("Sealed quest for \(\.$length)")
    }

    var quickStart: QuickStart { .sealed(minutes: length.minutes) }

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickStartCoordinator.shared.handle(quickStart, autoStart: false)
        return .result()
    }
}

/// What Siri listens for, and what the Shortcuts app and the Action Button list.
struct RoadsAndRunesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartJourneyIntent(),
            phrases: [
                "Start a \(\.$kind) with \(.applicationName)",
                "Start a \(\.$kind) in \(.applicationName)",
                "Start a journey with \(.applicationName)",
            ],
            shortTitle: "Start a journey",
            systemImageName: "bicycle"
        )
        AppShortcut(
            intent: BountyJourneyIntent(),
            phrases: [
                "Go out for the bounty with \(.applicationName)",
                "Go out for the \(.applicationName) bounty",
            ],
            shortTitle: "Find the bounty",
            systemImageName: "map"
        )
        AppShortcut(
            intent: QuickQuestIntent(),
            phrases: [
                "Give me something for \(\.$length) with \(.applicationName)",
                "Give me something for \(\.$length) in \(.applicationName)",
                "Give me a sealed quest in \(.applicationName)",
            ],
            shortTitle: "Sealed quest",
            systemImageName: "hourglass"
        )
    }
}
