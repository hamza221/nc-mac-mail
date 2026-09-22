// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NCMailNet
import NCMailStore
import NextcloudUI
import OSLog

/// Installs the instance's brand colour before the first frame, and keeps it current
/// afterwards.
///
/// The colour has to be available synchronously, before `WindowGroup` draws anything, or a
/// returning user sees the stock Nextcloud blue for one frame and then a visible recolour —
/// exactly what [S-09](../../docs/product/user-stories.md#s-09-it-looks-like-the-instance-it-belongs-to-ws-13)
/// asks not to happen. `MailStore`'s `meta` table is the obvious home for a cached value, but
/// its only public interface is `async`, deliberately, so that GRDB access is never main-actor
/// work ([concurrency.md](../../docs/architecture/concurrency.md)). This one small,
/// non-sensitive value also lives in `UserDefaults`, read synchronously at launch only.
/// [ADR-0027](../../docs/decisions/0027-userdefaults-cache-for-the-launch-theme.md) has the
/// alternative that gave up.
///
/// The *live* refresh still goes through `meta`, on purpose: this type never hands a theme
/// back to a caller to render. It writes the colour to the database, and `AppSession` renders
/// whatever `MailStore.observeMetaValue` reports — the same "network only writes, views only
/// read" shape as everything else in
/// [overview.md](../../docs/architecture/overview.md#the-invariant), for a value that would
/// otherwise have been the one exception.
enum ThemeCache {
    /// Shared with `AppSession`, which observes this same key rather than being handed a
    /// theme directly.
    static let metaKey = "theme.primaryColorHex"

    private static let logger = Logger(subsystem: "com.nextcloud.mail.macos", category: "theme")
    private static let defaultsKey = "theme.primaryColorHex"

    /// The theme to install at the scene root: last launch's brand colour, or the stock
    /// palette on a first run or after a colour that failed to parse.
    static func cachedTheme(defaults: UserDefaults = .standard) -> NCTheme {
        guard let hex = defaults.string(forKey: defaultsKey), let brand = NCBrand(primaryHex: hex) else {
            return .nextcloud
        }
        return NCTheme(brand: brand)
    }

    /// Re-reads capabilities and, on a colour that parses, writes it to `meta` and to
    /// `UserDefaults`. Does not touch `NCTheme` itself — see the type's documentation for why.
    ///
    /// - Throws: ``MailError/unauthorized`` only. Every other failure — offline, a slow
    ///   server, a colour that will not parse — leaves the cached colour exactly as this
    ///   launch already found it, which is correct rather than degraded.
    static func refresh(client: MailClient, store: MailStore, defaults: UserDefaults = .standard) async throws {
        do {
            let response = try await client.get(.capabilities)
            guard let hex = response.data.theming?.color else { return }
            guard NCBrand(primaryHex: hex) != nil else {
                logger.error("server reported a brand colour that did not parse as #rrggbb")
                return
            }
            defaults.set(hex, forKey: defaultsKey)
            try await store.setMetaValue(hex, forKey: metaKey)
        } catch MailError.unauthorized {
            throw MailError.unauthorized
        } catch {
            logger.debug("capabilities refresh skipped: \(String(describing: error), privacy: .public)")
        }
    }
}
