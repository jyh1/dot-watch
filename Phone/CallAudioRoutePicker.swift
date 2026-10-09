import AVKit
import SwiftUI

// Keep route discovery and selection in Apple's UI. Available destinations are
// determined by the active call session; a media receiver is not guaranteed to
// support two-way call audio.
struct CallAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .label
        picker.activeTintColor = .systemYellow
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
