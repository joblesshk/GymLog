import SwiftUI
import PhotosUI
import ImageIO
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

                PhotosPicker(selection: $photoItem, matching: .images) {
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
            AddBodyMetricSheet(client: client, prefill: scanResult)
        }
        .sheet(isPresented: $showingManualFallback, onDismiss: { dismiss() }) {
            AddBodyMetricSheet(client: client)
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            await MainActor.run {
                isProcessing = false
                errorMessage = language.t("無法讀取這張照片。", "Couldn't read that photo.")
            }
            return
        }
        let orientation = Self.cgImageOrientation(from: source)

        let result = await Task.detached(priority: .userInitiated) { () -> Result<(tokenCount: Int, scan: InBodyScanResult), Error> in
            do {
                let tokens = try InBodyTextRecognizer.recognizeTokens(in: cgImage, orientation: orientation)
                guard !tokens.isEmpty else { return .success((0, InBodyScanResult())) }
                return .success((tokens.count, InBodyReportParser.parse(tokens: tokens)))
            } catch {
                return .failure(error)
            }
        }.value

        await MainActor.run {
            isProcessing = false
            switch result {
            case .failure(let error):
                errorMessage = error.localizedDescription
            case .success(let (tokenCount, scan)):
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

    /// Vision needs the photo's ORIGINAL orientation, not the pixel buffer
    /// pre-rotated -- `CGImageSourceCreateImageAtIndex` does not auto-apply
    /// EXIF orientation, so this has to be read and passed through
    /// explicitly or every non-`.up` photo gets nonsensical bounding boxes.
    private static func cgImageOrientation(from source: CGImageSource) -> CGImagePropertyOrientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawValue = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawValue) else {
            return .up
        }
        return orientation
    }
}
