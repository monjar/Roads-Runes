import AuthenticationServices
import Foundation
import Observation
import RoadsAndRunesCore

/// Authentication + current user/character state.
@MainActor
@Observable
final class SessionStore {
    enum State: Equatable {
        case loading
        case signedOut
        case needsCharacter
        case ready
    }

    private(set) var state: State = .loading
    private(set) var user: User?
    private(set) var character: Character?
    /// The riding profile, kept for its default activity: the World and the planner
    /// need to know how this player moves before they have asked for anything.
    private(set) var riderProfile: RiderProfile?
    private(set) var config: AppConfig?
    var lastError: String?
    /// From creating a character until the rider has set up a bike and answered
    /// the location prompt (spec §96 steps 4–5); the tabs wait until then.
    private(set) var isOnboarding = false

    private let api: any RoadsAndRunesAPI

    init(api: any RoadsAndRunesAPI) {
        self.api = api
    }

    var settings: UserSettings { user?.settings ?? UserSettings() }
    var units: Units { settings.units == .unknown ? .metric : settings.units }
    var featureFlags: [String: Bool] { config?.featureFlags ?? [:] }

    func isEnabled(_ flag: String) -> Bool { featureFlags[flag] ?? false }

    /// How this player usually moves; a ride until they say otherwise.
    var defaultActivity: Activity {
        let activity = riderProfile?.defaultActivity ?? .ride
        return activity == .unknown ? .ride : activity
    }

    func setDefaultActivity(_ activity: Activity) async {
        var profile = (try? await api.riderProfile()) ?? riderProfile ?? RiderProfile()
        profile.defaultActivity = activity
        do {
            riderProfile = try await api.updateRiderProfile(profile)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func update(riderProfile: RiderProfile) {
        self.riderProfile = riderProfile
    }

    func bootstrap() async {
        do {
            let me = try await api.me()
            user = me
            config = try? await api.config()
            await refreshCharacter()
        } catch let error as APIError {
            if case .unauthenticated = error {
                state = .signedOut
            } else {
                lastError = error.localizedDescription
                state = user == nil ? .signedOut : state
            }
        } catch {
            state = .signedOut
        }
    }

    func refreshCharacter() async {
        do {
            character = try await api.character()
            riderProfile = try? await api.riderProfile()
            state = .ready
        } catch let error as APIError {
            if case .server(let code, _, _) = error, code == "NO_CHARACTER" || code == "NOT_FOUND" {
                character = nil
                state = .needsCharacter
            } else if case .unauthenticated = error {
                state = .signedOut
            } else {
                lastError = error.localizedDescription
                state = character == nil ? .needsCharacter : .ready
            }
        } catch {
            state = character == nil ? .needsCharacter : .ready
        }
    }

    func signInWithApple(result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let error):
            lastError = Self.appleSignInMessage(for: error)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                lastError = "Apple did not return an identity token"
                return
            }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            let name = AppleFullName(givenName: credential.fullName?.givenName, familyName: credential.fullName?.familyName)
            await complete(sign: { try await self.api.signInWithApple(AppleSignInRequest(identityToken: token, authorizationCode: code, fullName: name)) })
        }
    }

    /// ASAuthorizationError reads as "The operation couldn't be completed. (…error 1000.)";
    /// say what actually happened instead.
    private static func appleSignInMessage(for error: Error) -> String? {
        guard let authError = error as? ASAuthorizationError else { return error.localizedDescription }
        switch authError.code {
        case .canceled: return nil
        case .notHandled, .unknown, .failed:
            return "Sign in with Apple is unavailable in this build. Use Developer sign in, or install a build signed by a paid Apple developer account."
        default: return error.localizedDescription
        }
    }

    func devSignIn(subject: String, displayName: String) async {
        await complete(sign: { try await self.api.devSignIn(DevSignInRequest(subject: subject, displayName: displayName)) })
    }

    private func complete(sign: () async throws -> TokenResponse) async {
        do {
            let response = try await sign()
            user = response.user
            config = try? await api.config()
            await refreshCharacter()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createCharacter(name: String, characterClass: CharacterClass) async -> Bool {
        do {
            character = try await api.createCharacter(CharacterCreate(name: name, characterClass: characterClass))
            user = try? await api.me()
            isOnboarding = true
            state = .ready
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func finishOnboarding() {
        isOnboarding = false
    }

    func update(settings: UserSettings) async {
        do {
            user = try await api.updateMe(UserUpdate(settings: settings))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateCharacter(_ character: Character) {
        self.character = character
    }

    /// Switches class, keeping level, XP, coins and discoveries. Returns the server's
    /// reason when it refuses (a cooldown, an empty purse), nil on success.
    func changeClass(to characterClass: CharacterClass) async -> String? {
        do {
            character = try await api.changeClass(CharacterClassChange(characterClass: characterClass))
            return nil
        } catch let error as APIError {
            if case .server(_, let message, _) = error { return message }
            return error.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    /// Starts the character over. The rides stay; the character, quests, XP and
    /// coins go, and onboarding asks for a class again.
    func resetCharacter() async -> Bool {
        do {
            try await api.resetCharacter()
            character = nil
            user = try? await api.me()
            isOnboarding = false
            state = .needsCharacter
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func signOut() async {
        try? await api.logout()
        user = nil
        character = nil
        isOnboarding = false
        state = .signedOut
    }
}
