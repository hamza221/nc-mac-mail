// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NextcloudUI
import SwiftUI

/// The composer windows: one per ``ComposeRequest`` (§6.3).
///
/// `WindowGroup(for:)` already gives "one window per draft": opening a request a window is
/// presenting brings that window forward instead of building a second. The web client's
/// minimise is the window's own minimise; its maximise is the window's zoom.
///
/// This scene also owns ⌘Q: quitting with unsent composers asks first, which needs the
/// app-termination menu item, and commands from any scene apply app-wide.
struct ComposerScene: Scene {
    let session: AppSession

    var body: some Scene {
        WindowGroup(id: OpenComposerAction.windowId, for: ComposeRequest.self) { $request in
            if let request {
                ComposerWindowRoot(request: request, session: session)
                    .environment(session)
                    .ncTheme(session.theme)
            }
        }
        .defaultSize(width: 760, height: 680)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Nextcloud Mail") { ComposerWindows.shared.requestQuit() }
                    .keyboardShortcut("q")
            }
        }
    }
}

/// Holds the model for the window's life and connects it to the window: restoration of the
/// local draft row, hiding while a send is under way, and closing.
private struct ComposerWindowRoot: View {
    let request: ComposeRequest
    let session: AppSession

    @State private var model: ComposerModel
    /// The local `draft` row this window edits, so a relaunch resumes the same draft
    /// instead of starting a second one from the request.
    @SceneStorage("composer.draftId") private var restoredDraftId: Int = 0
    @Environment(\.dismiss) private var dismiss

    init(request: ComposeRequest, session: AppSession) {
        self.request = request
        self.session = session
        _model = State(initialValue: ComposerModel(request: request, session: ComposerServices(session: session)))
    }

    var body: some View {
        ComposerView(model: model)
            .background(WindowReader { window in model.window = window })
            .navigationTitle(model.title)
            .navigationSubtitle(subtitle)
            .focusedSceneValue(\.composerCommands, commands)
            .task { await start() }
            .onDisappear { model.windowClosed() }
    }

    private var subtitle: String {
        model.title == model.kindTitle ? "" : model.kindTitle
    }

    private var commands: ComposerCommandActions {
        let model = model
        var heading: (@MainActor (Int) -> Void)?
        if model.document.mode == .rich {
            heading = { level in model.document.setHeading(level) }
        }
        return ComposerCommandActions(
            send: { model.requestSend() },
            saveDraft: { model.saveNow() },
            canSend: model.canSend,
            heading: heading
        )
    }

    private func start() async {
        model.onDraftCreated = { restoredDraftId = Int($0) }
        model.dismiss = { dismiss() }
        await model.load(restoringDraftId: restoredDraftId == 0 ? nil : Int64(restoredDraftId))
        await model.cancelOutboxIfSafe()
    }
}

/// The `NSWindow` behind a SwiftUI window, for the two things SwiftUI has no API for:
/// hiding a window without closing it and bringing it back.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}
