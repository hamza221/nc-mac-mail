// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

@testable import NCMailCore

// What the header, the list row, the thread strip and the printed page show for a sender.
// The label is attacker-chosen, so the property under test is that the real address is
// never left off when the label is anything other than that address.

@Suite("Address display")
struct AddressDisplayTests {
    @Test(
        "a label that is not the address brings the address with it",
        arguments: ["security@paypal.com", "PayPal Security", "attacker@evil.example.com"]
    )
    func spoofedLabelShowsTheAddress(label: String) {
        let sender = Address(label: label, email: "attacker@evil.example")

        #expect(sender.addressBesideName == "attacker@evil.example")
        #expect(sender.nameAndAddress == "\(label) <attacker@evil.example>")
    }

    @Test("a sender with no label shows its address once", arguments: [nil, ""] as [String?])
    func labelLessShowsTheAddressOnce(label: String?) {
        let sender = Address(label: label, email: "rory@example.com")

        #expect(sender.addressBesideName == nil)
        #expect(sender.displayName == "rory@example.com")
        #expect(sender.nameAndAddress == "rory@example.com")
    }

    @Test("a label that is the address, give or take case and blanks, is not repeated")
    func labelThatIsTheAddressIsNotRepeated() {
        let sender = Address(label: " Rory@Example.com ", email: "rory@example.com")

        #expect(sender.addressBesideName == nil)
        #expect(sender.nameAndAddress == " Rory@Example.com ")
    }

    @Test("a group address has a label and nothing to put beside it")
    func groupAddressShowsTheLabel() {
        let group = Address(label: "undisclosed-recipients", email: nil)

        #expect(group.addressBesideName == nil)
        #expect(group.nameAndAddress == "undisclosed-recipients")
    }
}
