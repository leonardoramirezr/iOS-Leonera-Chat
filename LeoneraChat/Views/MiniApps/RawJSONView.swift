import SwiftUI

/// Which side of a run the raw JSON shows.
enum RawPart: String, Identifiable, CaseIterable {
    case request, response

    var id: String { rawValue }
}

/// The request a run sent, or the response it got back, as raw JSON. Read live from the run, so a
/// response that arrives while this is open shows up here.
struct RawJSONView: View {
    let appID: UUID
    @State private var part: RawPart
    @State private var text: String?

    @Environment(RunStore.self) private var runs
    @Environment(\.dismiss) private var dismiss

    init(appID: UUID, part: RawPart) {
        self.appID = appID
        _part = State(initialValue: part)
    }

    var body: some View {
        let result = runs.run(appID).result
        let file = part == .request ? result?.rawRequest : result?.rawResponse

        NavigationStack {
            ScrollView {
                content(file)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .task(id: file) {
                        text = nil
                        guard let file else { return }
                        let loaded = await RawJSON.text(of: file)
                        if !Task.isCancelled { text = loaded }
                    }
            }
            .safeAreaInset(edge: .top) {
                Picker("Raw JSON", selection: $part) {
                    Text("Request").tag(RawPart.request)
                    Text("Response").tag(RawPart.response)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()
                .background(.bar)
            }
            .navigationTitle("Raw JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                    }
                    .disabled(text == nil)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ file: StoredFile?) -> some View {
        if let text {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        } else if file != nil {
            ProgressView()
        } else if part == .request {
            ContentUnavailableView("Not available yet.", systemImage: "curlybraces")
        } else {
            ContentUnavailableView("Waiting for the response…", systemImage: "curlybraces")
        }
    }
}

enum RawJSON {
    /// The stored JSON, indented so it can be read. Runs off the main actor: a request can hold several photos.
    static func text(of file: StoredFile) async -> String {
        guard let data = try? BlobStore.data(for: file) else { return String(localized: "Couldn't read it.") }
        return indented(data)
    }

    private static func indented(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }
}
