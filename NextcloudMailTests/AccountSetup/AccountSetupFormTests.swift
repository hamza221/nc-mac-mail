// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import Testing

@testable import NextcloudMail

@Suite("Account setup form")
struct AccountSetupFormTests {
    @Test func defaultsAreIMAP993SSLAndSMTP587STARTTLS() {
        let form = AccountSetupForm()
        #expect(form.mode == .auto)
        #expect(form.imapPort == 993 && form.imapSecurity == .ssl)
        #expect(form.smtpPort == 587 && form.smtpSecurity == .tls)
    }

    @Test(
        "security sets the port",
        arguments: [
            (AccountSetupForm.Security.none, 143, 587),
            (.tls, 143, 587),
            (.ssl, 993, 465),
        ])
    func securityCouplesThePort(security: AccountSetupForm.Security, imap: Int, smtp: Int) {
        var form = AccountSetupForm()
        form.setIMAPSecurity(security)
        form.setSMTPSecurity(security)
        #expect(form.imapPort == imap)
        #expect(form.smtpPort == smtp)
    }

    @Test func smtpMirrorsIMAPUntilAnSMTPFieldIsEdited() {
        var form = AccountSetupForm()
        form.setIMAPHost("mail.example.com")
        form.setIMAPUser("alice")
        form.setIMAPPassword("secret")
        #expect(form.smtpHost == "mail.example.com")
        #expect(form.smtpUser == "alice")
        #expect(form.smtpPassword == "secret")

        form.setSMTPHost("smtp.example.com")
        form.setIMAPHost("imap.example.com")
        form.setIMAPUser("bob")
        form.setIMAPPassword("other")
        #expect(form.smtpHost == "smtp.example.com")
        #expect(form.smtpUser == "alice")
        #expect(form.smtpPassword == "secret")
    }

    @Test func anyEditedSMTPFieldSeversTheCoupling() {
        for edit: (inout AccountSetupForm) -> Void in [
            { $0.setSMTPUser("x") }, { $0.setSMTPPassword("x") }, { $0.setSMTPPort(25) }, { $0.setSMTPSecurity(.ssl) },
        ] {
            var form = AccountSetupForm()
            edit(&form)
            form.setIMAPHost("imap.example.com")
            #expect(form.smtpHost.isEmpty)
        }
    }

    @Test func imapSecurityDoesNotTouchSMTP() {
        var form = AccountSetupForm()
        form.setIMAPSecurity(.tls)
        #expect(form.smtpPort == 587 && form.smtpSecurity == .tls)
    }

    @Test func enteringManualFillsUsersAndPasswordsFromAuto() {
        var form = AccountSetupForm()
        form.emailAddress = "alice@example.com"
        form.password = "secret"
        form.setMode(.manual)
        #expect(form.imapUser == "alice@example.com" && form.smtpUser == "alice@example.com")
        #expect(form.imapPassword == "secret" && form.smtpPassword == "secret")

        var edited = AccountSetupForm()
        edited.emailAddress = "alice@example.com"
        edited.imapUser = "kept"
        edited.setMode(.manual)
        #expect(edited.imapUser == "kept")
    }

    @Test(
        "the web client's email check",
        arguments: [
            ("name@example.com", true), ("a.b+c@sub.example.org", true), ("user@localhost", true),
            ("user@[127.0.0.1]", true), ("\"quoted name\"@example.com", true),
            ("name@example", false), ("name", false), ("@example.com", false), ("a b@example.com", false),
        ])
    func emailValidation(address: String, valid: Bool) {
        #expect(AccountSetupForm.isValidEmail(address) == valid)
    }

    @Test func theFormatHintShowsOnlyForATypedInvalidAddress() {
        var form = AccountSetupForm()
        #expect(!form.showsEmailFormatHint)
        form.emailAddress = "name@"
        #expect(form.showsEmailFormatHint)
        form.emailAddress = "name@example.com"
        #expect(!form.showsEmailFormatHint)
    }

    @Test func autoNeedsAValidAddressAndAPasswordUnlessBothProvidersAreConfigured() {
        var form = AccountSetupForm()
        form.emailAddress = "name@example.com"
        #expect(!form.canSubmitAuto)
        form.password = "secret"
        #expect(form.canSubmitAuto)
        form.password = ""
        form.googleOAuthURL = "https://accounts.google.com/?state=_state_"
        #expect(!form.canSubmitAuto)
        form.microsoftOAuthURL = "https://login.microsoftonline.com/?state=_state_"
        #expect(form.canSubmitAuto)
        form.emailAddress = "invalid"
        #expect(!form.canSubmitAuto)
    }

    @Test func manualNeedsEveryField() {
        var form = AccountSetupForm()
        form.mode = .manual
        form.emailAddress = "name@example.com"
        form.setIMAPHost("mail.example.com")
        form.setIMAPUser("name")
        #expect(!form.canSubmitManual)
        form.setIMAPPassword("secret")
        #expect(form.canSubmitManual)
        form.smtpPort = 0
        #expect(!form.canSubmitManual)
    }

