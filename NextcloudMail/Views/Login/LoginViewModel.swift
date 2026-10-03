// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailNet
import OSLog
import SwiftUI

/// Drives `LoginView` through Login Flow v2.
///
/// `NextcloudMail` compiles with `defaultIsolation(MainActor.self)`
/// ([concurrency.md](../../../docs/architecture/concurrency.md)), so this class is
/// main-actor without saying so, which is what lets it assign `phase` directly
/// from the `Task` below and have SwiftUI see it.
@Observable
final class LoginViewModel {
    /// What the sign-in screen is showing right now.
    enum Phase: Equatable {
        case enteringServer
        case waitingForBrowser
        case failed(Failure)
    }

    /// A user-facing failure, collapsing `ServerURLError`, `LoginError` and
    /// `KeychainError` into the cases
    /// [S-01](../../../docs/product/user-stories.md#s-01-sign-in-ws-01) asks the
    /// screen to tell apart. `.cancelled` is deliberately absent: cancelling
    /// returns to `.enteringServer`, not to a failure.
    enum Failure: Equatable {
        case invalidAddress
        case unreachable
        case notNextcloud
        case mailAppMissing
        case timedOut
        case serverError(status: Int)
        case couldNotSaveCredentials
    }

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "login")

    var serverText = ""
    private(set) var phase: Phase = .enteringServer

    /// Called with the stored credentials once sign-in and the Keychain
    /// write both succeed. `NextcloudMail/Views/Login` is WS-01's; wiring
    /// this into the app shell that replaces `RootSplitView` is WS-13's.
    var onSignedIn: (Credentials) -> Void = { _ in }

    private var flow: LoginFlow?
    private var completionTask: Task<Void, Never>?

    /// The server field's Continue button, and `onSubmit`.
    func continueTapped() {
        let address: URL
        do {
            address = try ServerURL.normalize(serverText)
        } catch {
            phase = .failed(.invalidAddress)
            return
        }

        completionTask?.cancel()
        let flow = LoginFlow()
        self.flow = flow
        phase = .waitingForBrowser

        completionTask = Task { [weak self] in
            await self?.run(flow: flow, server: address)
        }
    }

    /// The waiting screen's Cancel button. `LoginFlow.cancel()` never wrote
    /// anything the way `save` would have, so there is nothing to undo here
    /// beyond returning to the form.
    func cancelTapped() {
        completionTask?.cancel()
        let flow = flow
        Task { await flow?.cancel() }
        phase = .enteringServer
    }

    private func run(flow: LoginFlow, server: URL) async {
        do {
            let loginURL = try await flow.start(server: server)
            NSWorkspace.shared.open(loginURL)
            let credentials = try await flow.awaitCompletion()
            do {
                try Keychain.save(credentials)
            } catch {
                Self.logger.error("keychain save failed: \(String(describing: error), privacy: .public)")
                phase = .failed(.couldNotSaveCredentials)
                return
            }
            phase = .enteringServer
            serverText = ""
            onSignedIn(credentials)
        } catch let error as LoginError {
            if error == .cancelled {
                phase = .enteringServer
            } else {
                phase = .failed(Failure(error))
            }
        } catch is CancellationError {
            // `completionTask` was replaced or the view went away; the flow
            // itself is still `LoginFlow`'s to clean up on its next call.
        } catch {
            Self.logger.error("unexpected login failure: \(String(describing: error), privacy: .public)")
            phase = .failed(.unreachable)
        }
    }
}

extension LoginViewModel.Failure {
    fileprivate init(_ error: LoginError) {
        switch error {
        case .unreachable: self = .unreachable
        case .notNextcloud: self = .notNextcloud
        case .mailAppMissing: self = .mailAppMissing
        case .timedOut: self = .timedOut
        case .server(let status): self = .serverError(status: status)
        case .cancelled:
            // Not reached in practice: `run(flow:server:)` checks `error == .cancelled` itself
            // and returns to `.enteringServer` before ever calling this initializer.
            self = .unreachable
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .invalidAddress: "Enter a valid server address"
        case .unreachable: "Could not reach this server"
        case .notNextcloud: "This does not look like a Nextcloud server"
        case .mailAppMissing: "The Mail app is not installed"
        case .timedOut: "Nothing happened in the browser"
        case .serverError: "The server reported an error"
        case .couldNotSaveCredentials: "Could not save your credentials"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .invalidAddress:
            "Type your server's web address, such as cloud.example.com."
        case .unreachable:
            "Check the address and your network connection, then try again."
        case .notNextcloud:
            "Double-check the address, or ask your administrator whether this server runs Nextcloud."
        case .mailAppMissing:
            "Ask your administrator to enable the Mail app for this account."
        case .timedOut:
            "The sign-in page was open for five minutes with no response. Try again."
        case .serverError(let status):
            "Status \(status). Try again in a moment."
        case .couldNotSaveCredentials:
            "Signing in worked, but the app password could not be stored in the Keychain. Try again."
        }
    }
}
