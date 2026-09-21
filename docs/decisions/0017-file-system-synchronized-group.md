<!--
SPDX-FileCopyrightText: Hamza Mahjoubi
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# ADR-0017: The app target reads its sources from a synchronised folder

**Status:** Accepted
**Date:** 2026-09-21
**Decided by:** WS-00, writing the project file by hand

## Context

[ADR-0001](0001-xcode-project-in-git.md) puts `project.pbxproj` in git and names the cost:
it is a merge-conflict surface, mitigated by letting one workstream at a time add file
references. Eight of the sixteen workstreams add files under `NextcloudMail/`, and under
the classic `PBXGroup` + `PBXFileReference` + `PBXBuildFile` scheme each of those additions
is three new lines in the one file nobody else may touch.

Xcode 16 added `PBXFileSystemSynchronizedRootGroup`: a group whose members are whatever is
in the folder on disk, resolved at build time. The project format that carries it is
`objectVersion = 77`.

## Decision

`NextcloudMail.xcodeproj` uses one synchronised root group for `NextcloudMail/`. The
project file names the folder; it does not name a single Swift file. Adding, renaming,
moving or deleting anything under `NextcloudMail/` changes no line of `project.pbxproj`.

The file is written by hand in the modern format, not generated. XcodeGen is installed on
the development machine and was not used: ADR-0001 rejected a generator, and a synchronised
group removes most of the reason to want one.

## Consequences

- The `.pbxproj` stops being a per-workstream conflict surface. It changes when a build
  setting, a target or a package dependency changes — a WS-00 concern — and not when
  someone adds a view.
- The ownership row "`NextcloudMail.xcodeproj/**` — WS-00 only" costs the other workstreams
  nothing, so it is easy to keep.
- Anything dropped into `NextcloudMail/` is compiled, including a file left behind by
  accident. The build phase is no longer a second place to notice.
- Xcode 16 or newer is required to open the project. Pinned to 26.6 in `.xcode-version`
  regardless.
- Per-file build settings would need an `exceptions` entry in the group. There are none
  today and the mechanism exists if one is ever needed.

## Alternatives considered

**Explicit file references.** Works everywhere, and hands every UI workstream a reason to
edit the one file it does not own.

**XcodeGen from a committed `project.yml`.** Would also solve it, at the price ADR-0001
already weighed: a generator dependency and two sources of truth, one of which Xcode
silently rewrites. With the synchronised group there is nothing left for it to buy.

## Revisit when

A file under `NextcloudMail/` needs its own build settings, or the project has to be opened
by an Xcode older than 16.
