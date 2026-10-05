import Foundation

// Between rides (0.7.3): the server's rules for pledges, letters and the sealed
// quest, small enough to hold in memory.
extension MockAPI {
    /// What the server says when the thing pledged for is gone.
    static let pledgeGoneMessage = "That creature or quest isn't on your map any more. Pick another."

    func validation(_ message: String) -> APIError {
        .server(code: APIErrorCode.validationError, message: message, status: 422)
    }

    // MARK: Pledge

    public func pledges(today: String) async throws -> PledgeState {
        try await run {
            // A day gone by without its pledge kept turns MISSED, quietly, and is never sent again.
            for (day, pledge) in self.storedPledges where day < today && pledge.status == .pledged {
                self.storedPledges[day]?.status = .missed
            }
            let tomorrow = Self.dayAfter(today)
            return PledgeState(
                today: self.storedPledges[today].flatMap { $0.status == .missed ? nil : $0 },
                tomorrow: tomorrow.flatMap { self.storedPledges[$0] }
            )
        }
    }

    public func pledge(_ request: PledgeRequest) async throws -> Pledge {
        try await run {
            guard Self.dayAfter(request.day) != nil else { throw self.validation("Pick today or tomorrow.") }
            let target: (name: String, icon: String?)
            switch request.targetKind {
            case .creature:
                guard let object = self.storedObjects[request.targetId], object.kind == .monster, object.status == .spawned else {
                    throw APIError.server(code: APIErrorCode.notFound, message: Self.pledgeGoneMessage, status: 404)
                }
                // The server names the creature's face; here every creature is the troll.
                target = (object.name, "troll")
            case .quest:
                guard let quest = self.storedQuests[request.targetId], quest.status == .available || quest.status == .accepted else {
                    throw APIError.server(code: APIErrorCode.notFound, message: Self.pledgeGoneMessage, status: 404)
                }
                target = (quest.title, "scroll")
            case .unknown:
                throw self.validation("Pledge a creature or a quest.")
            }
            if let remindAt = request.remindAt, PledgeWindow.reminderDate(day: "2000-01-01", remindAt: remindAt, now: .distantPast) == nil {
                throw self.validation("Pick a time for the reminder.")
            }
            let pledge = Pledge(day: request.day, targetKind: request.targetKind, targetId: request.targetId, targetName: target.name,
                                icon: target.icon, remindAt: request.remindAt, status: .pledged)
            self.storedPledges[request.day] = pledge
            return pledge
        }
    }

    public func cancelPledge(day: String) async throws {
        try await run {
            guard self.storedPledges.removeValue(forKey: day) != nil else { throw self.notFound("Pledge") }
        }
    }

    /// Keeps today's pledge when a journey defeated or finished what it was for, as
    /// `process_ride` does; what a summary then says. Nothing for any other journey.
    public func keepPledge(day: String, defeated targetId: UUID) -> PledgeKept? {
        lock.lock()
        defer { lock.unlock() }
        guard var pledge = storedPledges[day], pledge.status == .pledged, pledge.targetId == targetId else { return nil }
        pledge.status = .kept
        storedPledges[day] = pledge
        return PledgeKept(kept: true, targetName: pledge.targetName, icon: pledge.icon, line: PledgeKept.keptLine)
    }

    /// "2026-10-05" → "2026-10-06", on the Gregorian calendar in UTC (the day is a label, not a moment).
    static func dayAfter(_ day: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              PledgeWindow.dayString(date, calendar: calendar) == day,
              let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return PledgeWindow.dayString(next, calendar: calendar)
    }

    // MARK: Letters

    public func letters() async throws -> [Letter] {
        try await run { self.storedLetters.sorted { $0.writtenAt > $1.writtenAt } }
    }

    public func writeLetter(_ request: LetterCreate) async throws -> Letter {
        try await run {
            guard let text = LetterRules.cleaned(request.text) else {
                throw self.validation("A letter is 1 to \(LetterRules.maxLength) characters. Write a little less, or a little more.")
            }
            let here = Coordinate(latitude: request.latitude, longitude: request.longitude)
            let place = self.storedDiscoveries.values
                .map { (name: $0.name, meters: GeoMath.distance(here, Coordinate(latitude: $0.latitude, longitude: $0.longitude))) }
                .filter { $0.meters <= 80 }
                .min { $0.meters < $1.meters }
            let letter = Letter(id: UUID(), text: text, latitude: request.latitude, longitude: request.longitude,
                                placeName: place?.name, writtenAt: Date())
            self.storedLetters.append(letter)
            return letter
        }
    }

    public func deleteLetter(id: UUID) async throws {
        try await run {
            guard let index = self.storedLetters.firstIndex(where: { $0.id == id }) else { throw self.notFound("Letter") }
            self.storedLetters.remove(at: index)
        }
    }

    /// Puts a letter on the shelf as if written then, for a test to find.
    public func store(letter: Letter) {
        lock.lock()
        defer { lock.unlock() }
        storedLetters.append(letter)
    }

    /// Letters old enough, not yet found, within 60 m of the trace: found now, as
    /// `process_ride` finds them. What a summary says.
    public func findLetters(along trace: [Coordinate], at now: Date = Date()) -> [FoundLetter] {
        lock.lock()
        defer { lock.unlock() }
        let oldest = now.addingTimeInterval(-Double(letterMinAgeDays) * 86_400)
        var found: [FoundLetter] = []
        for index in storedLetters.indices where storedLetters[index].shownAt == nil && storedLetters[index].writtenAt <= oldest {
            let letter = storedLetters[index]
            let near = trace.contains { GeoMath.distance($0, letter.coordinate) <= 60 }
            guard near else { continue }
            storedLetters[index].shownAt = now
            found.append(FoundLetter(text: letter.text, writtenAt: letter.writtenAt, placeName: letter.placeName,
                                     line: LetterRules.foundLine(writtenAt: letter.writtenAt, now: now)))
        }
        return found
    }

    // MARK: Sealed quest

    public func sealedQuest(_ request: SealedQuestRequest) async throws -> Quest {
        try await run {
            guard SealedQuest.minuteChoices.contains(request.minutes) else {
                throw self.validation("Pick 20, 40 or 90 minutes.")
            }
            // One at a time: a sealed quest not yet started gives way to the new one.
            for (id, quest) in self.storedQuests where SealedQuest.isSealed(quest) && (quest.status == .accepted || quest.status == .available) {
                self.storedQuests[id]?.status = .abandoned
            }
            let origin = Coordinate(latitude: request.latitude, longitude: request.longitude)
            var quest = SampleData.sealedQuest(minutes: request.minutes, origin: origin, activity: request.activity ?? .ride, id: UUID())
            var route = SampleData.sampleRoute
            route.id = UUID()
            route.label = "Sealed"
            if let start = route.path.first {
                route = Self.moved(route, byLatitude: origin.latitude - start.latitude, longitude: origin.longitude - start.longitude)
            }
            self.storedRoutes[route.id] = route
            quest.suggestedRouteId = route.id
            self.storedQuests[quest.id] = quest
            return quest
        }
    }
}
