import SwiftUI
import UIKit
import GymLogKit

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

/// Keeps file sharing and chat sharing as explicit choices. A chat app often
/// drops an attachment, while Files/AirDrop should receive the real package.
struct ExchangeShareChoiceSheet: View {
    let fileURL: URL
    let text: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showingActivity = false
    @State private var activityItems: [Any] = []

    var body: some View {
        NavigationStack {
            List {
                Button {
                    activityItems = [fileURL]
                    showingActivity = true
                } label: {
                    Label(language.t("分享 .gymlogshare 檔案", "Share .gymlogshare File"), systemImage: "doc.fill")
                }
                Button {
                    activityItems = [text]
                    showingActivity = true
                } label: {
                    Label(language.t("分享可匯入聊天文字", "Share Importable Chat Text"), systemImage: "message.fill")
                }
            }
            .navigationTitle(language.t("分享方式", "Share Method"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingActivity, onDismiss: { activityItems = [] }) {
            ActivityShareSheet(activityItems: activityItems)
        }
    }
}
