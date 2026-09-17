import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import GymLogKit

/// P2 (2026-09-11) §5.2: 選文件（`.fileImporter` 兜底入口，或 `pendingURL`
/// 由 `.onOpenURL`/「從文件匯入」直接遞入）→ 解析並校驗 → 預覽（學員、日期、
/// 課次數、包含欄位、動作解析、衝突摘要）→ 選擇/新建目標學員 → 確認匯入 →
/// 結果摘要。鏡像 `BackupRestoreFlow` 的階段結構，但走獨立的
/// `ExchangeImporter`（不是 `BackupImporter`）。
struct ExchangeImportFlow: View {
    /// 非 nil 時直接用這個 URL（`.onOpenURL`/「從文件匯入」的隊列處理入口），
    /// 不再彈系統文件選擇器；nil 時走 `.fileImporter`。Settings 明確開啟
    /// JSON/純文字選項，系統接收到的文件則按副檔名和實際 bytes 驗證。
    var pendingURL: URL?
    var initialText: String?
    var allowsTextFiles: Bool
    let onComplete: (Status) -> Void

    enum Status {
        case success(ExchangeImporter.ImportResult)
        case failure(String)
        case cancelled
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Client.name) private var clients: [Client]
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @State private var showingFilePicker: Bool
    @State private var isProcessing = false
    @State private var parsedPackage: ExchangePackage?
    @State private var previewResult: ExchangeImporter.PreviewResult?
    @State private var didComplete = false
    @State private var didStartInput = false

    /// §5.3 first-pass limit: files past this size are refused before ever
    /// being fully read into memory.
    private static let maxFileSize = ExchangeImporter.maxFileSize

    init(pendingURL: URL? = nil, initialText: String? = nil, allowsTextFiles: Bool = false, onComplete: @escaping (Status) -> Void) {
        self.pendingURL = pendingURL
        self.initialText = initialText
        self.allowsTextFiles = allowsTextFiles
        self.onComplete = onComplete
        _showingFilePicker = State(initialValue: pendingURL == nil && initialText == nil)
    }

    var body: some View {
        Group {
            if let parsedPackage, let previewResult {
                ExchangeImportPreviewView(
                    package: parsedPackage, preview: previewResult, clients: clients,
                    onConfirm: { targetClientID in commitImport(parsedPackage, targetClientID: targetClientID) },
                    onCancel: {
                        self.parsedPackage = nil
                        self.previewResult = nil
                        complete(.cancelled)
                        dismiss()
                    }
                )
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if isProcessing {
                            ProgressView(language.t("解析中…", "Parsing…"))
                        } else {
                            Text(language.t("尚未載入分享資料。", "No share data has been loaded yet."))
                                .foregroundStyle(DS.C.textLow)
                        }
                        Button(language.t("取消", "Cancel")) {
                            complete(.cancelled)
                            dismiss()
                        }
                        .buttonStyle(.gymSecondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.C.canvas)
                    .navigationTitle(language.t("匯入分享", "Import Share"))
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: allowsTextFiles ? [ExchangeUTType.gymlogShare, .json, .plainText] : [ExchangeUTType.gymlogShare]) { result in
                handleFileSelection(result)
            }
            .onAppear {
                guard !didStartInput else { return }
                didStartInput = true
                if let initialText {
                    handleText(initialText)
                } else if let pendingURL {
                    handleSelectedURL(pendingURL, needsSecurityScope: true)
                }
            }
            .onDisappear {
                if !didComplete { complete(.cancelled) }
            }
    }

    private func handleFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            complete(.cancelled)
            dismiss()
        case .success(let url):
            handleSelectedURL(url, needsSecurityScope: true)
        }
    }

    /// `needsSecurityScope`: both the `.fileImporter` picker result AND a
    /// URL handed in from `.onOpenURL` are security-scoped resources on
    /// iOS -- `startAccessingSecurityScopedResource`/`stop...` bracket the
    /// whole read, and the bytes are copied out (not just read in place)
    /// before that scope closes, since parsing/preview can outlive a
    /// single synchronous read.
    private func handleSelectedURL(_ url: URL, needsSecurityScope: Bool) {
        let ext = url.pathExtension.lowercased()
        guard ext == "gymlogshare" || ext == "json" || ext == "txt" else {
            fail("請選擇 .gymlogshare、JSON 或純文字分享檔案。", "Choose a .gymlogshare, JSON, or plain-text GymLog share file.")
            return
        }
        let didStartScope = needsSecurityScope && url.startAccessingSecurityScopedResource()
        isProcessing = true
        Task.detached(priority: .userInitiated) {
            defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let fileSizeValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = fileSizeValues?.fileSize, fileSize > ExchangeImportFlow.maxFileSize {
                    await MainActor.run {
                        isProcessing = false
                        fail("檔案過大，請確認選擇的是正確的分享檔案。", "File too large — please check you selected the right share file.")
                    }
                    return
                }
                let data = try Data(contentsOf: url)
                guard data.count <= ExchangeImportFlow.maxFileSize else { throw ExchangeImporter.ImportError.invalidData("file is larger than \(ExchangeImportFlow.maxFileSize) bytes") }
                let package = try ExchangeTextCodec.decode(data: data)
                await MainActor.run {
                    isProcessing = false
                    computePreview(package)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                        fail(Self.describe(error, language: language))
                }
            }
        }
    }

    private func handleText(_ text: String) {
        isProcessing = true
        Task { @MainActor in
            do {
                let package = try ExchangeTextCodec.decode(text)
                isProcessing = false
                computePreview(package)
            } catch {
                isProcessing = false
                fail(Self.describe(error, language: language))
            }
        }
    }

    private func computePreview(_ package: ExchangePackage) {
        do {
            let preview = try ExchangeImporter.preview(package, in: modelContext)
            parsedPackage = package
            previewResult = preview
        } catch {
            fail(Self.describe(error, language: language))
        }
    }

    private func commitImport(_ package: ExchangePackage, targetClientID: String) {
        do {
            let result = try ExchangeImporter.commit(package, targetClientID: targetClientID, in: modelContext)
            complete(.success(result))
        } catch {
            complete(.failure(Self.describe(error, language: language)))
        }
        dismiss()
    }

    private func complete(_ status: Status) {
        guard !didComplete else { return }
        didComplete = true
        onComplete(status)
    }

    private func fail(_ zh: String, _ en: String? = nil) {
        complete(.failure(language == .zhHant ? zh : (en ?? zh)))
        dismiss()
    }

    private static func describe(_ error: Error, language: AppLanguage) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return language.t("這個檔案看起來不是有效的分享檔案。", "This file doesn't look like a valid share file.")
    }
}

/// The registered `.gymlogshare` document type -- see `project.yml`'s
/// `UTExportedTypeDeclarations` for the formal declaration this mirrors.
/// Falls back to a plain by-extension type if, for any reason, the app's
/// own declared type isn't resolvable at runtime (e.g. running from a
/// context where Info.plist wasn't merged the way expected) -- the
/// `.fileImporter` picker still works either way, just without the nicer
/// registered type name.
enum ExchangeUTType {
    static let gymlogShare: UTType = UTType(exportedAs: "org.example.gymlog.share")
}
