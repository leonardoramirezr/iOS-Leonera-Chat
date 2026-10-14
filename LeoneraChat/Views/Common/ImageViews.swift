import Photos
import SwiftUI

/// An image kept on the device, decoded off the main thread.
struct StoredImageView: View {
    let file: StoredFile
    /// The size it is decoded at: thumbnails need far fewer pixels than the photo has.
    var maxPixelSize: Int?
    var contentMode: ContentMode = .fit

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .task(id: file) {
            image = await ImageLoader.load(file, maxPixelSize: maxPixelSize)
        }
    }
}

enum PhotoLibrary {
    enum Failure: Error {
        case denied
    }

    /// Saves the image, as it is, to the photo library.
    static func save(_ file: StoredFile) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        let url = BlobStore.url(for: file)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}

struct SaveImageButton: View {
    let file: StoredFile

    @State private var state = SaveState.idle

    private enum SaveState {
        case idle, saving, saved, failed
    }

    var body: some View {
        Button {
            Task { await save() }
        } label: {
            switch state {
            case .idle, .saving: Label("Save", systemImage: "square.and.arrow.down")
            case .saved: Label("Saved", systemImage: "checkmark")
            case .failed: Label("Couldn't save", systemImage: "exclamationmark.triangle")
            }
        }
        .disabled(state == .saving)
    }

    private func save() async {
        state = .saving
        do {
            try await PhotoLibrary.save(file)
            state = .saved
        } catch {
            state = .failed
        }
        try? await Task.sleep(for: .seconds(2))
        state = .idle
    }
}

/// An image on the whole screen, to zoom in, save or share.
struct ImageViewer: View {
    let file: StoredFile

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            StoredImageView(file: file)
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(magnification)
                .simultaneousGesture(drag)
                .onTapGesture(count: 2) {
                    withAnimation(.spring) {
                        if scale > 1 {
                            reset()
                        } else {
                            scale = 2.5
                            settledScale = 2.5
                        }
                    }
                }
                .background(Color.black.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        SaveImageButton(file: file)
                        Spacer()
                        ShareLink(item: BlobStore.url(for: file))
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
                .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        }
        .preferredColorScheme(.dark)
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1 { withAnimation(.spring) { reset() } }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                if scale > 1 {
                    settledOffset = offset
                } else if value.translation.height > 120 {
                    // Pulled down: closed, as photos are in the system.
                    dismiss()
                }
            }
    }

    private func reset() {
        scale = 1
        settledScale = 1
        offset = .zero
        settledOffset = .zero
    }
}

/// The camera, to take a photo for the chat or a mini app.
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
}
