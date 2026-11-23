import AVFoundation
import HaloAppCore
import HaloLens
import HaloUI
import SwiftUI

/// Live Lens: camera preview with hologram labels over recognized faces.
///
/// Thin view: all logic lives in `LensScreenModel` (HaloAppCore). The preview and the overlay share
/// one frame (the overlay is the preview's `.overlay`) and one video gravity, which
/// `LensOverlayGeometry` relies on to put each label on the right face.
struct LensScreen: View {
    @Bindable var model: LensScreenModel
    /// The session of the app's one camera (`AppEnvironment.captureSession`).
    let session: AVCaptureSession
    /// Confirmed people labeled on screen right now (`AppEnvironment.recognizedPeople`).
    let recognizedPeople: [LensRecognizedPerson]
    /// Moments may start / stay open (`AppEnvironment.momentsAllowed`): false on lock,
    /// background, kill switch or lens stop, which dismisses an open sheet.
    let momentsAllowed: Bool
    /// Builds the Moments model for the people on screen (`AppEnvironment.makeMomentsModel`).
    let makeMomentsModel: @MainActor ([LensRecognizedPerson]) -> MomentsModel
    /// Starts the session through the environment, so backgrounding and the kill switch know the
    /// lens is on screen (`AppEnvironment.lensAppeared`).
    let onAppear: () async -> Void
    let onDisappear: () -> Void
    /// The open Moment, built for the people on screen when the button was tapped.
    @State private var moment: MomentPresentation?

    /// Single source of truth for how the preview fits the frame; the overlay maps with the same.
    static let gravity: LensOverlayGeometry.VideoGravity = .resizeAspectFill

    var body: some View {
        CameraPreview(session: session, gravity: Self.gravity, isCapturing: model.isCapturing)
            .overlay {
                LensOverlayView(items: model.items, frame: model.frame, videoGravity: Self.gravity)
            }
            .ignoresSafeArea()
            .background(Color.black)
            .overlay(alignment: .top) { banners }
            .overlay(alignment: .bottomTrailing) { metricsControls }
            .overlay(alignment: .bottom) { momentButton }
            .sheet(item: $moment) { presentation in
                MomentsSheet(model: presentation.model) { moment = nil }
                    .presentationDetents([.medium, .large])
            }
            // Lock, background, kill switch, lens stopped: close the sheet (it stops dictation).
            .onChange(of: momentsAllowed) { _, allowed in
                if !allowed { moment = nil }
            }
            .task { await onAppear() }
            .onDisappear { onDisappear() }
            .task(id: model.showsMetrics) {
                guard model.showsMetrics else { return }
                while !Task.isCancelled {
                    await model.refreshMetrics()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 8) {
            if !model.recognitionAvailable {
                LensBanner(
                    systemImage: "exclamationmark.triangle",
                    text: "Recognition unavailable: the face model isn't installed in this build.")
            }
            if let error = model.cameraError {
                LensBanner(systemImage: "video.slash", text: error)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// "Moment": jot a note about the people on screen. Enabled only while at least one confirmed
    /// person is recognized.
    private var momentButton: some View {
        Button {
            moment = MomentPresentation(model: makeMomentsModel(recognizedPeople))
        } label: {
            Label("Moment", systemImage: "square.and.pencil")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!momentsAllowed || recognizedPeople.isEmpty)
        .padding(.bottom, 24)
        .accessibilityHint(Text("Add a note about the people in view"))
    }

    private var metricsControls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.showsMetrics, let metrics = model.metrics {
                LensMetricsPanel(metrics: metrics)
            }
            Toggle(isOn: $model.showsMetrics) {
                Image(systemName: "speedometer")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityLabel(Text("Debug metrics"))
        }
        .padding()
    }
}

private struct MomentPresentation: Identifiable {
    let id = UUID()
    let model: MomentsModel
}

private struct LensBanner: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
    }
}

/// Debug numbers only (no face data).
private struct LensMetricsPanel: View {
    let metrics: LensMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "fps %.1f", metrics.fps))
            ForEach(LensMetrics.Stage.allCases, id: \.self) { stage in
                Text(String(format: "%@ %.1f ms", stage.rawValue, metrics.latencyMilliseconds[stage] ?? 0))
            }
            Text("dropped \(metrics.droppedFrames)")
            Text("embeds \(metrics.embedsLastFrame)/frame, \(metrics.totalEmbeds) total")
            Text("errors det \(metrics.detectorErrors) emb \(metrics.embedderErrors)")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// `AVCaptureVideoPreviewLayer` sharing the `CameraSource` session.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let gravity: LensOverlayGeometry.VideoGravity
    /// Re-applies the portrait rotation once capture has started: the layer's connection only
    /// exists after `CameraSource` adds its input on the first start.
    let isCapturing: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = Self.avGravity(gravity)
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.videoGravity = Self.avGravity(gravity)
        view.applyPortraitRotation()
    }

    static func avGravity(_ gravity: LensOverlayGeometry.VideoGravity) -> AVLayerVideoGravity {
        switch gravity {
        case .resizeAspectFill: .resizeAspectFill
        case .resizeAspect: .resizeAspect
        case .resize: .resize
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // `layerClass` guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyPortraitRotation()
        }

        /// The app is portrait-only and `CameraSource` tags frames `.right` (rotate 90 degrees
        /// clockwise to make them upright), so the preview gets the matching 90 degree rotation.
        /// The overlay maps boxes in that same upright space.
        func applyPortraitRotation() {
            guard let connection = previewLayer.connection, connection.videoRotationAngle != 90,
                connection.isVideoRotationAngleSupported(90)
            else { return }
            connection.videoRotationAngle = 90
        }
    }
}
