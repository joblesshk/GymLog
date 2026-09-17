import SwiftUI
import PhotosUI
import UIKit
import GymLogKit

/// CONTRACT-M7.md §2.1: `PhotosPicker` → decode → on-device OCR
/// (`InBodyTextRecognizer`) → on-device parsing (`InBodyReportParser`) →
/// §2.7's "did enough body-composition data come out of this" gate → the review form
/// (`AddBodyMetricSheet(prefill:)`). Never saves anything itself -- a
/// successful scan's only effect is opening that form pre-filled; the
/// coach's own "保存"/"Save" tap is still what commits a `BodyMetric`.
///
/// Presented as its own sheet (not an invisible overlay): `PhotosPicker` is
/// a real tappable control, not a `.fileImporter`-style modifier that can
/// be driven purely by a bound `Bool`, so this needs an actual visible
/// prompt screen for the coach to tap.
struct InBodyScanFlow: View {
    let client: Client

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var photoItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var scanResult: InBodyScanResult?
    @State private var showingReviewForm = false
    @State private var errorMessage: String?
    @State private var showingManualFallback = false
    @State private var scanDiagnostics: InBodyScanDiagnostics?
    @State private var showingDiagnostics = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(DS.C.textLow)
                Text(language.t(
                    "選一張 InBody 報告照片，App 會在本機自動識別報告內容。",
                    "Choose an InBody report photo — the app will recognize it entirely on-device."
                ))
                .font(DS.F.body)
                .foregroundStyle(DS.C.textLow)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

                PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .current) {
                    Text(language.t("選擇照片", "Choose Photo"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.gymPrimary)
                .padding(.horizontal, 48)
                .disabled(isProcessing)

                Button {
                    showingManualFallback = true
                } label: {
                    Text(language.t("改為手動填寫", "Fill In Manually Instead"))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(DS.C.textLow)
                .disabled(isProcessing)

                Spacer()
                Spacer()
            }
            .padding()
            .background(DS.C.canvas)
            .navigationTitle(language.t("掃描報告照片", "Scan Report Photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .foregroundStyle(DS.C.textHi)
                }
                if scanDiagnostics != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingDiagnostics = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel(language.t("查看本機診斷", "View local diagnostics"))
                    }
                }
            }
            .overlay {
                if isProcessing {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView(language.t("識別中…", "Recognizing…"))
                            .padding(16)
                            .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            handleSelection(newItem)
        }
        .sheet(isPresented: $showingReviewForm, onDismiss: { dismiss() }) {
            if let scanResult, let diagnostics = scanDiagnostics {
                InBodyReviewContainer(client: client, scanResult: scanResult, diagnostics: diagnostics)
            }
        }
        .sheet(isPresented: $showingManualFallback, onDismiss: { dismiss() }) {
            AddBodyMetricSheet(client: client)
        }
        .sheet(isPresented: $showingDiagnostics) {
            if let diagnostics = scanDiagnostics {
                InBodyDiagnosticsSheet(diagnostics: diagnostics)
            }
        }
        .alert(
            language.t("無法識別", "Couldn't Recognize"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            if isNotAnInBodyReportError {
                Button(language.t("仍然手動填寫", "Fill In Manually")) {
                    errorMessage = nil
                    showingManualFallback = true
                }
                Button(language.t("重新選擇", "Choose Again"), role: .cancel) {}
            } else {
                Button(language.t("好", "OK"), role: .cancel) {}
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isNotAnInBodyReportError: Bool {
        errorMessage == language.t("沒有從這張照片裡識別到足夠的身體數據。", "Couldn't find enough body-composition data in this photo.")
    }

    private func handleSelection(_ item: PhotosPickerItem) {
        isProcessing = true
        Task {
            defer { photoItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        isProcessing = false
                        errorMessage = language.t("無法讀取這張照片。", "Couldn't read that photo.")
                    }
                    return
                }
                try await recognizeAndParse(data)
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = language.t("無法讀取這張照片。", "Couldn't read that photo.")
                }
            }
        }
    }

    private func recognizeAndParse(_ data: Data) async throws {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<InBodyScanOutput, Error> in
            do {
                return .success(try InBodyScanService.scan(data: data))
            } catch {
                return .failure(error)
            }
        }.value

        await MainActor.run {
            isProcessing = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let output):
                scanDiagnostics = output.diagnostics
                let tokenCount = output.diagnostics.tokenCount
                let scan = output.scan
                if scan.passedThreshold {
                    scanResult = scan
                    showingReviewForm = true
                } else if tokenCount == 0 {
                    errorMessage = language.t("這張照片裡沒有識別到文字，請確認照片清晰、報告完整入框。", "No text found. Make sure the whole report is in frame and in focus.")
                } else {
                    errorMessage = language.t("沒有從這張照片裡識別到足夠的身體數據。", "Couldn't find enough body-composition data in this photo.")
                }
            }
        }
    }
}

/// Keeps the local diagnostic affordance reachable while the review form is
/// presented. The scanner's underlying toolbar is covered by this sheet, so
/// the action is passed into the form itself after a successful scan.
private struct InBodyReviewContainer: View {
    let client: Client
    let scanResult: InBodyScanResult
    let diagnostics: InBodyScanDiagnostics

    @State private var showingDiagnostics = false

    var body: some View {
        AddBodyMetricSheet(
            client: client,
            prefill: scanResult,
            diagnosticsAction: { showingDiagnostics = true }
        )
            .sheet(isPresented: $showingDiagnostics) {
                InBodyDiagnosticsSheet(diagnostics: diagnostics)
            }
    }
}

private struct InBodyDiagnosticsSheet: View {
    let diagnostics: InBodyScanDiagnostics

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.t(
                        "複製詳細診斷會包含報告文字與數值，僅按下複製時寫入剪貼簿。",
                        "Copying details includes report text and values; they are written to the clipboard only when you press Copy Details."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
                    Text(diagnostics.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(language.t("本機診斷", "Local Diagnostics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("關閉", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("複製詳細診斷", "Copy Details")) {
                        UIPasteboard.general.string = diagnostics.detailedSummary
                    }
                }
            }
        }
    }
}
