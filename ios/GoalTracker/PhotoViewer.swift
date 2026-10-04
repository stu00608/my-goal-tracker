import SwiftUI
import UIKit

@MainActor struct PhotoViewer: View {
    let photos: [Data]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int

    init(photos: [Data], initialIndex: Int) {
        self.photos = photos
        _selectedIndex = State(initialValue: min(max(initialIndex, 0), max(photos.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if photos.isEmpty {
                ContentUnavailableView(L.text("No photos"), systemImage: "photo")
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(photos.indices, id: \.self) { index in
                        ZoomablePhoto(data: photos[index], isSelected: selectedIndex == index)
                            .accessibilityLabel(pageLabel(index))
                            .accessibilityIdentifier("photo.page.\(index)")
                            .tag(index)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Label(L.text("Close"), systemImage: "xmark").padding(12) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("photo.close")
            }.padding(.horizontal)
        }
        .safeAreaInset(edge: .bottom) {
            if !photos.isEmpty {
                HStack {
                    Button { selectedIndex -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .disabled(selectedIndex == 0)
                        .accessibilityLabel(L.text("Previous photo"))
                        .accessibilityIdentifier("photo.previous")
                    Spacer()
                    Text(pageLabel(selectedIndex)).font(.callout.monospacedDigit())
                    Spacer()
                    Button { selectedIndex += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .disabled(selectedIndex >= photos.count - 1)
                        .accessibilityLabel(L.text("Next photo"))
                        .accessibilityIdentifier("photo.next")
                }.padding(.horizontal)
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(.white)
    }

    private func pageLabel(_ index: Int) -> String {
        String(format: L.text("Photo %lld of %lld"), locale: L.locale, Int64(index + 1), Int64(photos.count))
    }
}

@MainActor private struct ZoomablePhoto: UIViewRepresentable {
    let data: Data
    let isSelected: Bool

    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.setPhoto(data)
        if !isSelected { view.setZoomScale(view.minimumZoomScale, animated: false) }
    }
}

@MainActor private final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var photoData: Data?
    private var fittedBounds = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityHint = L.text("Pinch to zoom. Drag to pan.")
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L.text("Zoom in"), target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: L.text("Zoom out"), target: self, selector: #selector(zoomOut))
        ]
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        panGestureRecognizer.isEnabled = false
        updateZoomAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPhoto(_ data: Data) {
        guard photoData != data else { return }
        photoData = data
        imageView.image = UIImage(data: data)
        accessibilityLabel = imageView.image == nil ? L.text("Could not read this photo. Try a different image.") : nil
        fittedBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateZoomAccessibility()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if fittedBounds != bounds.size, let image = imageView.image, image.size.width > 0, image.size.height > 0 {
            fittedBounds = bounds.size
            setZoomScale(minimumZoomScale, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            contentOffset = .zero
        }
        centerPhoto()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Let the outer native pager own one-finger swipes while the image is fitted.
        panGestureRecognizer.isEnabled = zoomScale > minimumZoomScale + 0.01
        centerPhoto()
        updateZoomAccessibility()
    }
    private func updateZoomAccessibility() {
        accessibilityValue = Double(zoomScale).formatted(.percent.precision(.fractionLength(0)).locale(L.locale))
    }
    private func centerPhoto() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
        if zoomScale == minimumZoomScale {
            let offset = CGPoint(x: -horizontal, y: -vertical)
            if contentOffset != offset { contentOffset = offset }
        }
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 { setZoomScale(minimumZoomScale, animated: true) }
        else {
            let scale = min(3, maximumZoomScale)
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
    @objc private func zoomIn() -> Bool {
        setZoomScale(min(zoomScale * 2, maximumZoomScale), animated: true)
        return true
    }
    @objc private func zoomOut() -> Bool {
        setZoomScale(max(zoomScale / 2, minimumZoomScale), animated: true)
        return true
    }
}
