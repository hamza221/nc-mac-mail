// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet

/// Every line the account form can show under itself (checklist §1.4–§1.5), and the one
/// mapping from a command's failure to it — `AccountForm.vue`'s `catch` block, case for case.
enum AccountSetupFeedback: Equatable {
    enum Service: String, Equatable {
        case imap = "IMAP"
        case smtp = "SMTP"
    }

    case wrongPassword(Service)
    case unreachable(Service)
    case denied(Service)
    case authenticationError(Service)
    case connectionFailed(Service)
    case discoveryFailed
    case discoveryRateLimited
    case consentAborted
    case passwordRequired
    case generic
    case linkProvider(AccountSetupForm.Provider)

    var text: String {
        switch self {
        case .wrongPassword(.imap): String(localized: "IMAP username or password is wrong")
        case .wrongPassword(.smtp): String(localized: "SMTP username or password is wrong")
        case .unreachable(.imap): String(localized: "IMAP server is not reachable")
        case .unreachable(.smtp): String(localized: "SMTP server is not reachable")
        case .denied(.imap): String(localized: "IMAP server denied authentication")
        case .denied(.smtp): String(localized: "SMTP server denied authentication")
        case .authenticationError(.imap): String(localized: "IMAP authentication error")
        case .authenticationError(.smtp): String(localized: "SMTP authentication error")
        case .connectionFailed(.imap): String(localized: "IMAP connection failed")
        case .connectionFailed(.smtp): String(localized: "SMTP connection failed")
        case .discoveryFailed: String(localized: "Configuration discovery failed. Please use the manual settings")
        case .discoveryRateLimited:
            String(localized: "Configuration discovery temporarily not available. Please try again later.")
        case .consentAborted: String(localized: "Authorization pop-up closed")
        case .passwordRequired: String(localized: "Password required")
        case .generic: String(localized: "There was an error while setting up your account")
        case .linkProvider(.google):
            String(localized: "Account created. Please follow the pop-up instructions to link your Google account")
        case .linkProvider(.microsoft):
            String(localized: "Account created. Please follow the pop-up instructions to link your Microsoft account")
        }
    }

    /// Whether the line reports a failure (red) rather than an instruction.
    var isError: Bool {
        if case .linkProvider = self { return false }
        return true
    }

    /// A command's failure as the web client words it. `CouldNotConnectException` reasons the
    /// web client has no case for (`OTHER`, or an unknown service) fall through exactly as
    /// there: "<service> connection failed", else the generic line.
    init(_ error: MailError) {
        switch error {
        case .connectFailed(let service, let reason):
            guard let service = Service(rawValue: service) else {
                self = .generic
                return
            }
            switch reason {
            case "CONNECTION_ERROR": self = .unreachable(service)
            case "AUTHENTICATION_WRONG_PASSWORD": self = .wrongPassword(service)
            case "AUTHENTICATION_DENIED": self = .denied(service)
            case "AUTHENTICATION": self = .authenticationError(service)
            default: self = .connectionFailed(service)
            }
        case .rateLimited:
            self = .discoveryRateLimited
        default:
            self = .generic
        }
    }
}
