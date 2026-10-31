import SwiftUI
import UIKit

enum AppStorageKey {
    static let defaultTemplate = "notes.defaultTemplate"
    static let dashboardLayout = "dashboard.layout"
    static let dashboardSortOrder = "dashboard.sortOrder"
}

struct SettingsView: View {
    @Environment(ApplePencilManager.self) private var pencil
    @Environment(CourseDataManager.self) private var data
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.defaultTemplate) private var defaultTemplate: PaperTemplate = .collegeRuled
    @State private var shareItem: ShareItem?
    @State private var backupError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Double-Tap", selection: pencil.preference(\.doubleTapBehavior)) {
                        ForEach(DoubleTapBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    Picker("Squeeze", selection: pencil.preference(\.squeezeBehavior)) {
                        ForEach(SqueezeBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                } header: {
                    Label("Apple Pencil Gestures", systemImage: "applepencil")
                } footer: {
                    Text("""
                    Your iPad's Apple Pencil settings: double-tap — \(ApplePencilManager.describe(UIPencilInteraction.preferredTapAction)); \
                    squeeze — \(ApplePencilManager.describe(UIPencilInteraction.preferredSqueezeAction)). \
                    Choose “Follow System Setting” to use those instead. Squeeze, barrel roll and Pencil haptics need Apple Pencil Pro.
                    """)
                }

                Section {
                    Picker("Draw With", selection: pencil.preference(\.fingerDrawing)) {
                        ForEach(FingerDrawingPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    Toggle("Hover Reticle (Tilt & Roll)", isOn: pencil.preference(\.showsHoverReticle))
                    Toggle("Haptic Feedback", isOn: pencil.preference(\.hapticsEnabled))
                } header: {
                    Text("Drawing")
                } footer: {
                    Text("When Apple Pencil hovers, the reticle shows the tip's footprint for your current tilt and a tick that follows barrel roll. It is hidden when hover previews are turned off in your iPad's Apple Pencil settings.")
                }

                Section("New Notes") {
                    Picker("Default Paper", selection: $defaultTemplate) {
                        ForEach(PaperTemplate.allCases) { template in
                            Label(template.displayName, systemImage: template.symbolName).tag(template)
                        }
                    }
                }

                Section {
                    Button {
                        exportBackup()
                    } label: {
                        Label("Export Library Backup…", systemImage: "archivebox")
                    }
                    LabeledContent("Library Folder", value: "On My iPad › CourseNotes")
                } header: {
                    Text("Data")
                } footer: {
                    Text("Side-loaded apps can expire or be removed, which deletes their data. Export a backup regularly, or copy the “CourseNotes Library” folder in the Files app.")
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Notes", value: "\(data.notes.count)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(activityItems: [item.url])
            }
            .alert("Backup Failed", isPresented: Binding(get: { backupError != nil }, set: { if !$0 { backupError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backupError ?? "")
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func exportBackup() {
        do {
            shareItem = ShareItem(url: try data.makeBackupArchive())
        } catch {
            backupError = error.localizedDescription
        }
    }
}
