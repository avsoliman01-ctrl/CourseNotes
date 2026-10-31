import SwiftUI

@main
struct CourseNotesApp: App {
    @State private var dataManager = CourseDataManager()
    @State private var pencilManager = ApplePencilManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryRootView()
                .environment(dataManager)
                .environment(pencilManager)
        }
        .onChange(of: scenePhase) { _, phase in
            // Open editors save their ink on `.inactive`; this commits metadata and waits for
            // in-flight writes before iOS suspends the app.
            if phase == .background {
                dataManager.flushToDisk()
            }
        }
    }
}
