// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A compilation anchor, not an API.
///
/// A SwiftPM target with no source file does not build, and WS-00 ships no
/// behaviour. WS-03 deletes this file when it adds the first real type.
enum NCMailStorePlaceholder {}
