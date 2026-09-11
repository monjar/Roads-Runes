import PhotosUI
import RoadsAndRunesCore
import SwiftUI
import UIKit

extension Objective {
    /// Objectives the GPS cannot finish: the rider has to photograph or write something.
    var needsRider: Bool {
        objectiveType == .photoLocation || objectiveType == .writeNote
    }
}

/// Scribe work during a ride (spec §12, the Scribe class): one tap to photograph,
/// one to write. Both say to stop first — the rider is on a bicycle.
struct ScribeActions: View {
    let objective: Objective
    let onNote: (String) -> Void
    let onPhoto: (Data) -> Void

    @State private var writingNote = false
    @State private var takingPhoto = false

    var body: some View {
        HStack(spacing: 8) {
            if objective.objectiveType == .photoLocation {
                action("Photograph", symbol: "camera.fill") { takingPhoto = true }
            }
            if objective.objectiveType == .writeNote {
                action("Write a note", symbol: "square.and.pencil") { writingNote = true }
            }
        }
        .sheet(isPresented: $writingNote) {
            NoteSheet(title: objective.title) { note in
                onNote(note)
                writingNote = false
            }
        }
        .sheet(isPresented: $takingPhoto) {
            CameraPicker { data in
                takingPhoto = false
                if let data { onPhoto(data) }
            }
            .ignoresSafeArea()
        }
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                Text(title).font(Theme.Typography.text(14, .semibold))
            }
            .foregroundStyle(Theme.Colors.cream)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Theme.Colors.sage, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("scribe.\(symbol == "camera.fill" ? "photo" : "note")")
    }
}

/// A note about the place the rider is standing in.
struct NoteSheet: View {
    let title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Scribe", color: Theme.Colors.sageDeep)
            Text(title).font(Theme.Typography.voice(24, relativeTo: .title2)).foregroundStyle(Theme.Colors.ink)
            Text("Stop safely before writing.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            TextField("What is worth remembering here?", text: $text, axis: .vertical)
                .lineLimit(4...8)
                .textFieldStyle(CreamFieldStyle())
                .focused($focused)
            Spacer()
            Button("Save the note") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .buttonStyle(.primary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(22)
        .background(Theme.Colors.cream.ignoresSafeArea())
        .presentationDetents([.medium])
        .onAppear { focused = true }
    }
}

/// The camera, falling back to the photo library where there is none (the simulator).
struct CameraPicker: UIViewControllerRepresentable {
    let onResult: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onResult: (Data?) -> Void

        init(onResult: @escaping (Data?) -> Void) { self.onResult = onResult }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onResult(image?.jpegData(compressionQuality: 0.8))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onResult(nil)
        }
    }
}
