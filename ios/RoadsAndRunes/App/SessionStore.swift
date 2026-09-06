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
    private(set) var config: AppConfig?
    var lastError: String?

    private let api: any RoadsAndRunesAPI

    init(api: any RoadsAndRunesAPI) {
        self.api = api
    }

    var settings: UserSettings { user?.settings ?? UserSettings() }
    var units: Units { settings.units == .unknown ? .metric : settings.units }
    var featureFlags: [String: Bool] { config?.featureFlags ?? [:] }

    func isEnabled(_ flag: String) -> Bool { featureFlags[flag] ?? false }

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
            lastError = error.localizedDescription
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
            state = .ready
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
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

    func signOut() async {
        try? await api.logout()
        user = nil
        character = nil
        state = .signedOut
    }
}
