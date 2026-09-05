import Foundation

public struct AbilityEffect: Codable, Hashable, Sendable {
    public var type: String
    public var perRank: Double?

    public init(type: String, perRank: Double? = nil) {
        self.type = type
        self.perRank = perRank
    }
}

public struct Ability: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var characterClass: CharacterClass
    public var name: String
    public var description: String
    public var requiredClassLevel: Int
    public var maxRank: Int
    public var effects: [AbilityEffect]

    public init(id: String, characterClass: CharacterClass, name: String, description: String, requiredClassLevel: Int, maxRank: Int, effects: [AbilityEffect]) {
        self.id = id
        self.characterClass = characterClass
        self.name = name
        self.description = description
        self.requiredClassLevel = requiredClassLevel
        self.maxRank = maxRank
        self.effects = effects
    }
}

public struct AbilityState: Codable, Hashable, Identifiable, Sendable {
    public var ability: Ability
    public var rank: Int
    public var unlocked: Bool
    public var canUnlock: Bool

    public var id: String { ability.id }

    public init(ability: Ability, rank: Int, unlocked: Bool, canUnlock: Bool) {
        self.ability = ability
        self.rank = rank
        self.unlocked = unlocked
        self.canUnlock = canUnlock
    }
}

/// Alias for callers that also need `Swift.Character` in scope and want an
/// unambiguous spelling for the RPG character.
public typealias RRCharacter = Character

/// The player's RPG character. Note: this shadows `Swift.Character` inside
/// modules that import RoadsAndRunesCore; use `Swift.Character` for the text type.
public struct Character: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var characterClass: CharacterClass
    public var overallLevel: Int
    public var overallXP: Int
    public var nextOverallLevelXP: Int?
    public var overallLevelFloorXP: Int
    public var classLevel: Int
    public var classXP: Int
    public var nextClassLevelXP: Int?
    public var classLevelFloorXP: Int
    public var title: String?
    public var abilities: [AbilityState]
    public var unspentAbilityPoints: Int
    public var createdAt: Date

    public init(
        id: UUID, name: String, characterClass: CharacterClass, overallLevel: Int, overallXP: Int,
        nextOverallLevelXP: Int?, overallLevelFloorXP: Int, classLevel: Int, classXP: Int, nextClassLevelXP: Int?,
        classLevelFloorXP: Int, title: String?, abilities: [AbilityState], unspentAbilityPoints: Int, createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.characterClass = characterClass
        self.overallLevel = overallLevel
        self.overallXP = overallXP
        self.nextOverallLevelXP = nextOverallLevelXP
        self.overallLevelFloorXP = overallLevelFloorXP
        self.classLevel = classLevel
        self.classXP = classXP
        self.nextClassLevelXP = nextClassLevelXP
        self.classLevelFloorXP = classLevelFloorXP
        self.title = title
        self.abilities = abilities
        self.unspentAbilityPoints = unspentAbilityPoints
        self.createdAt = createdAt
    }

    /// Progress (0…1) through the current overall level; 1 at max level.
    public var overallLevelProgress: Double {
        progress(xp: overallXP, floor: overallLevelFloorXP, next: nextOverallLevelXP)
    }

    /// Progress (0…1) through the current class level; 1 at max level.
    public var classLevelProgress: Double {
        progress(xp: classXP, floor: classLevelFloorXP, next: nextClassLevelXP)
    }

    private func progress(xp: Int, floor: Int, next: Int?) -> Double {
        guard let next = next, next > floor else { return 1 }
        let fraction = Double(xp - floor) / Double(next - floor)
        return min(1, max(0, fraction))
    }
}

public struct CharacterCreate: Codable, Hashable, Sendable {
    public var name: String
    public var characterClass: CharacterClass

    public init(name: String, characterClass: CharacterClass = .explorer) {
        self.name = name
        self.characterClass = characterClass
    }
}

public struct ClassInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tagline: String
    public var description: String
    public var enabled: Bool

    public init(id: String, name: String, tagline: String, description: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.description = description
        self.enabled = enabled
    }

    public var characterClass: CharacterClass { CharacterClass.lenient(id) }
}

public struct Bike: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bikeType: BikeType
    public var allowGravel: Bool
    public var allowTrails: Bool
    public var maxTechnicalSurface: Int
    public var isDefault: Bool

    public init(id: UUID, name: String, bikeType: BikeType, allowGravel: Bool, allowTrails: Bool, maxTechnicalSurface: Int, isDefault: Bool) {
        self.id = id
        self.name = name
        self.bikeType = bikeType
        self.allowGravel = allowGravel
        self.allowTrails = allowTrails
        self.maxTechnicalSurface = maxTechnicalSurface
        self.isDefault = isDefault
    }
}

/// `POST /character/bikes` and (with all fields optional) `PATCH /character/bikes/{id}`.
public struct BikeIn: Codable, Hashable, Sendable {
    public var name: String?
    public var bikeType: BikeType?
    public var allowGravel: Bool?
    public var allowTrails: Bool?
    public var maxTechnicalSurface: Int?
    public var isDefault: Bool?

    public init(name: String? = nil, bikeType: BikeType? = nil, allowGravel: Bool? = nil, allowTrails: Bool? = nil, maxTechnicalSurface: Int? = nil, isDefault: Bool? = nil) {
        self.name = name
        self.bikeType = bikeType
        self.allowGravel = allowGravel
        self.allowTrails = allowTrails
        self.maxTechnicalSurface = maxTechnicalSurface
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case name, bikeType, allowGravel, allowTrails, maxTechnicalSurface, isDefault
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(bikeType, forKey: .bikeType)
        try container.encodeIfPresent(allowGravel, forKey: .allowGravel)
        try container.encodeIfPresent(allowTrails, forKey: .allowTrails)
        try container.encodeIfPresent(maxTechnicalSurface, forKey: .maxTechnicalSurface)
        try container.encodeIfPresent(isDefault, forKey: .isDefault)
    }
}

public struct RiderProfile: Codable, Hashable, Sendable {
    public var comfortableDistanceKm: Double
    public var comfortableElevationGain: Double
    public var maxPreferredGradient: Double
    public var trafficTolerance: Double
    public var gravelComfort: Double
    public var technicalTrailComfort: Double
    public var cyclewayPreference: Double

    public init(
        comfortableDistanceKm: Double = 25, comfortableElevationGain: Double = 300, maxPreferredGradient: Double = 8,
        trafficTolerance: Double = 0.3, gravelComfort: Double = 0.5, technicalTrailComfort: Double = 0.2, cyclewayPreference: Double = 0.8
    ) {
        self.comfortableDistanceKm = comfortableDistanceKm
        self.comfortableElevationGain = comfortableElevationGain
        self.maxPreferredGradient = maxPreferredGradient
        self.trafficTolerance = trafficTolerance
        self.gravelComfort = gravelComfort
        self.technicalTrailComfort = technicalTrailComfort
        self.cyclewayPreference = cyclewayPreference
    }
}
