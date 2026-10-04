// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing

@testable import NextcloudMail

/// The undo-send strip slides only when Reduce Motion is off (ux-spec.md, Accessibility).
///
/// `UndoSendBanner` reads `\.accessibilityReduceMotion` and takes its transition from
/// ``UndoSendBannerMotion`` and nowhere else, so this mapping is the whole decision.
@Suite("Undo-send banner motion")
struct UndoSendBannerMotionTests {
    @Test("Reduce Motion fades; otherwise the notice slides up from the bottom edge")
    func reduceMotionFades() {
        #expect(UndoSendBannerMotion(reduceMotion: true) == .fade)
        #expect(UndoSendBannerMotion(reduceMotion: false) == .slide)
    }
}
