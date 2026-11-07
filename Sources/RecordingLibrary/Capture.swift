import Foundation
import AVFoundation
import Combine

struct CaptureDraft: Codable, Identifiable {
    var id = UUID()
    var startedAt = Date()
    var language: String
    var mode: CaptureMode?
    var managedName: String {"source.caf"}
}

@MainActor protocol AudioRecordingSession: AnyObject {
    var elapsed: TimeInterval { get }
    var power: Float { get }
    var microphonePower: Float { get }
    var systemPower: Float { get }
    var inputLabel: String { get }
    var failureMessage: String? { get }
    var finished: ((Bool, String?) -> Void)? { get set }
    func record() -> Bool
    func pause()
    func stop()
    func updateMeters()
}

extension AudioRecordingSession {
    var microphonePower:Float {power}
    var systemPower:Float {-160}
    var inputLabel:String {"系統預設麥克風"}
    var failureMessage:String? {nil}
}

@MainActor final class MicrophoneSession: NSObject, AudioRecordingSession, AVAudioRecorderDelegate {
    let recorder: AVAudioRecorder
    var finished: ((Bool, String?) -> Void)?
    init(url: URL) throws {
        // CAF keeps PCM audio usable without waiting for an m4a container to be finalized.
        recorder = try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
        super.init()
        recorder.delegate = self; recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {throw LibraryError("無法準備錄音，請確認麥克風與儲存空間。")}
    }
    var elapsed: TimeInterval {recorder.currentTime}
    var power: Float {recorder.averagePower(forChannel:0)}
    func record() -> Bool {recorder.record()}
    func pause() {recorder.pause()}
    func stop() {recorder.stop()}
    func updateMeters() {recorder.updateMeters()}
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished?(flag,nil) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "音訊寫入中斷"
        Task { @MainActor [weak self] in self?.finished?(false,message) }
    }
}

