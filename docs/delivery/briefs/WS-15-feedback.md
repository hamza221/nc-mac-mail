# WS-15 — Library and server feedback

**Runs throughout. Lands at the end. Size: S — but it is half of why this project exists.**

## Goal

Turn everything every workstream learned into something `NextcloudUI` can freeze its API on,
and something Nextcloud Mail can act on.

## Before you start

- `hamza221/nextcloud-swiftui`: `README.md` ("Build a real Mail client against it, and
  freeze the API on what that finds"), `docs/ROADMAP.md`, `CONTRIBUTING.md`
- [../../feedback/library-feedback.md](../../feedback/library-feedback.md) — what is already there
- [../../feedback/server-findings.md](../../feedback/server-findings.md)
- Every merged workstream's pull request report

## You own

`docs/feedback/**`

## The standing obligation on everyone else

Every workstream appends as it goes. You curate. If a workstream's report says "nothing
new" and its diff contains a workaround, go back and ask — the workaround is the finding.

## Build

**`library-feedback.md`**, organised so the library maintainer can act on it:

| Section | Contents |
| --- | --- |
| Missing icons | The MDI names a mail client needs and the catalogue lacks, with where each is used |
| API friction | Every place a component needed a workaround, with the call site and what would have been better |
| Composition gaps | Shapes a mail client needs that no component covers — the leading accessory column, the message header block |
| Things that worked | Which decisions paid off, because a feedback document that only complains is not evidence |
| Performance | `NCListItem` at 50,000 rows, `NCAvatar` loader behaviour, anything measured |
| Open questions | Where the app made a choice the library should make instead |

Each entry: what happened, where (file and line), what we did instead, what we would have
preferred. An entry without a call site is an opinion.

**`server-findings.md`** — what `nextcloud/mail` could do better for native clients:

- no bulk body endpoint, which is what makes an initial mirror expensive;
- `POST /sync`'s `changedMessages` returning everything you claim to know, with its `TODO`;
- `newMessages` returning thread heads only;
- `destFolderId` versus `destMailboxId`;
- envelope `flags` an object, body `flags` an array;
- mailbox `selectable` computed server-side but not serialised;
- `displayName` being the full path;
- anything else found during implementation.

Each with a file and line reference, a suggested fix, and whether it is a bug or a
design-for-browsers assumption.

**Upstream.** Draft the issues — one per repository, or a small set grouped sensibly —
ready for a human to post. Do not file them yourself. Include the reproduction and the
version (Mail 5.12.0-rc.1).

## Acceptance

- Every merged workstream's report is represented, or explicitly considered and left out
  with a reason.
- Every library entry names a call site.
- Every server finding cites a file and line.
- The "things that worked" section is not empty. If it is, the document is not evidence, it
  is a complaint.
- The drafts are postable without editing.

## Out of scope

Changing either upstream repository. Making the library changes ourselves.

## Report

The pull request body **is** the summary: the three things `NextcloudUI` should change
before freezing its API, and the one thing Nextcloud Mail should add for native clients.
Short enough that a maintainer reads all of it.
