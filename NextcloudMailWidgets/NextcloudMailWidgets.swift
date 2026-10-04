// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import WidgetKit

/// Important and Unread (ADR-0071). Both read `widget-snapshot.json` from the app group and
/// nothing else: no database, no network, no credentials. The app reloads the timelines
/// whenever it writes a changed snapshot, so a timeline never schedules its own refresh.
@main
struct NextcloudMailWidgets: WidgetBundle {
    var body: some Widget {
        ImportantWidget()
        UnreadWidget()
    }
}

nonisolated enum InboxList: String, Sendable {
    case important
    case unread

    var kind: String { "com.nextcloud.mail.macos.widgets.\(rawValue)" }

    var title: LocalizedStringResource {
        switch self {
        case .important: "Important"
        case .unread: "Unread"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .important: "The newest important messages in your inboxes."
        case .unread: "The newest unread messages in your inboxes."
        }
    }

    var emptyText: LocalizedStringResource {
        switch self {
        case .important: "No important messages"
        case .unread: "No unread messages"
        }
    }

    func items(in snapshot: WidgetSnapshot) -> [WidgetSnapshot.Item] {
        switch self {
        case .important: snapshot.important
        case .unread: snapshot.unread
        }
    }
}

struct InboxListEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has written a snapshot (not signed in, or never launched).
    let items: [WidgetSnapshot.Item]?
}

struct InboxListProvider: TimelineProvider {
    let list: InboxList

    func placeholder(in context: Context) -> InboxListEntry {
        InboxListEntry(date: Date(), items: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (InboxListEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InboxListEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> InboxListEntry {
        let snapshot = AppGroup.containerURL.flatMap { WidgetSnapshot.read(from: WidgetSnapshot.url(in: $0)) }
        return InboxListEntry(date: Date(), items: snapshot.map(list.items(in:)))
    }
}

struct ImportantWidget: Widget {
    var body: some WidgetConfiguration { InboxListWidget.configuration(.important) }
}

struct UnreadWidget: Widget {
    var body: some WidgetConfiguration { InboxListWidget.configuration(.unread) }
}

/// The two widgets differ only in which list of the snapshot they draw.
enum InboxListWidget {
    static func configuration(_ list: InboxList) -> some WidgetConfiguration {
        StaticConfiguration(kind: list.kind, provider: InboxListProvider(list: list)) { entry in
            InboxListView(list: list, entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(list.title)
        .description(list.summary)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct InboxListView: View {
    let list: InboxList
    let entry: InboxListEntry

    @Environment(\.widgetFamily) private var family

    /// How many rows fit: the snapshot carries up to seven.
    private var visibleCount: Int {
        switch family {
        case .systemSmall: 2
        case .systemMedium: 3
        default: WidgetSnapshot.cap
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(list.title)
                .font(.headline)
            if let items = entry.items, !items.isEmpty {
                ForEach(items.prefix(visibleCount)) { item in
                    row(item)
                }
            } else {
                Group {
                    if entry.items == nil {
                        Text("Open Nextcloud Mail to sign in")
                    } else {
                        Text(list.emptyText)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ item: WidgetSnapshot.Item) -> some View {
        let content = VStack(alignment: .leading) {
            Text(item.sender)
                .font(.subheadline.weight(item.isUnread ? .semibold : .regular))
                .lineLimit(1)
            Text(item.subject)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if let url = SystemLink.message(item.id).url {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}
