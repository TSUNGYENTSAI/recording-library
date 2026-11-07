import Foundation
import Combine
import AVFoundation
import Darwin
import CryptoKit


enum LibraryJobKind {case transcription, organization}
struct LibraryJob {let id: UUID; let kind: LibraryJobKind}

struct ImportOutcome { let recording: Recording; let reused: Bool; var restored = false }

actor ImportGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func lock() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func unlock() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
func contentDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount:1024*1024), !data.isEmpty { hasher.update(data:data) }
    return hasher.finalize().map {String(format:"%02x",$0)}.joined()
}

@MainActor final class ProcessRunner {
    private var process: Process?
    private var cancelled = false
    func cancel() {
        cancelled = true
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak process] in
            if process?.isRunning == true { kill(pid, SIGKILL) }
        }
    }
    func run(_ executable: String, _ arguments: [String], environment: [String:String]? = nil, log: URL? = nil, onLine: (@MainActor (String) -> Void)? = nil) async throws -> String {
        if cancelled { throw CancellationError() }
        let child = Process(); process = child
        let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.standardOutput = pipe; child.standardError = pipe
        child.environment = environment ?? ProcessInfo.processInfo.environment
        child.standardInput = FileHandle.nullDevice
        if let log { FileManager.default.createFile(atPath: log.path, contents: nil) }
        try child.run()
        let result: (String, Int32) = await Task.detached(priority: .utility) {
            let handle = log.flatMap { try? FileHandle(forWritingTo: $0) }
            defer { try? handle?.close() }
            var all = Data(); var pending = ""
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                all.append(data); try? handle?.write(contentsOf: data)
                pending += String(decoding: data, as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<newline]); pending.removeSubrange(...newline)
                    if let onLine { await onLine(line) }
                }
            }
            child.waitUntilExit()
            if !pending.isEmpty, let onLine { await onLine(pending) }
            return (String(decoding: all, as: UTF8.self), child.terminationStatus)
        }.value
        process = nil
        if cancelled { throw CancellationError() }
        guard result.1 == 0 else { throw LibraryError("背景程序結束（\(result.1)）。\n" + String(result.0.suffix(2400))) }
        return result.0
    }
}