extension LibraryEngine {
    func captureManifest(_ draft: CaptureDraft) -> URL {store.root.appendingPathComponent("recordings/\(draft.id.uuidString)/capture.json")}
    func captureMedia(_ draft: CaptureDraft) -> URL {captureManifest(draft).deletingLastPathComponent().appendingPathComponent(draft.managedName)}
    func prepareCapture(language: String, mode: CaptureMode = .microphone) throws -> CaptureDraft {
        guard TranscriptionLanguage(rawValue:language) != nil else {throw LibraryError("不支援的轉錄語言")}
        let draft = CaptureDraft(language:language,mode:mode)
        let manifest = captureManifest(draft)
        try FileManager.default.createDirectory(at:manifest.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(draft).write(to:manifest,options:.atomic)
        return draft
    }
    func pendingCaptures() throws -> [CaptureDraft] {
        let folders = try FileManager.default.contentsOfDirectory(at:store.root.appendingPathComponent("recordings"),includingPropertiesForKeys:nil)
        var drafts: [CaptureDraft] = []
        for folder in folders {
            let manifest = folder.appendingPathComponent("capture.json")
            guard FileManager.default.fileExists(atPath:manifest.path) else {continue}
            let draft = try JSONDecoder().decode(CaptureDraft.self,from:Data(contentsOf:manifest))
            guard folder.lastPathComponent == draft.id.uuidString else {throw LibraryError("錄音草稿路徑不符，請檢查儲存位置。")}
            if try store.lookup(draft.id) == nil {drafts.append(draft)}
            else {try? FileManager.default.removeItem(at:manifest)}
        }
        return drafts.sorted {$0.startedAt > $1.startedAt}
    }
    func discardCapture(_ draft: CaptureDraft) throws {
        guard try store.lookup(draft.id) == nil else {throw LibraryError("錄音已歸檔，請從 Library 移到垃圾桶。")}
        let folder = captureManifest(draft).deletingLastPathComponent()
        let parent = store.root.appendingPathComponent("recordings").resolvingSymlinksInPath().standardizedFileURL.path
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == parent + "/" + draft.id.uuidString else {throw LibraryError("錄音路徑不符，已停止刪除。")}
        try FileManager.default.removeItem(at:folder)
    }
    func archiveCapture(_ draft: CaptureDraft, autoTranscribe: Bool = true) async throws -> Recording {
        if let existing = try store.lookup(draft.id) {
            try? FileManager.default.removeItem(at:captureManifest(draft)); try reload(); return existing
        }
        let media = captureMedia(draft)
        let (duration,isVideo,_,_) = try await metadata(media)
        guard duration > 0, !isVideo else {throw LibraryError("錄音沒有可讀取的音訊，原檔已保留，可重試或開啟儲存位置檢查。")}
        let hash = try await digest(media)
        let bytes = (try FileManager.default.attributesOfItem(atPath:media.path)[.size] as? NSNumber)?.int64Value ?? 0
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"zh_TW"); formatter.timeZone = TimeZone.current; formatter.dateFormat = "HH-mm-ss"
        var item = Recording(id:draft.id,title:recordingDatePrefix(draft.startedAt) + L(" 錄音 ") + formatter.string(from:draft.startedAt),sourcePath:media.path,managedName:draft.managedName,duration:duration,bytes:bytes,isVideo:false)
        item.recordedAt = draft.startedAt; item.recordedDateSource = "App 錄音開始時間";item.created = draft.startedAt
        item.titleManuallyEdited = false;item.categoryManuallyEdited = false;item.transcriptionLanguage = draft.language
        item.contentSHA256 = hash;item.audioSHA256 = try await audioDigest(media);item.archivedAt = Date();item.sourcePaths = [];item.importOrigin = L("App 錄音") + " · " + (draft.mode ?? .microphone).label
        item.captureMode = (draft.mode ?? .microphone).rawValue
        // No copy or move: the recorder has already written the final owned media file.
        try writeArchiveManifest(item);try store.save(item);try reload()
        try? FileManager.default.removeItem(at:captureManifest(draft))
        if autoTranscribe {do {try enqueue(item.id,language:draft.language)} catch {errorMessage = "錄音已儲存，可手動重試轉錄。\n" + error.localizedDescription}}
        return try record(item.id)
    }
}

