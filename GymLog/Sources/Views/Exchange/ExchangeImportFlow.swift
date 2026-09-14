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
    /// 不再彈系統文件選擇器；nil 時走 `.fileImporter`（設置頁「從文件匯入」
    /// 的常規入口）。
    var pendingURL: URL?
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
    @State private var errorMessage: String?
    @State private var parsedPackage: ExchangePackage?
    @State private var previewResult: ExchangeImporter.PreviewResult?
    @State private var showingPreview = false

    /// §5.3 first-pass limit: files past this size are refused before ever
    /// being fully read into memory.
    private static let maxFileSize = ExchangeImporter.maxFileSize

    init(pendingURL: URL? = nil, onComplete: @escaping (Status) -> Void) {
        self.pendingURL = pendingURL
        self.onComplete = onComplete
        _showingFilePicker = State(initialValue: pendingURL == nil)
    }

    var body: some View {
        Color.clear
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [ExchangeUTType.gymlogShare]) { result in
                handleFileSelection(result)
            }
            .onAppear {
                if let pendingURL {
                    handleSelectedURL(pendingURL, needsSecurityScope: true)
                }
            }
            .overlay {
                if isProcessing {
                    ProgressView(language.t("解析中…", "Parsing…"))
                        .padding(16)
                        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .sheet(isPresented: $showingPreview, onDismiss: { onComplete(.cancelled); dismiss() }) {
                if let parsedPackage, let previewResult {
                    ExchangeImportPreviewView(
                        package: parsedPackage, preview: previewResult, clients: clients,
                        onConfirm: { targetClientID in commitImport(parsedPackage, targetClientID: targetClientID) },
                        onCancel: { showingPreview = false }
                    )
                }
            }
            .alert(language.t("匯入失敗", "Import Failed"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { let wasShowing = errorMessage != nil; errorMessage = nil; if wasShowing { onComplete(.cancelled); dismiss() } } }
            )) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func handleFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            onComplete(.cancelled)
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
        guard url.pathExtension.lowercased() == "gymlogshare" || url.pathExtension.lowercased() == "json" else {
            errorMessage = language.t("請選擇 .gymlogshare 分享檔案。", "Please choose a .gymlogshare file.")
            return
        }
        let didStartScope = needsSecurityScope && url.startAccessingSecurityScopedResource()
        isProcessing = true
        Task.detached(priority: .userInitiated) {
            defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let fileSizeValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                guard let fileSize = fileSizeValues?.fileSize, fileSize < ExchangeImportFlow.maxFileSize else {
                    await MainActor.run {
                        isProcessing = false
                        errorMessage = language.t("檔案過大，請確認選擇的是正確的分享檔案。", "File too large — please check you selected the right share file.")
                    }
                    return
                }
                let data = try Data(contentsOf: url)
                let package = try ExchangeImporter.parse(data)
                await MainActor.run {
                    isProcessing = false
                    computePreview(package)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = Self.describe(error, language: language)
                }
            }
        }
    }

    private func computePreview(_ package: ExchangePackage) {
        do {
            let preview = try ExchangeImporter.preview(package, in: modelContext)
            parsedPackage = package
            previewResult = preview
            showingPreview = true
        } catch {
            errorMessage = Self.describe(error, language: language)
        }
    }

    private func commitImport(_ package: ExchangePackage, targetClientID: String) {
        do {
            let result = try ExchangeImporter.commit(package, targetClientID: targetClientID, in: modelContext)
            onComplete(.success(result))
        } catch {
            onComplete(.failure(Self.describe(error, language: language)))
        }
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
