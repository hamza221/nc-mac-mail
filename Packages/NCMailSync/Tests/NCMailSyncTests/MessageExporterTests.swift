// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NCMailTestSupport
import Testing

@testable import NCMailSync

@Suite("Message exporter")
struct MessageExporterTests {
    struct Fixture {
        let base: ServerResultFetcherTests.Fixture
        let exporter: MessageExporter
        let directory: URL

        var transport: FakeTransport { base.transport }
        var remoteId: Int64 { base.remoteId }
        var messageId: Int64 { base.messageId }
        var target: URL { directory.appendingPathComponent("out.bin") }

        func contents() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
        }
    }

    static func fixture() async throws -> Fixture {
        let base = try await ServerResultFetcherTests.fixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let exporter = MessageExporter(store: base.seeded.store, client: try MirrorTest.client(base.transport))
        return Fixture(base: base, exporter: exporter, directory: directory)
    }

    static let bytes = Data("fixture bytes \u{0}\u{1}".utf8)

    @Test(".eml writes the export endpoint's bytes")
    func eml() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(.pathSuffix("/messages/\(f.remoteId)/export"), with: StubResponse(body: Self.bytes))
        try await f.exporter.export(.eml, messageId: f.messageId, to: f.target)
        #expect(try Data(contentsOf: f.target) == Self.bytes)
        #expect(try f.contents() == ["out.bin"])
    }

    @Test(".attachmentsZip writes the zip endpoint's bytes, replacing an existing file")
    func attachmentsZip() async throws {
        let f = try await Self.fixture()
        try Data("old".utf8).write(to: f.target)
        await f.transport.stub(
            .pathSuffix("/messages/\(f.remoteId)/attachments"), with: StubResponse(body: Self.bytes))
        try await f.exporter.export(.attachmentsZip, messageId: f.messageId, to: f.target)
        #expect(try Data(contentsOf: f.target) == Self.bytes)
        #expect(try f.contents() == ["out.bin"])
    }

    @Test(".attachment serves the mirrored bytes without a request")
    func attachmentFromMirror() async throws {
        let f = try await Self.fixture()
        let store = f.base.seeded.store
        try await store.upsert(
            body: MessageBodyWrite(fetchedAt: 1, plainBody: "x", attachments: [AttachmentWrite(attachmentId: "2.1")]),
            for: f.messageId
        )
        try await store.storeInlineAttachment(
            messageId: f.messageId, attachmentId: "2.1", data: Self.bytes, fetchedAt: 1)
        try await f.exporter.export(.attachment(id: "2.1"), messageId: f.messageId, to: f.target)
        #expect(try Data(contentsOf: f.target) == Self.bytes)
        #expect(await f.transport.sendCount == 0)
    }

    @Test(".attachment falls back to the attachment endpoint")
    func attachmentFromServer() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(
            .pathSuffix("/messages/\(f.remoteId)/attachment/2.1"), with: StubResponse(body: Self.bytes))
        try await f.exporter.export(.attachment(id: "2.1"), messageId: f.messageId, to: f.target)
        #expect(try Data(contentsOf: f.target) == Self.bytes)
        #expect(await f.transport.sendCount == 1)
    }

    @Test("a failed request leaves no file behind")
    func failureLeavesNoFile() async throws {
        let f = try await Self.fixture()
        await f.transport.stub(.pathSuffix("/messages/\(f.remoteId)/export"), with: .status(500))
        await #expect(throws: MailError.self) {
            try await f.exporter.export(.eml, messageId: f.messageId, to: f.target)
        }
        #expect(try f.contents().isEmpty)
    }

    @Test("an unknown message is notFound and sends nothing")
    func unknownMessage() async throws {
        let f = try await Self.fixture()
        await #expect(throws: MailError.self) {
            try await f.exporter.export(.eml, messageId: 999_999, to: f.target)
        }
        #expect(await f.transport.sendCount == 0)
    }
}
