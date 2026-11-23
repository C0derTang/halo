import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// QR rendering for the pairing payload (CoreImage `CIQRCodeGenerator`).
public enum PairingQR {
    /// Crisp, integer-scaled QR for `payload` on a white background with a 4-module quiet zone,
    /// or nil if generation fails.
    public static func image(for payload: String, scale: CGFloat = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let quiet = 4 * scale
        let canvas = scaled.extent.insetBy(dx: -quiet, dy: -quiet)
        let white = CIImage(color: .white).cropped(to: canvas)
        let composed = scaled.composited(over: white)
        return CIContext().createCGImage(composed, from: canvas)
    }
}

public struct PairingView: View {
    @State private var model: PairingModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: PairingModel) { _model = State(initialValue: model) }

    public var body: some View {
        List {
            Section {
                if let payload = model.payload {
                    if let image = model.qrImage {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Pairing QR code")
                    }
                    Text(payload).font(.footnote.monospaced()).textSelection(.enabled)
                    #if canImport(UIKit)
                        Button("Copy code") { UIPasteboard.general.string = payload }
                    #endif
                    Button("Re-pair…", role: .destructive) { model.requestRepair() }
                } else {
                    Button("Unlock to show pairing code") { Task { await model.unlock() } }
                }
            } footer: {
                Text(
                    "Use this code with halo-bridge on your Mac: halo-bridge pair <code>. It contains only a public key."
                )
            }
            if let error = model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Pair Mac")
        .confirmationDialog(
            "Re-pair?", isPresented: $model.isConfirmingRepair, titleVisibility: .visible
        ) {
            Button("Create new pairing key", role: .destructive) { model.confirmRepair() }
            Button("Cancel", role: .cancel) { model.cancelRepair() }
        } message: {
            Text("Digests from your Mac stop working until you pair it again with the new code.")
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.lock() } }
        .onDisappear { model.lock() }
    }
}