@MainActor final class CaptureController: ObservableObject {
    enum State {case idle, requesting, recording, paused, stopping, saving}
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var activeMode: CaptureMode = .microphone
    @Published private(set) var inputLabel = "系統預設麥克風"
    @Published private(set) var drafts: [CaptureDraft] = []
    @Published private(set) var savedID: UUID?
    @Published var errorMessage: String?
    let engine: LibraryEngine
    private var session: AudioRecordingSession?
    private var currentDraft: CaptureDraft?
    private var timer: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var expectedStop = false
    private var terminating = false
    private let permission: () async -> Bool
    private let makeSession: ((URL) throws -> AudioRecordingSession)?
    var busy: Bool {state != .idle}
    var recording: Bool {state == .recording || state == .paused}
    init(engine: LibraryEngine, permission: (() async -> Bool)? = nil, makeSession: ((URL) throws -> AudioRecordingSession)? = nil) {
        self.engine = engine
        self.permission = permission ?? {
            switch AVCaptureDevice.authorizationStatus(for:.audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for:.audio)
            default: return false
            }
        }
        self.makeSession = makeSession
        refreshDrafts()
    }
    func refreshDrafts() {do {drafts = try engine.pendingCaptures()} catch {errorMessage = error.localizedDescription}}
    func start(language: String, mode: CaptureMode = .microphone) async {
        guard !busy, !terminating else {return}
        state = .requesting;errorMessage = nil;savedID = nil;activeMode = mode
        if mode.hasMicrophone, !(await permission()) {state = .idle;errorMessage = "尚未允許麥克風。請在「系統設定 → 隱私權與安全性 → 麥克風」允許 Recording Library，再重試。";return}
        guard !terminating else {state = .idle;return}
        do {
            let draft = try engine.prepareCapture(language:language,mode:mode);currentDraft = draft
            let session:AudioRecordingSession
            if let makeSession {session = try makeSession(engine.captureMedia(draft))}
            else if mode.hasSystem {
                if #available(macOS 14.2, *) {session = try SystemAudioSession(url:engine.captureMedia(draft),mode:mode)}
                else {throw LibraryError("系統聲音錄製需要 macOS 14.2 或更新版本。")}
            } else {session = try MicrophoneSession(url:engine.captureMedia(draft))}
            self.session = session;inputLabel = L(session.inputLabel)
            session.finished = { [weak self] success,message in self?.didFinish(success:success,message:message) }
            guard session.record() else {throw LibraryError(session.failureMessage ?? "無法開始錄音，請確認裝置與錄音權限。")}
            sleepActivity = ProcessInfo.processInfo.beginActivity(options:[.idleSystemSleepDisabled],reason:"錄音中")
            expectedStop = false;elapsed = 0;level = 0;microphoneLevel = 0;systemLevel = 0;state = .recording
            timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in Task { @MainActor in self?.refreshMeters() } }
        } catch {
            session?.finished = nil;session?.stop();session = nil;state = .idle;currentDraft = nil
            errorMessage = error.localizedDescription;refreshDrafts()
        }
    }
    func refreshMeters() {
        guard state == .recording, let session else {return}
        elapsed = session.elapsed;session.updateMeters()
        microphoneLevel = activeMode.hasMicrophone ? min(1,max(0,pow(10,Double(session.microphonePower)/20))) : 0
        systemLevel = activeMode.hasSystem ? min(1,max(0,pow(10,Double(session.systemPower)/20))) : 0
        level = max(microphoneLevel,systemLevel)
    }
    func pauseOrResume() {
        guard let session else {return}
        if state == .recording {elapsed = session.elapsed;session.pause();level = 0;microphoneLevel = 0;systemLevel = 0;state = .paused}
        else if state == .paused {
            if session.record() {state = .recording}
            else {errorMessage = "無法繼續錄音，請停止並儲存已錄下的部分。"}
        }
    }
    func stop() {
        guard recording, let session else {return}
        elapsed = session.elapsed;state = .stopping;level = 0;microphoneLevel = 0;systemLevel = 0;expectedStop = true;timer?.invalidate();timer = nil
        session.stop()
    }
    private func didFinish(success: Bool, message: String?) {
        guard let draft = currentDraft, session != nil else {return}
        let save = expectedStop && success
        if let sleepActivity {ProcessInfo.processInfo.endActivity(sleepActivity);self.sleepActivity = nil}
        session?.finished = nil;session?.stop();session = nil;currentDraft = nil;timer?.invalidate();timer = nil;level = 0;microphoneLevel = 0;systemLevel = 0
        if save {
            state = .saving
            Task {await saveDraft(draft,alreadySaving:true)}
        } else {
            state = .idle;errorMessage = message ?? "錄音已中斷，檔案保留在待處理錄音，可嘗試儲存。";refreshDrafts()
        }
    }
    func saveDraft(_ draft: CaptureDraft, alreadySaving: Bool = false) async {
        guard !busy || alreadySaving else {return}
        state = .saving
        do {let item = try await engine.archiveCapture(draft,autoTranscribe:!terminating);savedID = item.id}
        catch {errorMessage = "錄音尚未歸檔，檔案已保留，可重試儲存。\n" + error.localizedDescription}
        state = .idle;refreshDrafts()
    }
    func discard(_ draft: CaptureDraft) {
        guard !busy else {return}
        do {try engine.discardCapture(draft);refreshDrafts()} catch {errorMessage = error.localizedDescription}
    }
    func finishForTermination() async {
        terminating = true
        if recording {stop()}
        let deadline = Date().addingTimeInterval(15)
        while [.stopping,.saving,.requesting].contains(state), Date() < deadline {try? await Task.sleep(nanoseconds:100_000_000)}
        // A failed or interrupted save keeps its capture manifest and original media for next launch.
    }
}
