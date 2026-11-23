import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Picks a `.halodigest` with `asCopy: true`: the system copies the file into the app's own
/// container first, so the importer's post-import delete only ever removes the app's copy, never
/// the user's original.
struct DigestDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    static var contentTypes: [UTType] {
        [UTType("study.paradigm.halo.digest") ?? UTType(filenameExtension: "halodigest") ?? .data]
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}