@MainActor final class LibraryEngine: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published private(set) var configuration: ModelConfiguration
    @Published var trashedRecordings: [Recording] = []
    @Published var trashActivity: String?
    @Published var isRemoving = false
    private var pendingTrash = Set<UUID>()
    @Published var errorMessage: String?
    @Published var importMessage: String?
    @Published var activeID: UUID?
    @Published var activity = ""
    @Published var activeSince: Date?
    @Published var isImporting = false
    @Published var importNotice: String?
    @Published var livePreviews: [UUID:PreviewSnapshot] = [:]
    private let importGate = ImportGate()
    private var importBatchCount = 0
    let store: LibraryStore
    let helper: URL
    let textWorker: URL
    var textPython: URL
    private var queue: [LibraryJob] = []
    private var runner: ProcessRunner?
    private var worker: Task<Void,Never>?
    private var cancelled = Set<UUID>()
    private var stopping = false
    static let networkProfile = "(version 1) (allow default) (deny network*)"
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RecordingLibrary", isDirectory: true)
    }
    init(root: URL, helper: URL, recover: Bool = true, textWorker: URL? = nil, textPython: URL? = nil, configuration: ModelConfiguration? = nil) throws {
        self.store = try LibraryStore(root: root); self.helper = helper
        let selectedConfiguration = try configuration ?? ModelConfiguration.load(root:root)
        self.configuration = selectedConfiguration
        let resources = helper.deletingLastPathComponent().deletingLastPathComponent()
        let infoURL = resources.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = (try? Data(contentsOf:infoURL)).flatMap {try? PropertyListSerialization.propertyList(from:$0,format:nil) as? [String:Any]}
        let name = info?["RecordingLibraryTextWorker"] as? String ?? "local_text.py"
        self.textWorker = textWorker ?? resources.appendingPathComponent("TextModel/" + name)
        self.textPython = textPython ?? URL(fileURLWithPath:selectedConfiguration.pythonPath)
        if recover {
            for var record in try store.list() {
                for i in record.attempts.indices where ["running", "queued"].contains(record.attempts[i].status) {
                    record.attempts[i].status = "failed"
                    record.attempts[i].message = "上次工作已中斷；可重試，先前結果仍保留。"
                    record.attempts[i].finished = Date()
                }
                for i in (record.metadataAttempts ?? []).indices where ["running","queued"].contains(record.metadataAttempts![i].status) {
                    record.metadataAttempts![i].status = "failed"
                    record.metadataAttempts![i].message = "上次命名分類已中斷，可只重試整理。"
                    record.metadataAttempts![i].finished = Date()
                }
                try store.save(record)
            }
        }
        try reload()
    }
    func updateConfiguration(_ value:ModelConfiguration) throws {
        guard !isBusy else {throw LibraryError("請等目前背景工作停止後再變更模型設定。")}
        try value.save(root:store.root);configuration = value;textPython = URL(fileURLWithPath:value.pythonPath)
    }
    func reload() throws {recordings = try store.list(); trashedRecordings = try store.list(onlyTrashed:true)}
    func record(_ id: UUID, includeTrashed: Bool = false) throws -> Recording {
        guard let record = try store.lookup(id), includeTrashed || record.trashedAt == nil else { throw LibraryError("找不到錄音") }
        return record
    }
    private func save(_ record: Recording) throws { try store.save(record); try reload() }
    func search(_ query: String, trash: Bool = false) -> [Recording] {
        do { return try store.list(query:query,onlyTrashed:trash) } catch { errorMessage = error.localizedDescription; return [] }
    }
    func metadata(_ url: URL) async throws -> (Double, Bool, Date?, String?) {
        let probe = configuration.ffprobePath
        guard FileManager.default.isExecutableFile(atPath: probe) else { throw LibraryError("找不到 FFprobe：\(probe)。此版本沿用本機 FFmpeg 安裝。") }
        let output = try await ProcessRunner().run("/usr/bin/sandbox-exec", ["-p", Self.networkProfile, probe, "-v", "error", "-show_entries", "format=duration:format_tags=creation_time,date,com.apple.quicktime.creationdate:stream=codec_type:stream_tags=creation_time", "-of", "json", url.path])
        guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]], streams.contains(where: { $0["codec_type"] as? String == "audio" }),
              let format = json["format"] as? [String: Any], let string = format["duration"] as? String, let duration = Double(string), duration.isFinite, duration > 0 else { throw LibraryError("檔案沒有可讀取的音軌或有效時長。") }
        let tags = format["tags"] as? [String:String] ?? [:]
        let dates = [tags["com.apple.quicktime.creationdate"],tags["creation_time"],tags["date"]] + streams.map {($0["tags"] as? [String:String])?["creation_time"]}
        let recordedAt = dates.compactMap {$0}.compactMap {Self.parseRecordingDate($0)}.first
        return (duration, streams.contains { $0["codec_type"] as? String == "video" },recordedAt,recordedAt == nil ? nil : "媒體內嵌日期")
    }
    static func parseRecordingDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let date = iso.date(from:value) {return date}
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from:value) {return date}
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        if let date = formatter.date(from:value) {return date}
        guard value.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil else {return nil}
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.date(from:value)
    }
    func digest(_ url: URL) async throws -> String {
        try await Task.detached(priority:.utility) { try contentDigest(url) }.value
    }
    func audioDigest(_ url: URL) async throws -> String {
        let output = try await ProcessRunner().run("/usr/bin/sandbox-exec",["-p",Self.networkProfile,configuration.ffmpegPath,"-nostdin","-v","error","-i",url.path,"-map","0:a:0","-c:a","copy","-f","hash","-hash","sha256","-"])
        guard let line = output.split(separator:"\n").last, line.hasPrefix("SHA256="), line.count == 71 else {throw LibraryError("無法確認音訊內容指紋，尚未歸檔。")}
        return String(line.dropFirst(7))
    }
    func writeArchiveManifest(_ record: Recording) throws {
        let manifest: [String:Any] = ["recordingID":record.id.uuidString,"managedFile":record.managedName,"sha256":record.contentSHA256 ?? "","audioSHA256":record.audioSHA256 ?? "","bytes":record.bytes,"verifiedAt":record.archivedAt.map { ISO8601DateFormatter().string(from:$0) } ?? "","sourcePaths":record.sourcePaths ?? [record.sourcePath],"origin":record.importOrigin ?? "本地檔案"]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:store.folder(record).appendingPathComponent("archive.json"),options:.atomic)
    }
    @discardableResult func importFile(_ source: URL, ownedStagingDirectory: URL? = nil) async throws -> Recording {
        try await importOutcome(source,ownedStagingDirectory:ownedStagingDirectory).recording
    }
    private func importOutcome(_ source: URL, ownedStagingDirectory: URL?) async throws -> ImportOutcome {
        await importGate.lock()
        do {
            let result = try await importUniqueFile(source,ownedStagingDirectory:ownedStagingDirectory)
            await importGate.unlock(); return result
        } catch {await importGate.unlock(); throw error}
    }
    private func importUniqueFile(_ originalURL: URL, ownedStagingDirectory: URL?) async throws -> ImportOutcome {
        let access = originalURL.startAccessingSecurityScopedResource()
        defer {if access {originalURL.stopAccessingSecurityScopedResource()}}
        let source = originalURL.resolvingSymlinksInPath().standardizedFileURL
        let isOwnedIncoming = ownedStagingDirectory.map { source.path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") } ?? false
        guard try source.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else {throw LibraryError("請選擇本地音訊或影片檔案。")}
        let allowed = ["m4a","mp3","wav","aac","aiff","aif","flac","caf","ogg","opus","mp4","mov","m4v","mkv","webm","avi"]
        guard allowed.contains(source.pathExtension.lowercased()) else {throw LibraryError("不支援這個檔案格式：\(source.pathExtension)")}
        importMessage = "檢查音軌與歸檔內容：\(source.lastPathComponent)"
        let (duration,isVideo,recordedAt,dateSource) = try await metadata(source)
        let bytes = (try FileManager.default.attributesOfItem(atPath:source.path)[.size] as? NSNumber)?.int64Value ?? 0
        let incomingHash = try await digest(source)
        let incomingAudio = isVideo ? nil : try await audioDigest(source)
        // Migrate identities lazily from owned media; never touch or delete an old source file.
        for snapshot in try store.list(includeTrashed:true) {
            var candidate = try record(snapshot.id,includeTrashed:true)
            let managed = store.media(candidate)
            let exists = FileManager.default.fileExists(atPath:managed.path)
            if candidate.contentSHA256 == nil, exists, candidate.bytes == bytes || (!candidate.isVideo && incomingAudio != nil) {
                let hash = try await digest(managed)
                let audio = candidate.isVideo ? nil : try await audioDigest(managed)
                candidate = try record(snapshot.id,includeTrashed:true)
                candidate.contentSHA256 = hash; candidate.audioSHA256 = audio; candidate.archivedAt = Date()
                candidate.sourcePaths = candidate.sourcePaths ?? [candidate.sourcePath]
                try writeArchiveManifest(candidate); try save(candidate)
            }
            let matchesFile = candidate.contentSHA256 == incomingHash
            let matchesAudio = !candidate.isVideo && !isVideo && incomingAudio != nil && candidate.audioSHA256 == incomingAudio
            guard matchesFile || matchesAudio else {continue}
            guard !pendingTrash.contains(candidate.id) else {throw LibraryError("此錄音正在移到垃圾桶，請稍後再匯入。")}
            guard candidate.purgeStartedAt == nil else {throw LibraryError("垃圾桶中的相同錄音已開始永久刪除，請先完成刪除，再重新匯入。")}
            if exists {
                guard try await digest(managed) == candidate.contentSHA256 else {throw LibraryError("找到同一錄音，但歸檔副本已被外部修改。請先檢查該項目，這次沒有建立重複副本。")}
            } else {
                guard candidate.trashedAt == nil else {throw LibraryError("垃圾桶中的媒體副本已遺失，請先檢查該項目。")}
                let name = "source.\(source.pathExtension.lowercased())"
                let destination = store.folder(candidate).appendingPathComponent(name)
                try FileManager.default.createDirectory(at:store.folder(candidate),withIntermediateDirectories:true)
                try await Task.detached(priority:.utility) {try FileManager.default.copyItem(at:source,to:destination)}.value
                guard try await digest(destination) == incomingHash else {try? FileManager.default.removeItem(at:destination); throw LibraryError("修復歸檔副本時校驗不符。")}
                candidate = try record(snapshot.id,includeTrashed:true); candidate.managedName = name; candidate.bytes = bytes; candidate.contentSHA256 = incomingHash
            }
            // Refresh metadata after awaits so an ongoing transcription or rename is not overwritten.
            var latest = try record(candidate.id,includeTrashed:true)
            let wasTrashed = latest.trashedAt != nil
            if wasTrashed {latest = try store.restore(latest)}
            latest.managedName = candidate.managedName; latest.bytes = candidate.bytes; latest.contentSHA256 = candidate.contentSHA256; latest.audioSHA256 = candidate.audioSHA256
            latest.archivedAt = Date()
            if latest.recordedAt == nil, let recordedAt {
                latest.recordedAt = recordedAt; latest.recordedDateSource = dateSource
                if !latest.protectTitle, let theme = latest.currentMetadata?.proposedTitle {latest.title = latest.datePrefix + " " + theme}
            }
            var paths = latest.sourcePaths ?? [latest.sourcePath]
            if !isOwnedIncoming, !paths.contains(source.path) {paths.append(source.path)}
            latest.sourcePaths = paths
            try writeArchiveManifest(latest); try save(latest)
            return ImportOutcome(recording:latest,reused:true,restored:wasTrashed)
        }
        var item = Recording(title:source.deletingPathExtension().lastPathComponent,sourcePath:source.path,managedName:"source.\(source.pathExtension.lowercased())",duration:duration,bytes:bytes,isVideo:isVideo)
        item.recordedAt = recordedAt; item.recordedDateSource = dateSource ?? "匯入日期"
        item.titleManuallyEdited = false; item.categoryManuallyEdited = false
        item.contentSHA256 = incomingHash; item.audioSHA256 = incomingAudio
        item.sourcePaths = isOwnedIncoming ? [] : [source.path]
        item.importOrigin = isOwnedIncoming ? "應用程式拖曳匯出" : "本地檔案"
        let directory = store.folder(item); let destination = store.media(item)
        let canMove = isOwnedIncoming
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            importMessage = "正在歸檔：\(source.lastPathComponent)"
            try await Task.detached(priority:.utility) {
                if canMove {try FileManager.default.moveItem(at:source,to:destination)}
                else {try FileManager.default.copyItem(at:source,to:destination)}
            }.value
            guard try await digest(destination) == incomingHash else {throw LibraryError("歸檔後的檔案校驗不符，未建立 Library 項目。請重試。")}
            item.archivedAt = Date()
            try writeArchiveManifest(item); try save(item)
            return ImportOutcome(recording:item,reused:false)
        } catch {try? FileManager.default.removeItem(at:directory); throw error}
    }
    @discardableResult func importURLs(_ urls: [URL], autoTranscribe: Bool = true, ownedStagingDirectory: URL? = nil, language: String = "auto") async -> [UUID] {
        // Accept another drop while a file promise is resolving; the gate serializes writes.
        var ids: [UUID] = []; var failures: [String] = []; var created = 0; var reused = 0; var restored = 0
        importBatchCount += 1; isImporting = true
        defer {importBatchCount -= 1; isImporting = importBatchCount > 0; if !isImporting {importMessage = nil}; if let directory = ownedStagingDirectory {try? FileManager.default.removeItem(at:directory)}}
        for url in urls {
            do {
                let outcome = try await importOutcome(url,ownedStagingDirectory:ownedStagingDirectory)
                let item = outcome.recording
                ids.append(item.id)
                if outcome.reused {reused += 1} else {created += 1}
                if outcome.restored {restored += 1}
                // Importing an existing completed/failed recording must not start a new attempt.
                if autoTranscribe, item.status == "imported" {try enqueue(item.id,language:language)}
                else if autoTranscribe, item.status == "transcribed", configuration.automaticMetadata {try enqueueOrganization(item.id)}
            } catch {failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")}
        }
        if !ids.isEmpty {importNotice = "已歸檔 \(created) 份・已存在 \(reused) 份（未重複複製）" + (restored > 0 ? "・從垃圾桶復原 \(restored) 份" : "")}
        if !failures.isEmpty {errorMessage = failures.joined(separator:"\n\n")}
        return ids
    }
    func enqueue(_ id: UUID, language: String? = nil) throws {
        guard !stopping else { return }
        guard !pendingTrash.contains(id) else {throw LibraryError("此錄音正在移到垃圾桶。")}
        var record = try record(id)
        guard activeID != id else { throw LibraryError("工作仍在停止中，請稍候再重試。") }
        guard !record.isProcessing else { return }
        let selectedLanguage = language ?? record.transcriptionLanguage ?? "auto"
        guard TranscriptionLanguage(rawValue:selectedLanguage) != nil else {throw LibraryError("不支援的轉錄語言")}
        record.transcriptionLanguage = selectedLanguage; record.metadataSkipped = false
        var attempt = Attempt(); attempt.language = selectedLanguage
        record.attempts.append(attempt)
        livePreviews.removeValue(forKey:id)
        try save(record); cancelled.remove(id); queue.append(LibraryJob(id:id,kind:.transcription)); pump()
    }
    private func pump() {
        guard worker == nil, !stopping, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        worker = Task { [weak self] in
            guard let self else { return }
            if !self.cancelled.contains(job.id), !self.pendingTrash.contains(job.id) {
                switch job.kind {case .transcription: await self.transcribe(job.id); case .organization: await self.organize(job.id,createAttempt:false)}
            }
            self.worker = nil; self.activeID = nil; self.activeSince = nil; self.activity = ""; self.runner = nil
            self.pump()
        }
    }
    private func transcribe(_ id: UUID) async {
        activeID = id; activeSince = Date(); activity = "準備轉錄"
        do {
            var item = try record(id)
            guard let attemptID = item.attempts.last?.id else { return }
            let directory = store.attemptFolder(item, attemptID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let job = ProcessRunner(); runner = job
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw LibraryError("找不到隨 App 提供的轉錄工具。") }
            guard FileManager.default.fileExists(atPath:configuration.whisperModelPath+"/AudioEncoder.mlmodelc"), FileManager.default.fileExists(atPath:configuration.tokenizerPath+"/tokenizer.json") else {throw LibraryError("請在設定中選擇本機 Whisper 模型與 tokenizer，或依安裝說明下載推薦模型。")}
            item.attempts[item.attempts.count-1].status = "running"; item.attempts[item.attempts.count-1].message = "準備音訊"
            try save(item)
            var audio = store.media(item)
            let workingAudio = directory.appendingPathComponent("working-audio.wav")
            defer { if FileManager.default.fileExists(atPath: workingAudio.path) { try? FileManager.default.removeItem(at: workingAudio) } }
            // Convert video and audio formats AVAudioFile may not decode. The managed source stays intact.
            if item.isVideo || ["flac","ogg","opus"].contains(audio.pathExtension.lowercased()) {
                activity = "擷取音軌"
                audio = directory.appendingPathComponent("working-audio.wav")
                _ = try await job.run("/usr/bin/sandbox-exec", ["-p", Self.networkProfile, configuration.ffmpegPath, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", store.media(item).path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio.path], log: directory.appendingPathComponent("extraction.log"))
            }
            activity = "載入本地模型"
            var environment = ProcessInfo.processInfo.environment
            environment["RECORDING_LIBRARY_MODEL_DIR"] = configuration.whisperModelPath
            environment["RECORDING_LIBRARY_TOKENIZER_DIR"] = configuration.tokenizerPath
            environment.removeValue(forKey: "VALIDATION_INCREMENTAL"); environment.removeValue(forKey: "VALIDATION_PROMPT")
            let language = item.attempts.last?.language ?? "auto"
            if ["zh","en"].contains(language) {environment["VALIDATION_LANGUAGE"] = language}
            else {environment.removeValue(forKey:"VALIDATION_LANGUAGE")}
            _ = try await job.run("/usr/bin/sandbox-exec", ["-p", Self.networkProfile, helper.path, audio.path, directory.path], environment: environment, log: directory.appendingPathComponent("process.log")) { [weak self] line in
                guard let self, self.activeID == id else { return }
                if line == "RL_PREVIEW" {
                    if let data = try? Data(contentsOf:directory.appendingPathComponent("preview.json")), let snapshot = try? JSONDecoder().decode(PreviewSnapshot.self,from:data) {self.livePreviews[id] = snapshot}
                }
                if line.contains("Model loaded") { self.activity = "正在轉錄" }
                else if line.contains("Still transcribing") { self.activity = "正在轉錄" }
            }
            if cancelled.contains(id) { throw CancellationError() }
            let document = try TranscriptDocument.read(directory)
            guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError("沒有辨識到可用文字。可檢查音軌或重試；本次原始輸出仍保留。") }
            let issues = document.audit(duration: item.duration)
            try JSONEncoder().encode(issues).write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
            var latest = try record(id)
            guard let index = latest.attempts.firstIndex(where: { $0.id == attemptID }) else { throw LibraryError("找不到轉錄工作紀錄") }
            latest.attempts[index].status = "completed"; latest.attempts[index].finished = Date()
            latest.attempts[index].diagnostics = issues
            latest.attempts[index].message = issues.isEmpty ? "轉錄完成" : "轉錄完成，有 \(issues.count) 項診斷"
            latest.currentRawID = attemptID; latest.metadataSkipped = !configuration.automaticMetadata
            try save(latest)
            if configuration.automaticMetadata {await organize(id,createAttempt:true)}
        } catch {
            do {
                var latest = try record(id)
                if !latest.attempts.isEmpty {
                    let i = latest.attempts.count-1
                    latest.attempts[i].status = cancelled.contains(id) || error is CancellationError ? "cancelled" : "failed"
                    latest.attempts[i].message = latest.attempts[i].status == "cancelled" ? "工作已取消，可重試。" : error.localizedDescription
                    latest.attempts[i].finished = Date(); try save(latest)
                }
            } catch { errorMessage = "無法儲存工作狀態：\(error.localizedDescription)" }
        }
    }
    private func appendMetadataAttempt(_ id: UUID) throws {
        var item = try record(id)
        guard let rawID = item.currentRawID else {throw LibraryError("尚無可整理的原始逐字稿。")}
        var attempts = item.metadataAttempts ?? []
        attempts.append(MetadataAttempt(rawAttemptID:rawID))
        item.metadataAttempts = attempts; item.metadataSkipped = false; try save(item)
    }
    func enqueueOrganization(_ id: UUID) throws {
        guard !stopping else {return}
        guard !pendingTrash.contains(id) else {throw LibraryError("此錄音正在移到垃圾桶。")}
        let item = try record(id)
        guard activeID != id, !item.isProcessing else {throw LibraryError("此錄音正在處理，請稍候。")}
        try appendMetadataAttempt(id)
        cancelled.remove(id); queue.append(LibraryJob(id:id,kind:.organization)); pump()
    }
    private func organize(_ id: UUID, createAttempt: Bool) async {
        activeID = id; if activeSince == nil {activeSince = Date()}; activity = "整理標題與分類"
        var operationID: UUID?
        do {
            if createAttempt {try appendMetadataAttempt(id)}
            var item = try record(id)
            guard let attempt = item.metadataAttempts?.last, let rawID = item.currentRawID, attempt.rawAttemptID == rawID else {throw LibraryError("找不到對應的原始逐字稿。")}
            operationID = attempt.id
            let index = item.metadataAttempts!.count-1
            item.metadataAttempts![index].status = "running"; item.metadataAttempts![index].message = "本機模型正在命名與分類"
            try save(item)
            let folder = store.metadataFolder(item,attempt.id)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let input = store.attemptFolder(item,rawID).appendingPathComponent("transcript.txt")
            let inputHash = try await digest(input)
            if cancelled.contains(id) {throw CancellationError()}
            let python = textPython
            guard FileManager.default.isExecutableFile(atPath:python.path), FileManager.default.fileExists(atPath:textWorker.path) else {throw LibraryError("找不到本機文字模型執行環境，請確認 Qwen 安裝仍在。")}
            let job = ProcessRunner(); runner = job
            let output = folder.appendingPathComponent("result.json")
            _ = try await job.run("/usr/bin/sandbox-exec",["-p",Self.networkProfile,python.path,textWorker.path,"--model-path",configuration.textModelPath,"--task","metadata","--input",input.path,"--output",output.path,"--categories"] + recordingCategories, log:folder.appendingPathComponent("process.log")) { [weak self] line in
                if line.contains("\"event\": \"outline\"") {self?.activity = "分段整理主題"}
            }
            if cancelled.contains(id) {throw CancellationError()}
            let response = try JSONDecoder().decode(MetadataModelResponse.self,from:Data(contentsOf:output))
            let theme = response.result.title.components(separatedBy:.whitespacesAndNewlines).filter {!$0.isEmpty}.joined(separator:" ")
            guard theme.count >= 6, theme.count <= 40, !recordingCategories.contains(theme), recordingCategories.contains(response.result.category), response.inputSHA256 == inputHash else {throw LibraryError("模型輸出未通過標題、分類或來源校驗，可只重試整理。")}
            var latest = try record(id)
            guard latest.currentRawID == rawID, let i = latest.metadataAttempts?.firstIndex(where:{$0.id == attempt.id}) else {throw LibraryError("原始逐字稿已更新，本次建議尚未套用。")}
            let applyTitle = !latest.protectTitle
            let applyCategory = !latest.protectCategory
            if applyTitle {latest.title = latest.datePrefix + " " + theme; latest.titleManuallyEdited = false}
            if applyCategory {latest.category = response.result.category; latest.categoryManuallyEdited = false}
            latest.metadataAttempts![i].status = "completed"; latest.metadataAttempts![i].finished = Date()
            latest.metadataAttempts![i].proposedTitle = theme; latest.metadataAttempts![i].proposedCategory = response.result.category
            latest.metadataAttempts![i].model = response.model; latest.metadataAttempts![i].revision = response.revision
            latest.metadataAttempts![i].inputSHA256 = inputHash
            latest.metadataAttempts![i].titleApplied = applyTitle; latest.metadataAttempts![i].categoryApplied = applyCategory
            latest.metadataAttempts![i].message = applyTitle || applyCategory ? "命名分類完成；手動設定的欄位已保留。" : "整理完成，保留你設定的名稱與分類。"
            try save(latest)
        } catch {
            do {
                var latest = try record(id)
                if let operationID, let i = latest.metadataAttempts?.firstIndex(where:{$0.id == operationID}) {
                    let wasCancelled = cancelled.contains(id) || error is CancellationError
                    latest.metadataAttempts![i].status = wasCancelled ? "cancelled" : "failed"
                    latest.metadataAttempts![i].message = wasCancelled ? "命名分類已取消，原始稿已保留。" : "命名分類失敗：" + error.localizedDescription
                    latest.metadataAttempts![i].finished = Date(); try save(latest)
                } else {errorMessage = "原始稿已保留；無法建立整理工作：" + error.localizedDescription}
            } catch {errorMessage = "原始稿已保留；無法儲存整理狀態：" + error.localizedDescription}
        }
    }
    func cancel(_ id: UUID) {
        cancelled.insert(id); queue.removeAll { $0.id == id }
        if activeID == id { runner?.cancel(); activity = "正在取消" }
        do {
            var item = try record(id)
            if !item.attempts.isEmpty, ["queued","running"].contains(item.status) {
                let i = item.attempts.count-1; item.attempts[i].status = "cancelled"; item.attempts[i].message = "工作已取消，可重試。"; item.attempts[i].finished = Date()
                try save(item)
            } else if let i = item.metadataAttempts?.indices.last, ["queued","running"].contains(item.metadataAttempts![i].status) {
                item.metadataAttempts![i].status = "cancelled"; item.metadataAttempts![i].message = "命名分類已取消，可只重試整理。"; item.metadataAttempts![i].finished = Date(); try save(item)
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func setLanguage(_ id: UUID, language: String) throws {
        guard TranscriptionLanguage(rawValue:language) != nil else {throw LibraryError("不支援的轉錄語言")}
        var item = try record(id)
        guard !item.isProcessing else {throw LibraryError("請等目前工作結束後再變更語言。")}
        item.transcriptionLanguage = language; try save(item)
    }
    func update(_ id: UUID, title: String, category: String, keep: Bool, recordedDate: Date? = nil, titleEdited: Bool? = nil, categoryEdited: Bool? = nil) throws {
        var item = try record(id)
        let newTitle = title.trimmingCharacters(in:.whitespacesAndNewlines)
        let newCategory = category.trimmingCharacters(in:.whitespacesAndNewlines)
        let titleChanged = titleEdited ?? (newTitle != item.title)
        let categoryChanged = categoryEdited ?? (newCategory != item.category)
        if titleChanged {
            guard !newTitle.isEmpty else {throw LibraryError("錄音名稱不能空白。")}
            item.titleManuallyEdited = true; item.title = newTitle
        }
        if categoryChanged {item.categoryManuallyEdited = true; item.category = newCategory.isEmpty ? "未分類" : newCategory}
        if let recordedDate, recordingDatePrefix(recordedDate) != item.datePrefix {
            item.recordedAt = recordedDate; item.recordedDateSource = "手動設定"
            if !titleChanged, !item.protectTitle, let theme = item.currentMetadata?.proposedTitle {item.title = item.datePrefix + " " + theme}
        }
        item.keepForever = keep; try save(item)
    }
    func saveEdit(_ id: UUID, text: String, sourceID: UUID? = nil) throws { _ = try store.saveEdit(record(id), text: text, sourceID: sourceID); try reload() }
    func exportMarkdown(_ id: UUID, mode: String = "逐字稿", to url: URL) throws {
        let item = try record(id)
        guard let raw = try store.raw(item) else { throw LibraryError("尚無可匯出的逐字稿") }
        let body: String
        if mode == "時間戳" { body = raw.segments.map { "[\(timeLabel($0.start))] \($0.text)" }.joined(separator: "\n\n") }
        else if mode == "原始文字" { body = raw.text }
        else { body = try store.edit(item)?.text ?? raw.text }
        try "# \(item.title)\n\n\(item.category) · \(item.durationLabel)\n\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    }
    func delete(_ id: UUID) throws {
        guard activeID != id else {throw LibraryError("工作正在停止，請稍候再移除。")}
        try store.remove(record(id)); livePreviews.removeValue(forKey:id); try reload()
    }
    func moveToTrash(_ ids: Set<UUID>) async -> RemovalBatchResult {
        var result = RemovalBatchResult()
        guard !isRemoving else {result.failures.append("正在處理另一個移除操作，請稍候。"); return result}
        isRemoving = true
        defer {isRemoving = false; trashActivity = nil; pendingTrash.subtract(ids)}
        var eligible: [UUID] = []
        for id in ids {
            do {
                let item = try record(id)
                if item.keepForever {result.protected.append(id)} else {eligible.append(id)}
            } catch {result.failures.append(error.localizedDescription)}
        }
        pendingTrash.formUnion(eligible)
        // Cancel the whole selected queue first so the next selected job cannot start while waiting.
        for id in eligible {
            if activeID == id || (try? record(id).isProcessing) == true {cancel(id)}
        }
        for (index,id) in eligible.enumerated() {
            trashActivity = "移至垃圾桶 \(index+1)/\(eligible.count)"
            let deadline = Date().addingTimeInterval(20)
            while activeID == id, Date() < deadline {try? await Task.sleep(nanoseconds:100_000_000)}
            do {
                guard activeID != id else {throw LibraryError("背景工作尚未停止，這份錄音仍保留在 Library。")}
                let item = try record(id)
                if item.keepForever {result.protected.append(id); continue}
                try store.remove(item); livePreviews.removeValue(forKey:id); result.succeeded.append(id)
            } catch {result.failures.append(error.localizedDescription)}
        }
        do {try reload()} catch {result.failures.append(error.localizedDescription)}
        importNotice = "已移到垃圾桶 \(result.succeeded.count) 份" + (result.protected.isEmpty ? "" : "・永久保留已跳過 \(result.protected.count) 份")
        if !result.failures.isEmpty {errorMessage = result.failures.joined(separator:"\n")}
        return result
    }
    func restoreFromTrash(_ ids: Set<UUID>) -> RemovalBatchResult {
        var result = RemovalBatchResult()
        guard !isRemoving else {result.failures.append("正在處理移除操作，請稍候。"); return result}
        for id in ids {
            do {
                let item = try record(id,includeTrashed:true)
                _ = try store.restore(item); result.succeeded.append(id)
            } catch {result.failures.append(error.localizedDescription)}
        }
        do {try reload()} catch {result.failures.append(error.localizedDescription)}
        importNotice = "已復原 \(result.succeeded.count) 份錄音"
        if !result.failures.isEmpty {errorMessage = result.failures.joined(separator:"\n")}
        return result
    }
    func permanentlyDelete(_ ids: Set<UUID>) async -> RemovalBatchResult {
        var result = RemovalBatchResult()
        guard !isRemoving else {result.failures.append("正在處理另一個移除操作，請稍候。"); return result}
        isRemoving = true; defer {isRemoving = false; trashActivity = nil}
        for (index,id) in ids.enumerated() {
            trashActivity = "永久刪除 \(index+1)/\(ids.count)"
            do {
                let item = try record(id,includeTrashed:true)
                if item.keepForever {result.protected.append(id); continue}
                try store.purge(item); result.succeeded.append(id)
            } catch {result.failures.append(error.localizedDescription)}
            await Task.yield()
        }
        do {try reload()} catch {result.failures.append(error.localizedDescription)}
        importNotice = "已永久刪除 \(result.succeeded.count) 份" + (result.protected.isEmpty ? "" : "・保留項目已跳過 \(result.protected.count) 份")
        if !result.failures.isEmpty {errorMessage = result.failures.joined(separator:"\n")}
        return result
    }
    func shutdown() {
        stopping = true
        for item in recordings where item.isProcessing { cancel(item.id) }
        runner?.cancel()
    }
    var isBusy: Bool { worker != nil || !queue.isEmpty }
}
