// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

internal import Foundation
internal import NCMailNet
internal import NCMailStore

/// Stage 2: one account-wide queue of bodies, newest first, at two requests at a time.
///
/// This is the expensive stage and the only one the server really feels. `GET /body` opens
/// an IMAP connection, fetches, parses and sanitises; it is not a database read. The four
/// rules in `local-mirror.md` — bounded concurrency, yield to the user, back off on
/// pressure, stop when the machine is not ours — are implemented here, and each one is a
/// promise to somebody else's server.
extension MirrorCoordinator {
    func runBodyStage() async throws {
        if let reason = bodyPauseReason {
            MirrorLog.mirror.info("stage 2 held: \(reason.rawValue, privacy: .public)")
            return
        }
        await setBodyStageState()
        resetBodyQueue()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, configuration.bodyConcurrency) {
                group.addTask(priority: .utility) { await self.bodyWorker() }
            }
        }
        try Task.checkCancellation()
    }

    /// Everything that stops bodies: what stops the whole mirror, plus the three conditions
    /// etiquette rule 4 names — Low Power Mode, an expensive path, a constrained path.
    var bodyPauseReason: MirrorPauseReason? {
        if let reason = runPauseReason { return reason }
        if configuration.isLowPowerModeEnabled() { return .lowPowerMode }
        if conditions.isExpensive { return .expensiveNetwork }
        if conditions.isConstrained { return .constrainedNetwork }
        return nil
    }

    private func bodyWorker() async {
        while !Task.isCancelled {
            if bodyPauseReason != nil { return }
            await releaseThrottleIfExpired()
            guard let item = await claimNextBody() else { return }

            // Account first, then the process-wide cap, in that order everywhere, so two
            // workers cannot each hold half of what the other needs.
            await accountBudget.acquire()
            await globalBudget.acquire()
            await fetchAndStoreBody(item)
            await globalBudget.release()
            await accountBudget.release()

            await finishBody(item.id)
            // Between items, so a burst of small bodies cannot starve the scroll view.
            await Task.yield()
        }
    }

    // MARK: - The queue

    private func resetBodyQueue() {
        pendingBodies.removeAll(keepingCapacity: true)
        isBodyQueueExhausted = false
        bodyFailureCounts.removeAll(keepingCapacity: true)
    }

    /// The next message to fetch, refilling from the database when the in-memory slice runs
    /// out. Newest first across every mailbox of the account, because recency is what
    /// people open.
    private func claimNextBody() async -> BodyBackfillItem? {
        if pendingBodies.isEmpty, !isBodyQueueExhausted {
            // Over-fetch by what is in flight: those rows are still `missing` in the
            // database (deliberately — see the note on `pendingBodies`), so without the
            // slack a batch could come back entirely full of work already being done.
            let batch =
                (try? await store.nextBodyBackfillBatch(
                    accountId: accountId,
                    limit: configuration.bodyBatchSize + inFlightBodyIds.count
                )) ?? []
            pendingBodies = batch.filter { !inFlightBodyIds.contains($0.id) }
            if pendingBodies.isEmpty { isBodyQueueExhausted = true }
        }
        guard !pendingBodies.isEmpty else { return nil }
        let item = pendingBodies.removeFirst()
        inFlightBodyIds.insert(item.id)
        return item
    }

    private func finishBody(_ messageId: Int64) async {
        inFlightBodyIds.remove(messageId)
        bodiesSincePublish += 1
        // Every tenth body rather than every body. The progress query is four `count(*)`s
        // over `message`, measured at 0.83 ms median on a 50,000-row mirror — small, but
        // spent on the one database queue the list's `ValueObservation`s also want, and the
        // sidebar cannot read a count that changes ten times a second anyway.
        if bodiesSincePublish >= 10 || pendingBodies.isEmpty {
            bodiesSincePublish = 0
            await publishProgress()
        }
    }

    // MARK: - One body

    /// `GET /body`, then `GET /html?plain=true` when the message has an HTML part, then one
    /// transaction for the body row, the attachments, the search index and `bodyState`.
    func fetchAndStoreBody(_ item: BodyBackfillItem) async {
        let messageId = item.id
        do {
            // The request takes the server's id; the write takes the mirror's. They are not
            // the same number once a second server is signed in (ADR-0033).
            let body = try await client.get(.messageBody(id: Int(item.remoteId)))
            var html: String?
            if body.value.hasHtmlBody {
                html = try await fetchSanitisedHTML(item)
            }
            let write = try MirrorMapping.bodyWrite(body, html: html, fetchedAt: configuration.now())
            try await store.upsert(body: write, for: messageId)
            bodyFailureCounts[messageId] = nil
        } catch is CancellationError {
            // The row stays `missing`; the next run picks it up.
        } catch MailError.notFound {
            await abandonBody(messageId, why: "notFound")
        } catch MailError.forbidden {
            // The ordinary answer to an id the server will not show us, which for a mirror
            // means the message was deleted elsewhere. Not a lost session, not a sign-out.
            await abandonBody(messageId, why: "forbidden")
        } catch MailError.rateLimited(let retryAfter) {
            await applyThrottle(retryAfter: retryAfter)
        } catch {
            await countBodyFailure(messageId, error)
        }
    }

    /// The sanitised fragment, or nil when the server has the body but not the HTML.
    ///
    /// Measured against the live server: for one stale id, `/body` answers 403 and
    /// `/html?plain=true` answers 404 with an HTML error fragment. So the two routes
    /// disagree about the same message, and a 404 here after a successful `/body` is worth
    /// keeping the body for rather than throwing the whole fetch away.
    private func fetchSanitisedHTML(_ item: BodyBackfillItem) async throws -> String? {
        do {
            let (data, _) = try await client.bytes(.messageHTML(id: Int(item.remoteId)))
            return String(decoding: data, as: UTF8.self)
        } catch MailError.notFound {
            MirrorLog.mirror.info(
                "message \(item.id, privacy: .public) has a body but no html fragment; storing the body"
            )
            return nil
        }
    }

    private func abandonBody(_ messageId: Int64, why: String) async {
        MirrorLog.mirror.info(
            "message \(messageId, privacy: .public) body unavailable (\(why, privacy: .public)); marked failed"
        )
        try? await store.setBodyState(.failed, messageIds: [messageId])
        bodyFailureCounts[messageId] = nil
    }

    /// Three strikes and the message is left to the deep reconcile rather than retried in a
    /// loop that would spend the whole backfill budget on one broken message.
    private func countBodyFailure(_ messageId: Int64, _ error: any Error) async {
        let count = (bodyFailureCounts[messageId] ?? 0) + 1
        bodyFailureCounts[messageId] = count
        MirrorLog.mirror.error(
            """
            message \(messageId, privacy: .public) body failed \(count, privacy: .public)×: \
            \(describe(error), privacy: .public)
            """
        )
        guard count >= configuration.bodyFailureLimit else {
            // Still `missing`, so the next refill offers it again.
            return
        }
        try? await store.setBodyState(.failed, messageIds: [messageId])
        bodyFailureCounts[messageId] = nil
    }

    // MARK: - Etiquette rule 3: back off on pressure

    /// Halves body concurrency for ten minutes and waits out `Retry-After` once more.
    ///
    /// `MailClient` has already honoured the header up to three times by the time this
    /// error escapes it, so the wait here is not the header's first hearing — it is what
    /// stops the other worker walking straight into the same wall with the next message.
    private func applyThrottle(retryAfter: Duration?) async {
        let now = configuration.now()
        let until = now + configuration.throttleCooldownSeconds
        if throttledUntil == nil {
            await accountBudget.setLimit(max(1, configuration.bodyConcurrency / 2))
            MirrorLog.mirror.error(
                """
                account \(self.accountId, privacy: .public) throttled by the server; \
                body concurrency halved for \(self.configuration.throttleCooldownSeconds, privacy: .public)s
                """
            )
        }
        throttledUntil = max(throttledUntil ?? until, until)
        try? await configuration.sleep(retryAfter ?? .seconds(1))
    }

    func releaseThrottleIfExpired() async {
        guard let until = throttledUntil, configuration.now() >= until else { return }
        throttledUntil = nil
        await accountBudget.setLimit(configuration.bodyConcurrency)
        MirrorLog.mirror.info("account \(self.accountId, privacy: .public) throttle lifted")
    }

    private func setBodyStageState() async {
        try? await store.setMirrorState(.bodies, accountId: accountId, lastSyncAt: configuration.now())
    }

    // MARK: - Etiquette rule 2: yield to the user

    /// The user opened a message whose body is not mirrored yet.
    ///
    /// It jumps the whole queue and preempts a backfill slot rather than waiting for one,
    /// so interactive latency is one round trip regardless of how much backfill is in
    /// flight. It also runs while the mirror is paused, on Low Power Mode and on a metered
    /// network: those are reasons not to download fifty thousand bodies unasked, not
    /// reasons to refuse the one the user is looking at.
    ///
    /// Returns once the body is in the database, so the caller knows when the view will
    /// have it. The view itself reads the row through a `ValueObservation` and never this
    /// return value.
    public func prioritise(messageId: Int64) async {
        guard !inFlightBodyIds.contains(messageId) else { return }
        // The row also supplies the server id the request needs, which the view has no
        // business knowing (ADR-0033).
        guard let record = try? await store.message(id: messageId), record.bodyState != .present else {
            return
        }
        let item = BodyBackfillItem(id: messageId, remoteId: record.remoteId)
        pendingBodies.removeAll { $0.id == messageId }
        inFlightBodyIds.insert(messageId)

        await accountBudget.preempt()
        await fetchAndStoreBody(item)
        await accountBudget.release()

        inFlightBodyIds.remove(messageId)
        await publishProgress()
    }
}
