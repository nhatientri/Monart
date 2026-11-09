import SwiftUI

@main
struct CanvasApp: App {
    init() {
        // With iCloud Drive enabled, document apps show an Open panel at launch instead
        // of a new untitled document. Start with a blank canvas instead.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
    }

    var body: some Scene {
        DocumentGroup(newDocument: { CanvasDocument() }) { file in
            ContentView(document: file.document)
        }
        .commands { AppCommands() }
    }
}
