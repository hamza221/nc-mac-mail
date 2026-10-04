// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailStore
import NCMailSync
import OSLog
import Observation

/// One login's Teams, live from the mirror: the `teams` row decides whether anything shows
/// (``TeamsGate``), `team` / `teamMember` hold what does. Shared by the sidebar rows and the
/// team view through ``TeamsModels``, so the gate is asked once per login.
///
/// The one network-adjacent call is `ServerResultFetcher.request` (registers interest,
/// answers nothing) and `run(_:)` for an edit, whose awaited value is an outcome; the data
/// always comes back through the table (ADR-0067, ADR-0097).
@MainActor
@Observable
final class TeamsModel {
    let sessionId: String
    private(set) var isAvailable = false
    private(set) var teams: [TeamSummary] = []
    private(set) var loginId: Int64?

    let store: MailStore
    private let fetcher: @MainActor () -> ServerResultFetcher?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(sessionId: String, store: MailStore, fetcher: @escaping @MainActor () -> ServerResultFetcher?) {
        self.sessionId = sessionId
        self.store = store
        self.fetcher = fetcher
    }

    func team(_ remoteId: String) -> TeamSummary? { teams.first { $0.remoteId == remoteId } }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self, store, sessionId] in
            guard let login = await PeopleLogin.resolve(store: store, sessionId: sessionId) else { return }
            self?.loginId = login.loginId
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.requestWhenEngineRuns() }
                group.addTask { await self?.observe(loginId: login.loginId) }
            }
        }
    }

    /// Asks for a fresh list (subject to the five-minute expiry unless forced).
    func refresh(force: Bool = false) {
        guard let fetcher = fetcher() else { return }
        Task { await fetcher.request(kind: .teams, key: ServerResultKind.teamsKey, force: force) }
    }

    /// Asks the server which users and groups match `term`; the answer is the `sharees`
    /// row the add-member sheet observes.
    func requestSharees(_ term: String) {
        guard let fetcher = fetcher() else { return }
        Task { await fetcher.request(kind: .sharees, key: term) }
    }

    /// Runs one edit; nil when it worked, else the sentence to show.
    func perform(_ command: TeamCommand) async -> String? {
        guard let fetcher = fetcher() else {
            return String(localized: "Teams cannot be changed while this account is signed out.")
        }
        let outcome = await fetcher.run(command)
        guard case .failure(let error) = outcome else { return nil }
        Self.logger.info("team edit refused: \(error.description, privacy: .public)")
        if let message = outcome.serverMessage, !message.isEmpty { return message }
        if case .transport = error {
            return String(localized: "The server could not be reached. Try again when online.")
        }
        return String(localized: "The server refused the change.")
    }

    /// The login's engine can start after the sidebar is drawn; the cached rows show
    /// meanwhile, and the refresh goes out once the fetcher exists.
    private func requestWhenEngineRuns() async {
        for _ in 0..<60 {
            if let fetcher = fetcher() {
                await fetcher.request(kind: .teams, key: ServerResultKind.teamsKey)
                return
            }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
    }

    private func observe(loginId: Int64) async {
        do {
            // The row is written after `team` and `teamMember`, so each emission is a
            // consistent moment to read both.
            for try await row in store.observeServerResult(
                kind: ServerResultKind.teams.rawValue, key: ServerResultKind.teamsKey, loginId: loginId)
            {
                let available = TeamsGate.isAvailable(row)
                teams = available ? await load(loginId: loginId) : []
                isAvailable = available
            }
        } catch {
            Self.logger.error("teams observation ended: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func load(loginId: Int64) async -> [TeamSummary] {
        do {
            var summaries: [TeamSummary] = []
            for record in try await store.teams(loginId: loginId) {
                guard let id = record.id else { continue }
                summaries.append(TeamSummary(record: record, members: try await store.teamMembers(teamId: id)))
            }
            return summaries
        } catch {
            Self.logger.error("teams read failed: \(String(describing: type(of: error)), privacy: .public)")
            return teams
        }
    }

    nonisolated static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "teams")
}

/// The ``TeamsModel`` of each login, created and started on first use from a view body —
/// the same lifetime as `ContactsBrowser`'s login models. A registry rather than a view's
/// `@State` because the sidebar rows must decide to draw nothing at all, and a view that
/// draws nothing never runs its `.task`.
@MainActor
enum TeamsModels {
    private static var models: [String: TeamsModel] = [:]

    static func model(_ sessionId: String, session: AppSession) -> TeamsModel {
        if let model = models[sessionId] { return model }
        let model = TeamsModel(sessionId: sessionId, store: session.store) { [weak session] in
            session?.engine.serverResults(sessionId: sessionId)
        }
        models[sessionId] = model
        model.start()
        return model
    }
}
