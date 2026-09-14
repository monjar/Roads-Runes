import Foundation

/// Client analytics events (PRODUCT_SPEC §78–79). Names are the wire values.
public enum AnalyticsEvent: String, CaseIterable, Hashable, Sendable {
    // Navigation
    case navigationStarted = "navigation_started"
    case navigationEnded = "navigation_ended"
    case navigationCrashed = "navigation_crashed"
    case routeReroute = "route_reroute"
    case watchDisconnected = "watch_disconnected"
    case gpsAccuracyPoor = "gps_accuracy_poor"
    // Quests
    case questViewed = "quest_viewed"
    case questAccepted = "quest_accepted"
    case questStarted = "quest_started"
    case questCompleted = "quest_completed"
    case questAbandoned = "quest_abandoned"
    // Routes & rides
    case routeGenerated = "route_generated"
    case routeSelected = "route_selected"
    case rideStarted = "ride_started"
    case rideCompleted = "ride_completed"
    // Exploration & progression
    case newAreaExplored = "new_area_explored"
    case discoveryFound = "discovery_found"
    // The world
    case worldObjectClaimed = "world_object_claimed"
    case levelUp = "level_up"
    case abilityUnlocked = "ability_unlocked"
    // Social
    case friendAdded = "friend_added"
    case partyCreated = "party_created"
    case partyQuestCompleted = "party_quest_completed"
}

/// Destination for analytics events. Implementations must never receive
/// precise location; callers pass only coarse, non-identifying properties.
public protocol AnalyticsSink: Sendable {
    func track(_ event: AnalyticsEvent, properties: [String: String])
}

extension AnalyticsSink {
    public func track(_ event: AnalyticsEvent) {
        track(event, properties: [:])
    }
}

public struct NoopAnalytics: AnalyticsSink {
    public init() {}
    public func track(_ event: AnalyticsEvent, properties: [String: String]) {}
}
