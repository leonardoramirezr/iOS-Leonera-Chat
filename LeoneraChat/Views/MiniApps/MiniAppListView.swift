import SwiftUI

struct MiniAppsTab: View {
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            MiniAppListView { path.append($0) }
                .navigationDestination(for: UUID.self) { id in
                    MiniAppRunnerView(appID: id)
                }
        }
    }
}

/// What the editor sheet is open for: a new mini app, or one to change.
struct EditorTarget: Identifiable {
    let id = UUID()
    var app: MiniApp?
}

struct MiniAppListView: View {
    var open: (UUID) -> Void

    @Environment(MiniAppStore.self) private var miniApps
    @Environment(RunStore.self) private var runs

    @State private var editing: EditorTarget?
    @State private var deleting: MiniApp?

    var body: some View {
        Group {
            if miniApps.apps.isEmpty {
                ContentUnavailableView {
                    Label("Your mini apps", systemImage: "sparkles")
                } description: {
                    Text("A mini app is a prompt that asks you a few things and gives back one result. Set it up once and run it as often as you want.")
                } actions: {
                    Button {
                        editing = EditorTarget()
                    } label: {
                        Label("New mini app", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(miniApps.sorted) { app in
                        NavigationLink(value: app.id) {
                            MiniAppRow(app: app, running: runs.isRunning(app.id))
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = app }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = EditorTarget(app: app) }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = app }
                        }
                    }
                }
            }
        }
        .navigationTitle("Mini apps")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = EditorTarget()
                } label: {
                    Label("New mini app", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { target in
            MiniAppEditorView(app: target.app) { id in
                if target.app == nil { open(id) }
            }
        }
        .confirmationDialog(
            "Delete this mini app? Its last result will be deleted too.",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { app in
            Button("Delete mini app", role: .destructive) {
                runs.forget(app.id)
                miniApps.remove(app.id)
            }
        }
    }
}

private struct MiniAppRow: View {
    let app: MiniApp
    let running: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if running {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let questions = app.questions.count
        var parts = [questions == 1 ? String(localized: "1 question") : String(localized: "\(questions) questions")]
        let images = app.inputs.filter { $0.kind == .image }.count
        let files = app.inputs.count - images
        if images > 0 { parts.append(images == 1 ? String(localized: "1 image") : String(localized: "\(images) images")) }
        if files > 0 { parts.append(files == 1 ? String(localized: "1 file") : String(localized: "\(files) files")) }
        return parts.joined(separator: " · ")
    }
}
