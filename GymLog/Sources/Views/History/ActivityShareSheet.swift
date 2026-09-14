import SwiftUI
import UIKit

/// Thin `UIViewControllerRepresentable` bridge to the system share sheet
/// (`UIActivityViewController`) -- SwiftUI's `ShareLink` can't be triggered
/// programmatically from a `Menu` action the way a plain `Button` can, and
/// the export flow needs to generate the file first (on tap, not on every
/// menu render) before there's anything to share.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