    @Test func providersAreDetectedAndOAuthHidesThePasswords() {
        var form = AccountSetupForm()
        form.mode = .manual
        form.setIMAPHost("imap.gmail.com")
        #expect(form.provider == .google)
        #expect(!form.usesOAuth)
        #expect(form.submitLabel == "Connect")
        form.googleOAuthURL = "https://accounts.google.com/o?state=_state_&login_hint=_email_"
        #expect(form.usesOAuth)
        #expect(form.submitLabel == "Sign in with Google")

        form.setIMAPHost("outlook.office365.com")
        #expect(form.provider == .microsoft)
        #expect(!form.usesOAuth)
        form.microsoftOAuthURL = "https://login.microsoftonline.com/?state=_state_"
        #expect(form.submitLabel == "Sign in with Microsoft")
        form.mode = .auto
        #expect(form.submitLabel == "Connect")
    }

    @Test func theRequestTrimsHostsAndDropsPasswordsForOAuth() {
        var form = AccountSetupForm()
        form.emailAddress = "name@gmail.com"
        form.setIMAPHost(" imap.gmail.com ")
        form.setIMAPPassword("secret")
        #expect(form.request.imapHost == "imap.gmail.com")
        #expect(form.request.smtpHost == "imap.gmail.com")
        #expect(form.request.authMethod == "password")
        #expect(form.request.imapPassword == "secret")

        form.setIMAPHost("imap.gmail.com")
        form.googleOAuthURL = "https://accounts.google.com/o?state=_state_"
        #expect(form.request.authMethod == "xoauth2")
        #expect(form.request.imapPassword == nil && form.request.smtpPassword == nil)
    }

    @Test func theOAuthURLCarriesTheStateAndTheEncodedAddress() {
        var form = AccountSetupForm()
        form.setIMAPHost("imap.gmail.com")
        form.googleOAuthURL = "https://accounts.google.com/o?state=_state_&login_hint=_email_"
        let url = form.oauthURL(state: "abc", email: "a+b@gmail.com")
        #expect(url?.absoluteString == "https://accounts.google.com/o?state=abc&login_hint=a%2Bb%40gmail.com")
    }

    @Test func discoveryFillsTheManualFieldsWithAutosPassword() {
        var form = AccountSetupForm()
        form.emailAddress = "name@example.com"
        form.password = "secret"
        form.apply(
            DiscoveredConfiguration(
                imap: DiscoveredServer(username: nil, host: "imap.example.com", port: 143, security: .tls),
                smtp: DiscoveredServer(username: "u", host: "smtp.example.com", port: 465, security: .ssl)))
        #expect(form.imapUser == "name@example.com" && form.imapHost == "imap.example.com")
        #expect(form.imapPort == 143 && form.imapSecurity == .tls && form.imapPassword == "secret")
        #expect(form.smtpUser == "u" && form.smtpPort == 465 && form.smtpSecurity == .ssl)
    }
}

@Suite("Account setup feedback")
struct AccountSetupFeedbackTests {
    @Test(
        "every CouldNotConnectException reason, both services",
        arguments: [
            ("IMAP", "AUTHENTICATION_WRONG_PASSWORD", "IMAP username or password is wrong"),
            ("SMTP", "AUTHENTICATION_WRONG_PASSWORD", "SMTP username or password is wrong"),
            ("IMAP", "CONNECTION_ERROR", "IMAP server is not reachable"),
            ("SMTP", "CONNECTION_ERROR", "SMTP server is not reachable"),
            ("IMAP", "AUTHENTICATION_DENIED", "IMAP server denied authentication"),
            ("SMTP", "AUTHENTICATION_DENIED", "SMTP server denied authentication"),
            ("IMAP", "AUTHENTICATION", "IMAP authentication error"),
            ("SMTP", "AUTHENTICATION", "SMTP authentication error"),
            ("IMAP", "OTHER", "IMAP connection failed"),
            ("SMTP", "OTHER", "SMTP connection failed"),
            ("SIEVE", "CONNECTION_ERROR", "There was an error while setting up your account"),
        ])
    func connectFailures(service: String, reason: String, text: String) {
        #expect(AccountSetupFeedback(.connectFailed(service: service, reason: reason)).text == text)
    }

    @Test func aRateLimitIsDiscoveryUnavailable() {
        #expect(
            AccountSetupFeedback(.rateLimited(retryAfter: nil)).text
                == "Configuration discovery temporarily not available. Please try again later.")
    }

    @Test(
        "anything else is the generic line",
        arguments: [
            MailError.server(status: 500, message: "Could not create account"), .forbidden, .notFound,
            .transport(URLError(.notConnectedToInternet)),
        ])
    func otherFailuresAreGeneric(error: MailError) {
        #expect(AccountSetupFeedback(error) == .generic)
        #expect(AccountSetupFeedback.generic.text == "There was an error while setting up your account")
    }

    @Test func theFlowsOwnLines() {
        #expect(
            AccountSetupFeedback.discoveryFailed.text
                == "Configuration discovery failed. Please use the manual settings")
        #expect(AccountSetupFeedback.consentAborted.text == "Authorization pop-up closed")
        #expect(AccountSetupFeedback.passwordRequired.text == "Password required")
        #expect(
            AccountSetupFeedback.linkProvider(.google).text
                == "Account created. Please follow the pop-up instructions to link your Google account")
        #expect(!AccountSetupFeedback.linkProvider(.microsoft).isError)
    }
}
