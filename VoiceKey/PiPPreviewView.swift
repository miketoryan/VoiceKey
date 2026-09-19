import SwiftUI
import UIKit

struct PiPPreviewView: UIViewRepresentable {
    let service: PictureInPictureService

    func makeUIView(context: Context) -> PiPPreviewHostView {
        PiPPreviewHostView(service: service)
    }

    func updateUIView(_ uiView: PiPPreviewHostView, context: Context) {
        service.attachPreview(to: uiView)
        service.layoutPreview(in: uiView.bounds)
    }
}

@MainActor
final class PiPPreviewHostView: UIView {
    private let service: PictureInPictureService

    init(service: PictureInPictureService) {
        self.service = service
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.cornerRadius = 14
        service.attachPreview(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        service.layoutPreview(in: bounds)
    }
}
