import Foundation

struct Segment: Codable, Identifiable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
}
struct RawPart: Decodable { var text: String; var segments: [Segment] }
struct Attempt: Codable, Identifiable {
    var id = UUID()
    var created = Date()
    var status = "queued"
    var message = "等待轉錄"
    var finished: Date?
    var language: String?
    var loadingMode = "fullFile"
    var diagnostics: [String] = []
}
struct EditRevision: Codable, Identifiable {
    var id = UUID()
    var created = Date()
    var rawAttemptID: UUID
    var parentEditID: UUID?
    var text: String
}
struct Recording: Codable, Identifiable {
    var id = UUID()
    var title: String
    var category = "未分類"
    var created = Date()
    var sourcePath: String
    var managedName: String
    var duration: Double
    var bytes: Int64
    var isVideo: Bool
    var contentSHA256: String?
    var audioSHA256: String?
    var archivedAt: Date?
    var sourcePaths: [String]?
    var importOrigin: String?
    var captureMode: String?
    var transcriptionLanguage: String?
    var recordedAt: Date?
    var recordedDateSource: String?
    var titleManuallyEdited: Bool?
    var categoryManuallyEdited: Bool?
    var metadataAttempts: [MetadataAttempt]?
    var trashedAt: Date?
    var purgeStartedAt: Date?
    var purgeError: String?
    var keepForever = false
    var attempts: [Attempt] = []
    var metadataSkipped: Bool?
    var currentRawID: UUID?
    var currentEditID: UUID?
    var currentMetadata: MetadataAttempt? { metadataAttempts?.last(where: { $0.rawAttemptID == currentRawID }) }
    var protectTitle: Bool {titleManuallyEdited ?? (title != URL(fileURLWithPath:sourcePath).deletingPathExtension().lastPathComponent)}
    var protectCategory: Bool {categoryManuallyEdited ?? (category != "未分類")}
    var namingDate: Date {recordedAt ?? created}
    var datePrefix: String {recordingDatePrefix(namingDate)}
    var status: String {
        let transcription = attempts.last?.status ?? "imported"
        if transcription != "completed" {return transcription}
        if metadataSkipped == true {return "completed"}
        guard let metadata = currentMetadata else {return "transcribed"}
        switch metadata.status {
        case "queued": return "organize_queued"
        case "running": return "organizing"
        case "failed": return "organization_failed"
        case "cancelled": return "organization_cancelled"
        default: return "completed"
        }
    }
    var isProcessing: Bool {["queued","running","organize_queued","organizing"].contains(status)}
    var isTranscribing: Bool {["queued","running"].contains(status)}
    var requiresAttention: Bool {["failed","cancelled","organization_failed","organization_cancelled","transcribed"].contains(status) || !(attempts.first(where:{$0.id == currentRawID})?.diagnostics.isEmpty ?? true)}
    var automaticMetadataLabel: String? {
        guard currentMetadata?.status == "completed" else {return nil}
        let title = currentMetadata?.titleApplied == true && !protectTitle
        let category = currentMetadata?.categoryApplied == true && !protectCategory
        if title && category {return "自動命名／分類"}
        if title {return "自動命名"}
        if category {return "自動分類"}
        return nil
    }
    var hasAutomaticMetadata: Bool {automaticMetadataLabel != nil}
    var statusLabel: String {
        switch status {
        case "queued": return "等待中"
        case "running": return "轉錄中"
        case "completed": return "已完成"
        case "transcribed": return "已轉錄"
        case "organize_queued": return "等待整理"
        case "organizing": return "整理標題與分類"
        case "organization_failed": return "已轉錄・整理失敗"
        case "organization_cancelled": return "已轉錄・整理已取消"
        case "failed": return "失敗"
        case "cancelled": return "已取消"
        default: return "未轉錄"
        }
    }
    var durationLabel: String { timeLabel(duration) }
}
func timeLabel(_ seconds: Double) -> String {
    let n = max(0, Int(seconds.isFinite ? seconds : 0))
    return n >= 3600 ? String(format:"%d:%02d:%02d", n/3600, n/60%60, n%60) : String(format:"%02d:%02d", n/60, n%60)
}
func searchFold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}
struct LibraryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = L(message) }
    var errorDescription: String? { message }
}
struct TranscriptDocument {
    var text: String
    var segments: [Segment]
    static func read(_ directory: URL) throws -> TranscriptDocument {
        let parts = try JSONDecoder().decode([RawPart].self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        return TranscriptDocument(text: parts.map(\.text).joined(separator: "\n"), segments: parts.flatMap(\.segments))
    }
    func audit(duration: Double) -> [String] {
        var issues: [String] = []
        var previous: Double?
        for (index, segment) in segments.enumerated() {
            let label = "第 \(index + 1) 段 · \(timeLabel(segment.start))"
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("\(label)：文字空白") }
            if !segment.start.isFinite || !segment.end.isFinite || segment.start < 0 || segment.end < segment.start || segment.end > duration + 0.25 { issues.append("\(label)：時間戳越界或起訖無效（\(segment.start)–\(segment.end) 秒）") }
            if let previous, segment.start < previous { issues.append("\(label)：起始時間倒退 \(String(format: "%.3f", previous - segment.start)) 秒") }
            previous = segment.start
        }
        return issues
    }
}

enum TranscriptionLanguage: String, CaseIterable {
    case auto, zh, en
    var label: String {
        switch self {case .auto:return "自動偵測"; case .zh:return "中文為主（可中英混用）"; case .en:return "英文為主"}
    }
}
struct PreviewSnapshot: Codable {
    var text: String
    var processedSeconds: Double
    var updatedAt: Double
    var isFinal: Bool
}

let recordingCategories = ["產品討論","技術討論","工作會議","個人想法","學習筆記","未分類"]
func recordingDatePrefix(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
    formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from:date)
}
struct MetadataAttempt: Codable, Identifiable {
    var id = UUID()
    var created = Date()
    var finished: Date?
    var rawAttemptID: UUID
    var status = "queued"
    var message = "等待命名分類"
    var proposedTitle: String?
    var proposedCategory: String?
    var model: String?
    var revision: String?
    var inputSHA256: String?
    var titleApplied: Bool?
    var categoryApplied: Bool?
}
struct MetadataModelResponse: Decodable {
    struct Result: Decodable {var title: String; var category: String}
    var result: Result
    var model: String
    var revision: String
    var inputSHA256: String
}

struct RemovalBatchResult {
    var succeeded: [UUID] = []
    var protected: [UUID] = []
    var failures: [String] = []
}
