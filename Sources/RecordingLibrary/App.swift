import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var engine: LibraryEngine?
    static var capture: CaptureController?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating {return .terminateLater}
        return MainActor.assumeIsolated {
            guard let capture = Self.capture, capture.busy else {Self.engine?.shutdown();return .terminateNow}
            terminating = true
            Task {
                await capture.finishForTermination()
                Self.engine?.shutdown()
                sender.reply(toApplicationShouldTerminate:true)
            }
            return .terminateLater
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct RecordingLibraryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var engine: LibraryEngine
    @StateObject private var capture: CaptureController
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--check-localization") {
            let english = Bundle.main.preferredLocalizations.first == "en"
            let checks:[(String,String)] = english ? [
                (L("全部錄音"),"All recordings"), (L("開始錄音"),"Start recording"),
                (L("已選取 3 份錄音"),"3 recordings selected"),
                (L("產品討論"),"Product discussion"),
                (L("取消"),"Cancel")
            ] : [(L("開始錄音"),"開始錄音"),(L("產品討論"),"產品討論")]
            guard checks.allSatisfy({$0.0 == $0.1}), Localization.translations.count > 300 else {
                fputs("Localization check failed: \(checks)\n",stderr); exit(1)
            }
            print("LOCALIZATION CHECK PASSED: \(Bundle.main.preferredLocalizations)")
            exit(0)
        }
        let root: URL
        if let i = arguments.firstIndex(of: "--library"), arguments.indices.contains(i+1) { root = URL(fileURLWithPath: arguments[i+1]) }
        else if let custom = ProcessInfo.processInfo.environment["RECORDING_LIBRARY_ROOT"] { root = URL(fileURLWithPath: custom) }
        else { root = LibraryEngine.defaultRoot }
        let workerName = Bundle.main.object(forInfoDictionaryKey:"RecordingLibraryWorker") as? String ?? "Validate"
        let helper = Bundle.main.resourceURL!.appendingPathComponent("WhisperValidation/" + workerName)
        do {
            let instance = try LibraryEngine(root: root, helper: helper)
            if arguments.contains("--check-audio-setup") {
                // Diagnostic only: construct and dispose private audio objects. Never call record()/AudioDeviceStart.
                guard #available(macOS 14.2, *) else {throw LibraryError("需要 macOS 14.2 或以上。")}
                let directory = root.appendingPathComponent("audio-setup-probe")
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let session = try SystemAudioSession(url:directory.appendingPathComponent("probe.caf"),mode:.both)
                session.stop()
                let setup = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("capture-setup.json")))
                FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:["prepared":true,"recordingStarted":false,"setup":setup],options:[.prettyPrinted,.sortedKeys]))
                exit(0)
            }
            if arguments.contains("--check-library") {
                let entries = try instance.recordings.map { record -> [String:Any] in
                    let raw = try instance.store.raw(record)
                    let edit = try instance.store.edit(record)
                    guard FileManager.default.fileExists(atPath:instance.store.media(record).path) else {throw LibraryError("匯入副本遺失")}
                    return ["id":record.id.uuidString,"title":record.title,"status":record.status,"rawSegments":raw?.segments.count ?? 0,"hasEdit":edit != nil,"keepForever":record.keepForever]
                }
                let data = try JSONSerialization.data(withJSONObject:["startupPassed":true,"library":root.path,"recordings":entries],options:[.prettyPrinted,.sortedKeys])
                FileHandle.standardOutput.write(data); exit(0)
            }
            let recorder = CaptureController(engine:instance)
            _engine = StateObject(wrappedValue:instance); _capture = StateObject(wrappedValue:recorder)
            AppDelegate.engine = instance;AppDelegate.capture = recorder
        } catch {
            if arguments.contains("--check-library") || arguments.contains("--check-audio-setup") { fputs("Startup check failed: \(error.localizedDescription)\n",stderr); exit(1) }
            let alert = NSAlert(); alert.messageText = L("無法開啟 Recording Library"); alert.informativeText = error.localizedDescription; alert.runModal()
            exit(1)
        }
    }
    var body: some Scene {
        WindowGroup("Recording Library") { LibraryView().environmentObject(engine).environmentObject(capture).frame(minWidth: 1040, minHeight: 660) }
            .defaultSize(width: 1280, height: 820)
            .commands {
                CommandMenu(L("錄音")) {
                    Button(L("開始錄音")) {Task {await capture.start(language:UserDefaults.standard.string(forKey:"importTranscriptionLanguage") ?? "auto",mode:CaptureMode(rawValue:UserDefaults.standard.string(forKey:"captureMode") ?? "both") ?? .both)}}.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(capture.busy)
                    Button(L(capture.state == .paused ? "繼續錄音" : "暫停錄音")) {capture.pauseOrResume()}.disabled(!capture.recording)
                    Button(L("停止並儲存")) {capture.stop()}.disabled(!capture.recording)
                }
                CommandGroup(replacing: .newItem) {
                    Button(L("匯入錄音或影片…")) { NotificationCenter.default.post(name: .importRecording, object: nil) }.keyboardShortcut("i", modifiers: .command)
                }
            }
        Settings { ModelSettingsView().environmentObject(engine) }
    }
}
extension Notification.Name { static let importRecording = Notification.Name("importRecording") }
struct LibraryView: View {
    @EnvironmentObject var engine: LibraryEngine
    @EnvironmentObject var capture: CaptureController
    @AppStorage("importTranscriptionLanguage") private var importLanguage = "auto"
    @State private var filter = "全部錄音"
    @State private var selectedIDs: Set<UUID> = []
    @State private var removalRequest: RemovalRequest?
    var selectedID: UUID? {
        get {selectedIDs.count == 1 ? selectedIDs.first : nil}
        nonmutating set {selectedIDs = newValue.map {Set([$0])} ?? []}
    }
    var isTrash: Bool {filter == "垃圾桶"}
    @State private var query = ""
    @State private var dropping = false
    private let filters = [("全部錄音","square.stack"),("未轉錄","waveform"),("工作中","arrow.triangle.2.circlepath"),("已完成","checkmark.circle"),("需要處理","exclamationmark.circle"),("永久保留","pin")]
    var visible: [Recording] {
        engine.search(query,trash:isTrash).filter { item in
            switch filter {
            case "全部錄音", "垃圾桶": return true
            case "未轉錄": return item.status == "imported"
            case "工作中": return item.isProcessing
            case "已完成": return item.status == "completed"
            case "需要處理": return item.requiresAttention
            case "永久保留": return item.keepForever
            default: return filter.hasPrefix("category:") && item.category == String(filter.dropFirst(9))
            }
        }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName:"waveform.circle.fill").font(.system(size:32)).foregroundStyle(.teal)
                    VStack(alignment:.leading, spacing:3) { Text(L("Recording Library")).font(.headline); Label(L("本機資料庫"),systemImage:"internaldrive").font(.caption).foregroundStyle(.secondary) }
                }.padding(18)
                List(selection:$filter) {
                    Section(L("資料庫")) {
                        ForEach(filters, id:\.0) { name, icon in Label(L(name),systemImage:icon).tag(name) }
                    }
                    Section(L("管理")) {Label(L("垃圾桶"),systemImage:"trash").badge(engine.trashedRecordings.count).tag("垃圾桶")}
                    Section(L("分類")) {
                        ForEach(Array(Set(recordingCategories + engine.recordings.map(\.category))).sorted(),id:\.self) { category in Label(L(category),systemImage:"folder").tag("category:" + category) }
                    }
                }.listStyle(.sidebar)
                Divider()
                CaptureControls().padding(14)
                Divider()
                VStack(alignment:.leading,spacing:6) {
                    Label(L("離線轉錄"),systemImage:"lock.shield").font(.caption).foregroundStyle(.secondary)
                    Text(L("\(engine.recordings.count) 份錄音 · \(timeLabel(engine.recordings.reduce(0) { $0 + $1.duration }))")).font(.caption).foregroundStyle(.secondary)
                    Button(L("開啟儲存位置")) { NSWorkspace.shared.open(engine.store.root) }.buttonStyle(.link).font(.caption)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min:190,ideal:220,max:270)
        } content: {
            VStack(spacing:0) {
                HStack { Text(L(filter.hasPrefix("category:") ? String(filter.dropFirst(9)) : filter)).font(.title2.bold()); Spacer(); Text(L("\(visible.count)")).foregroundStyle(.secondary) }.padding(18)
                HStack { Image(systemName:"magnifyingglass").foregroundStyle(.secondary); TextField(L("搜尋名稱、中文內容或英文術語"),text:$query).textFieldStyle(.plain); if !query.isEmpty { Button { query = "" } label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(.secondary) } }.padding(9).background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:8)).padding(.horizontal,14).padding(.bottom,12)
                if !isTrash {HStack {
                    Text(L("錄音語言")).font(.caption).foregroundStyle(.secondary)
                    Picker(L("錄音語言"),selection:$importLanguage) {ForEach(TranscriptionLanguage.allCases,id:\.rawValue) {Text(L($0.label)).tag($0.rawValue)}}.labelsHidden().frame(maxWidth:.infinity,alignment:.trailing)
                }.padding(.horizontal,16).padding(.bottom,12)}
                if isTrash {Text(L("可復原；清空垃圾桶才會釋放儲存空間。")).font(.caption).foregroundStyle(.secondary).padding(.horizontal,16).padding(.bottom,12)}
                if !visible.isEmpty && !isTrash {
                    dropZone(expanded:false).frame(height:62).padding(.horizontal,14).padding(.bottom,12)
                }
                Divider()
                if visible.isEmpty {
                    if isTrash {ContentUnavailableView(L("垃圾桶是空的"),systemImage:"trash",description:Text(L("移除的錄音會保留在這裡，直到你選擇永久刪除。")))}
                    else if query.isEmpty {dropZone(expanded:true).frame(maxWidth:.infinity,maxHeight:.infinity).padding(14)}
                    else {ContentUnavailableView(L("沒有符合的錄音"),systemImage:"magnifyingglass",description:Text(L("支援中文連續字詞及英文子字串搜尋。")))}
                } else {
                    List(visible,selection:$selectedIDs) { item in
                        RecordingRow(item:item,active:engine.activeID == item.id).tag(item.id).padding(.vertical,6)
                            .contextMenu {
                                let ids = selectedIDs.contains(item.id) ? selectedIDs : Set([item.id])
                                if isTrash {
                                    Button(L("復原錄音")) {_ = engine.restoreFromTrash(ids)}.disabled(engine.isRemoving || item.purgeStartedAt != nil)
                                    Button(L("永久刪除…"),role:.destructive) {removalRequest = RemovalRequest(kind:.purge,ids:ids)}.disabled(engine.isRemoving)
                                } else {
                                    Button(L("移到垃圾桶…"),role:.destructive) {removalRequest = RemovalRequest(kind:.trash,ids:ids)}.disabled(engine.isRemoving || !ids.contains(where:{id in engine.recordings.contains(where:{$0.id == id && !$0.keepForever})}))
                                    if ids.contains(where:{id in engine.recordings.contains(where:{$0.id == id && $0.keepForever})}) {Text(L("永久保留項目會跳過"))}
                                }
                            }
                    }.listStyle(.inset)
                    .onDeleteCommand {
                        if !selectedIDs.isEmpty && !engine.isRemoving {removalRequest = RemovalRequest(kind:isTrash ? .purge : .trash,ids:selectedIDs)}
                    }
                }
                if !engine.configuration.readiness.isEmpty {
                    VStack(alignment:.leading,spacing:5) {
                        Text(L("模型或工具尚未準備："+engine.configuration.readiness.joined(separator:"、"))).font(.caption).foregroundStyle(.orange)
                        SettingsLink {Text(L("開啟模型設定"))}
                    }.padding(12)
                }
                if let message = engine.trashActivity {HStack {ProgressView().controlSize(.small);Text(L(message)).font(.caption);Spacer()}.padding(12)}
                if let notice = engine.importNotice {
                    HStack(alignment:.top) {Image(systemName:"checkmark.seal.fill").foregroundStyle(.teal); Text(L(notice)).font(.caption); Spacer(); Button {engine.importNotice = nil} label:{Image(systemName:"xmark")}.buttonStyle(.plain)}.padding(12)
                }
                if let message = engine.importMessage { HStack { ProgressView().controlSize(.small); Text(L(message)).font(.caption); Spacer() }.padding(12) }
                if let activeID = engine.activeID, let item = engine.recordings.first(where:{$0.id == activeID}) {
                    Divider()
                    HStack(spacing:10) { ProgressView().controlSize(.small); VStack(alignment:.leading,spacing:3) { Text(item.title).lineLimit(1); Text(L(engine.activity)).foregroundStyle(.secondary) }; Spacer(); Button(L("查看")) { selectedID = activeID } }.font(.caption).padding(14)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top).navigationSplitViewColumnWidth(min:280,ideal:330,max:430)
        } detail: {
            if let selectedID, let record = engine.recordings.first(where:{$0.id == selectedID}) {
                RecordingDetail(record:record,media:engine.store.media(record)).id(selectedID)
            } else if let selectedID, let record = engine.trashedRecordings.first(where:{$0.id == selectedID}) {
                TrashDetail(record:record,onRestore:{_ = engine.restoreFromTrash([record.id])},onPurge:{removalRequest = RemovalRequest(kind:.purge,ids:[record.id])})
            } else if selectedIDs.count > 1 {
                VStack(spacing:18) {
                    Image(systemName:isTrash ? "trash" : "square.stack").font(.system(size:40)).foregroundStyle(.secondary)
                    Text(L("已選取 \(selectedIDs.count) 份錄音")).font(.title2.bold())
                    if isTrash {Button(L("復原所選錄音")) {_ = engine.restoreFromTrash(selectedIDs)};Button(L("永久刪除…"),role:.destructive) {removalRequest = RemovalRequest(kind:.purge,ids:selectedIDs)}}
                    else {Button(L("移到垃圾桶…"),role:.destructive) {removalRequest = RemovalRequest(kind:.trash,ids:selectedIDs)}}
                }.disabled(engine.isRemoving).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if isTrash {
                ContentUnavailableView(L("垃圾桶"),systemImage:"trash",description:Text(L("選取錄音即可復原或永久刪除。來源檔案與模型保持不動。")))
            } else {
                recordingWelcome.frame(maxWidth:.infinity,maxHeight:.infinity).padding(28)
            }
        }
        .toolbar {
            ToolbarItem(placement:.primaryAction) {
                if isTrash {Button(L("清空垃圾桶…")) {removalRequest = RemovalRequest(kind:.empty,ids:Set(engine.trashedRecordings.map(\.id)))}.disabled(engine.trashedRecordings.isEmpty || engine.isRemoving)}
                else {Button(action:importPanel) {Label(L("匯入"),systemImage:"plus")}.disabled(engine.isImporting)}
            }
        }
        .sheet(item:$removalRequest) {request in
            RemovalConfirmation(request:request,records:(engine.recordings + engine.trashedRecordings).filter {request.ids.contains($0.id)}) {
                removalRequest = nil
                Task {
                    if request.kind == .trash {_ = await engine.moveToTrash(request.ids)}
                    else {_ = await engine.permanentlyDelete(request.ids)}
                    selectedIDs.subtract(request.ids)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:.importRecording)) { _ in importPanel() }
        .onOpenURL { url in Task { let ids = await engine.importURLs([url],language:importLanguage); reveal(ids) } }
        .onDrop(of:[UTType.fileURL.identifier,UTType.audio.identifier,UTType.movie.identifier],isTargeted:$dropping) { providers in
            Task {
                do {
                    let batch = try await ProviderDropResolver.resolve(providers)
                    let ids = await engine.importURLs(batch.urls,ownedStagingDirectory:batch.staging,language:importLanguage)
                    reveal(ids)
                } catch {engine.errorMessage = error.localizedDescription}
            }
            return true
        }
        .overlay { if dropping { RoundedRectangle(cornerRadius:12).stroke(.teal,lineWidth:3).padding(6).allowsHitTesting(false) } }
        .alert(L("無法完成操作"),isPresented:Binding(get:{engine.errorMessage != nil},set:{if !$0 {engine.errorMessage = nil}})) { Button(L("好")) {engine.errorMessage = nil} } message:{ Text(L(engine.errorMessage ?? "")) }
        .onChange(of:capture.savedID) {_,id in if let id {reveal([id])}}
        .onChange(of:filter) {_,_ in selectedIDs.formIntersection(Set(visible.map(\.id)))}
        .onChange(of:query) {_,_ in selectedIDs.formIntersection(Set(visible.map(\.id)))}
        .onChange(of:Set(visible.map(\.id))) {_,ids in selectedIDs.formIntersection(ids)}
    }
    private var recordingWelcome: some View {
        VStack(spacing:18) {
            Image(systemName:"record.circle").font(.system(size:54)).foregroundStyle(.red)
            Text(L("從錄音開始")).font(.title.bold())
            Text(L("錄下會議或想法，停止後自動轉錄、命名與分類。")).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                Task {await capture.start(language:importLanguage,mode:CaptureMode(rawValue:UserDefaults.standard.string(forKey:"captureMode") ?? "both") ?? .both)}
            } label:{Label(L("開始錄音"),systemImage:"record.circle").padding(.horizontal,16).padding(.vertical,5)}
                .buttonStyle(.borderedProminent).tint(.red).disabled(capture.busy)
            Text(L("先在側邊欄選擇麥克風、系統聲音或兩者一起錄。")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Divider().padding(.vertical,8)
            Text(L("已有錄音或影片？也可以匯入。")).font(.callout).foregroundStyle(.secondary)
            dropZone(expanded:false).frame(height:78)
        }.frame(maxWidth:520)
    }
    private func dropZone(expanded: Bool) -> some View {
        RecordingDropZone(expanded:expanded,onReceive:{urls,staging in
            let language = importLanguage
            Task {let ids = await engine.importURLs(urls,ownedStagingDirectory:staging,language:language); reveal(ids)}
        },onError:{engine.errorMessage = $0})
    }
    private func reveal(_ ids: [UUID]) {
        guard let id = ids.last else {return}
        filter = "全部錄音"; query = ""; selectedID = id
    }
    private func importPanel() {
        let panel = NSOpenPanel(); panel.title = L("匯入錄音或影片"); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.audio,UTType.movie] + ["mkv","webm","opus","ogg","flac"].compactMap { UTType(filenameExtension:$0) }
        if panel.runModal() == .OK { Task { let ids = await engine.importURLs(panel.urls,language:importLanguage); reveal(ids) } }
    }
}
struct RecordingRow: View {
    let item: Recording
    let active: Bool
    var statusColor: Color {item.trashedAt != nil ? .secondary : item.status == "failed" ? .red : ["organization_failed","organization_cancelled"].contains(item.status) ? .orange : item.status == "completed" ? .teal : .secondary}
    var body: some View {
        HStack(alignment:.top,spacing:11) {
            Image(systemName:item.isVideo ? "film" : "waveform").font(.system(size:19)).foregroundStyle(active ? .teal : .secondary).frame(width:34,height:36).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            VStack(alignment:.leading,spacing:6) {
                HStack { Text(item.title).font(.system(size:13,weight:.semibold)).lineLimit(2); if item.keepForever {Image(systemName:"pin.fill").font(.caption).foregroundStyle(.teal)} }
                Text(L("\(item.durationLabel) · \(L(item.category))")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(item.namingDate,style:.date); Spacer(); Text(L(item.trashedAt != nil ? "已移除" : item.statusLabel)).foregroundStyle(statusColor) }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
struct RemovalRequest: Identifiable {
    enum Kind {case trash, purge, empty}
    let id = UUID()
    let kind: Kind
    let ids: Set<UUID>
}
struct RemovalConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let request: RemovalRequest
    let records: [Recording]
    let onConfirm: () -> Void
    var eligible: [Recording] {records.filter {!$0.keepForever}}
    var action: String {request.kind == .trash ? "移到垃圾桶" : request.kind == .empty ? "清空垃圾桶" : "永久刪除"}
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Label(L(action),systemImage:request.kind == .trash ? "trash" : "trash.slash").font(.title2.bold())
            Text(L(request.kind == .trash ? "將移除 \(eligible.count) 份錄音，可從側邊欄的垃圾桶復原。音檔、逐字稿與編輯版本都會保留。" : "將永久刪除 \(eligible.count) 份錄音的 Library 媒體副本、原始逐字稿、編輯版本與命名紀錄。這個動作無法復原。"))
            if records.contains(where:{$0.isProcessing}) && request.kind == .trash {
                Label(L("會先停止所選錄音的背景工作，再移到垃圾桶。復原後可手動重試。"),systemImage:"pause.circle").font(.callout)
            }
            if records.count != eligible.count {Text(L("\(records.count - eligible.count) 份永久保留錄音會跳過。")).foregroundStyle(.secondary)}
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(records) {record in HStack {Text(record.title).lineLimit(2);Spacer();if record.keepForever {Label(L("略過"),systemImage:"pin.fill").foregroundStyle(.secondary)}}}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:180)
            Text(L("原始來源檔案與既有模型不受影響。")).font(.caption).foregroundStyle(.secondary)
            HStack {Spacer();Button(L("取消"),role:.cancel) {dismiss()}.keyboardShortcut(.cancelAction);Button(L(action),role:.destructive,action:onConfirm).disabled(eligible.isEmpty)}
        }.padding(24).frame(width:490)
    }
}
struct TrashDetail: View {
    @EnvironmentObject var engine: LibraryEngine
    let record: Recording
    let onRestore: () -> Void
    let onPurge: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Label(L("已移到垃圾桶"),systemImage:"trash").foregroundStyle(.secondary)
            Text(record.title).font(.title.bold()).textSelection(.enabled)
            Text(L("\(record.durationLabel) · \(L(record.category))")).foregroundStyle(.secondary)
            if let date = record.trashedAt {Text(L("移除時間：\(date.formatted(date:.abbreviated,time:.shortened))")).font(.callout).foregroundStyle(.secondary)}
            if record.purgeStartedAt != nil {
                Text(L("這份錄音已開始永久刪除，部分檔案可能已移除。請重試永久刪除以完成清理。"))
            } else {
                Text(L("媒體、原始逐字稿、編輯版本與命名紀錄保留在原歸檔位置。復原會帶回原本的資料與工作狀態，不另複製音檔。"))
            }
            if let message = record.purgeError {Text(L(message)).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            HStack {
                Button(L("復原錄音"),action:onRestore).buttonStyle(.borderedProminent).disabled(record.purgeStartedAt != nil)
                Button(L(record.purgeStartedAt == nil ? "永久刪除…" : "重試永久刪除…"),role:.destructive,action:onPurge)
            }.disabled(engine.isRemoving)
            Spacer()
        }.padding(30).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
}
@MainActor final class Playback: ObservableObject {
    let player: AVPlayer
    @Published var time: Double = 0
    @Published var playing = false
    private var observer: Any?
    init(url:URL) {
        player = AVPlayer(url:url)
        observer = player.addPeriodicTimeObserver(forInterval:CMTime(seconds:0.25,preferredTimescale:600),queue:.main) { [weak self] value in
            MainActor.assumeIsolated { guard let self else { return }; self.time = value.seconds.isFinite ? value.seconds : 0; self.playing = self.player.rate != 0 }
        }
    }
    func seek(_ seconds:Double,duration:Double) { player.seek(to:CMTime(seconds:max(0,min(duration,seconds)),preferredTimescale:600)) }
    func toggle() { if player.rate == 0 { player.play() } else { player.pause() } }
    deinit { if let observer { player.removeTimeObserver(observer) }; player.pause() }
}
struct RecordingDetail: View {
    @EnvironmentObject var engine: LibraryEngine
    @EnvironmentObject var capture: CaptureController
    let record: Recording
    @StateObject private var playback: Playback
    @State private var mode = "逐字稿"
    @State private var editing = false
    @State private var editingInfo = false
    @State private var deleting = false
    @State private var showingHistory = false
    @State private var showingArchive = false
    @State private var draft = ""
    @State private var draftSourceID: UUID?
    @State private var raw: TranscriptDocument?
    @State private var revision: EditRevision?
    @State private var documentError: String?
    @State private var savedPreview: PreviewSnapshot?
    @State private var copied = false
    init(record: Recording, media: URL) {
        self.record = record
        _playback = StateObject(wrappedValue:Playback(url: media))
    }
    var preview: PreviewSnapshot? {engine.livePreviews[record.id] ?? savedPreview}
    var isWorking: Bool {record.isTranscribing}
    var previewAvailable: Bool {isWorking || preview != nil}
    var text: String { mode == "原始文字" ? (raw?.text ?? "") : (revision?.text ?? raw?.text ?? "") }
    var diagnostics: [String] { record.attempts.first(where:{$0.id == record.currentRawID})?.diagnostics ?? [] }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:12) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:6) { Text(record.title).font(.system(size:26,weight:.bold)).textSelection(.enabled); HStack { Label(L(record.category),systemImage:"folder"); Text(L("· \(record.durationLabel) · \(record.managedName.split(separator:".").last.map(String.init)?.uppercased() ?? "")")); if record.keepForever { Label(L("永久保留"),systemImage:"pin.fill") } }.font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Menu {
                        Button(L("名稱、分類與保留標記…")) {editingInfo = true}
                        Button(L("轉錄與編輯版本…")) {showingHistory = true}
                        Button(L("歸檔與校驗資訊…")) {showingArchive = true}
                        Button(L("重新產生標題與分類")) {perform {try engine.enqueueOrganization(record.id)}}.disabled(record.currentRawID == nil || record.isProcessing)
                        Button(L("重新轉錄")) {perform {try engine.enqueue(record.id)}}.disabled(record.isProcessing)
                        Button(L("在 Finder 顯示匯入副本")) {NSWorkspace.shared.activateFileViewerSelecting([engine.store.media(record)])}
                        Divider()
                        Button(L("移到垃圾桶…"),role:.destructive) {deleting = true}.disabled(record.keepForever || record.isProcessing)
                    } label:{Image(systemName:"ellipsis.circle").font(.title3)}.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("錄音選單"))
                }
                HStack(spacing:10) {
                    Label(L(record.statusLabel),systemImage:record.status == "completed" ? "checkmark.circle.fill" : ["failed","organization_failed","organization_cancelled"].contains(record.status) ? "exclamationmark.circle.fill" : "waveform").font(.caption.weight(.medium)).foregroundStyle(record.status == "failed" ? .red : ["organization_failed","organization_cancelled"].contains(record.status) ? .orange : .teal).padding(.horizontal,9).padding(.vertical,5).background(.teal.opacity(0.08),in:Capsule())
                    if record.archivedAt != nil {Label(L("已歸檔"),systemImage:"checkmark.seal").font(.caption).foregroundStyle(.secondary)}
                    if record.currentEditID != nil {Text(L("已編輯 · 原始結果另存")).font(.caption).foregroundStyle(.secondary)}
                    Spacer()
                    if record.hasAutomaticMetadata {Text(L(record.automaticMetadataLabel ?? "")).font(.caption).foregroundStyle(.secondary)}
                    if record.isProcessing { Button(L("取消工作")) {engine.cancel(record.id)} }
                    else if record.currentRawID != nil && ["transcribed","organization_failed","organization_cancelled"].contains(record.status) {
                        Button(L("整理標題與分類")) {perform {try engine.enqueueOrganization(record.id)}}.buttonStyle(.borderedProminent).tint(.teal)
                    } else {Button(L(record.currentRawID == nil ? "開始轉錄" : "重新轉錄")) {perform {try engine.enqueue(record.id)}}.buttonStyle(.borderedProminent).tint(.teal)}
                }
                HStack {
                    Text(L("轉錄語言")).font(.caption).foregroundStyle(.secondary)
                    Picker(L("轉錄語言"),selection:Binding(get:{record.transcriptionLanguage ?? "auto"},set:{value in perform {try engine.setLanguage(record.id,language:value)}})) {
                        ForEach(TranscriptionLanguage.allCases,id:\.rawValue) {Text(L($0.label)).tag($0.rawValue)}
                    }.labelsHidden().disabled(record.isProcessing).help(L("套用至下次語音轉錄；整理標題與分類使用現有原始稿。"))
                    Spacer()
                }
                if engine.activeID == record.id {
                    HStack {ProgressView().controlSize(.small); Text(L(engine.activity)); Spacer(); TimelineView(.periodic(from:.now,by:1)) {context in Text(L("已執行 \(timeLabel(context.date.timeIntervalSince(engine.activeSince ?? context.date)))")).monospacedDigit()} }.font(.caption).foregroundStyle(.secondary)
                }
                if record.status == "failed" || record.status == "cancelled" { Text(L(record.attempts.last?.message ?? "")).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(6) }
                if ["organization_failed","organization_cancelled"].contains(record.status) {Text(L(record.currentMetadata?.message ?? "原始稿已保存，可只重試整理。")).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(6)}
            }.padding(24)
            VStack(spacing:12) {
                if record.isVideo { VideoPlayer(player:playback.player).frame(height:165) }
                HStack(spacing:14) {
                    Button {playback.toggle()} label:{Image(systemName:playback.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size:34)).foregroundStyle(.teal)}.buttonStyle(.plain).help(L("播放／暫停")).accessibilityLabel(L("播放／暫停"))
                    Text(L(timeLabel(playback.time))).monospacedDigit().font(.caption)
                    Slider(value:Binding(get:{min(record.duration,max(0,playback.time))},set:{playback.seek($0,duration:record.duration)}),in:0...max(record.duration,0.1)).tint(.teal)
                    Text(L(record.durationLabel)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(capture.busy && capture.activeMode.hasSystem).padding(.horizontal,24).padding(.bottom,20)
            Divider()
            HStack {
                Picker(L("檢視"),selection:$mode) {ForEach(["逐字稿","原始文字","時間戳","診斷"] + (previewAvailable ? ["轉錄預覽"] : []),id:\.self) {Text(L($0)).tag($0)}}.pickerStyle(.segmented).frame(maxWidth:420)
                Spacer()
                Button {draft = text; draftSourceID = mode == "原始文字" ? record.currentRawID : revision?.rawAttemptID ?? record.currentRawID; editing = true} label:{Image(systemName:"square.and.pencil")}.help(L("編輯為新版本")).accessibilityLabel(L("編輯逐字稿")).disabled(raw == nil || mode == "轉錄預覽")
                Button {NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); copied = true; DispatchQueue.main.asyncAfter(deadline:.now()+2) {copied = false}} label:{Image(systemName:copied ? "checkmark" : "doc.on.doc")}.help(L("複製逐字稿")).accessibilityLabel(L("複製逐字稿")).disabled(raw == nil || mode == "轉錄預覽")
                Button {exportMarkdown()} label:{Image(systemName:"square.and.arrow.up")}.help(L("匯出 Markdown")).accessibilityLabel(L("匯出 Markdown")).disabled(raw == nil || mode == "轉錄預覽")
            }.buttonStyle(.borderless).padding(.horizontal,24).padding(.vertical,14)
            if let documentError { Text(L(documentError)).font(.caption).foregroundStyle(.red).padding(.horizontal,24) }
            if mode == "轉錄預覽" || (raw == nil && isWorking) {
                LivePreviewView(snapshot:preview,isWorking:isWorking)
            } else if raw == nil, let preview {
                LivePreviewView(snapshot:preview,isWorking:false)
            } else if raw == nil {
                ContentUnavailableView(L("逐字稿會顯示在這裡"),systemImage:"text.alignleft",description:Text(L("匯入後在背景轉錄，完成後可閱讀、搜尋及另存編輯版本。")))
            } else if mode == "診斷" {
                ScrollView {VStack(alignment:.leading,spacing:12) {
                    Label(L(diagnostics.isEmpty ? "未發現時間戳或空白段落問題" : "\(diagnostics.count) 項診斷"),systemImage:diagnostics.isEmpty ? "checkmark.shield" : "exclamationmark.triangle").font(.headline)
                    Text(L("診斷反映模型原始輸出，沒有自動修正文字或時間戳。點選時間戳播放時，只會將播放位置限制在檔案範圍內。")).foregroundStyle(.secondary)
                    ForEach(Array(diagnostics.enumerated()),id:\.offset) {_,issue in Text(L(issue)).font(.system(.body,design:.monospaced)).textSelection(.enabled)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(24)}
            } else if mode == "時間戳" {
                ScrollView {LazyVStack(alignment:.leading,spacing:0) {
                    ForEach(Array((raw?.segments ?? []).enumerated()),id:\.offset) {_,segment in
                        HStack(alignment:.top,spacing:14) {
                            Button(L(timeLabel(segment.start))) {playback.seek(segment.start,duration:record.duration); playback.player.play()}.font(.system(.caption,design:.monospaced)).foregroundStyle(.teal).buttonStyle(.plain).frame(width:65,alignment:.leading)
                            Text(segment.text.isEmpty ? L("〔空白段落〕") : segment.text).font(.system(size:14)).lineSpacing(5).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                        }.padding(.vertical,10).padding(.horizontal,24).background(playback.time >= segment.start && playback.time < segment.end ? Color.teal.opacity(0.08) : .clear)
                    }
                }}
            } else {
                ScrollView {VStack(alignment:.leading,spacing:14) {
                    if mode == "逐字稿", let revision { Text(L("編輯版本 · \(revision.created.formatted(date:.abbreviated,time:.shortened))")).font(.caption).foregroundStyle(.secondary); if revision.rawAttemptID != record.currentRawID {Text(L("此編輯版源自先前轉錄；最新原始文字可在「原始文字」查看。")).font(.caption).foregroundStyle(.orange)} }
                    Text(text).font(.system(size:15)).lineSpacing(8).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(24)}
            }
        }
        .background(Color(nsColor:.textBackgroundColor))
        .task {loadDocument(); if isWorking {mode = "轉錄預覽"}; playback.player.replaceCurrentItem(with:AVPlayerItem(url:engine.store.media(record)))}
        .onChange(of:record.status) {_,status in
            if status == "running" || status == "queued" {savedPreview = nil; mode = "轉錄預覽"}
            if !isWorking {loadDocument(); if preview == nil && mode == "轉錄預覽" {mode = "逐字稿"}}
        }
        .onChange(of:record.currentRawID) {_,_ in loadDocument(); if mode == "轉錄預覽" {mode = "逐字稿"}}
        .onChange(of:record.currentEditID) {_,_ in loadDocument()}
        .onChange(of:capture.busy) {_,busy in if busy && capture.activeMode.hasSystem {playback.player.pause()}}
        .onDisappear {playback.player.pause()}
        .sheet(isPresented:$editing) {EditSheet(title:record.title,text:$draft) {perform {try engine.saveEdit(record.id,text:draft,sourceID:draftSourceID)}; editing = engine.errorMessage != nil}}
        .sheet(isPresented:$editingInfo) {InfoSheet(record:record) {title,category,keep,date,titleEdited,categoryEdited in perform {try engine.update(record.id,title:title,category:category,keep:keep,recordedDate:date,titleEdited:titleEdited,categoryEdited:categoryEdited)}; editingInfo = engine.errorMessage != nil}}
        .sheet(isPresented:$showingHistory) {HistorySheet(record:record).environmentObject(engine)}
        .sheet(isPresented:$showingArchive) {ArchiveSheet(record:record).environmentObject(engine)}
        .alert(L("移到垃圾桶？"),isPresented:$deleting) { Button(L("取消"),role:.cancel) {}; Button(L("移到垃圾桶"),role:.destructive) {perform {try engine.delete(record.id)}} } message:{Text(L("將從 Library 移除，媒體副本、原始結果與編輯版本都會保留，可從垃圾桶復原。來源檔案與 MacWhisper 模型不受影響。"))}
    }
    private func perform(_ work:() throws -> Void) {do {try work()} catch {engine.errorMessage = error.localizedDescription}}
    private func loadDocument() {
        do {
            raw = try engine.store.raw(record); revision = try engine.store.edit(record); documentError = nil
            if let attempt = record.attempts.last {
                let url = engine.store.attemptFolder(record,attempt.id).appendingPathComponent("preview.json")
                savedPreview = (try? Data(contentsOf:url)).flatMap {try? JSONDecoder().decode(PreviewSnapshot.self,from:$0)}
            }
        } catch {documentError = "無法讀取逐字稿：\(error.localizedDescription)"}
    }
    private func exportMarkdown() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:"md") ?? .plainText]; panel.nameFieldStringValue = record.title.replacingOccurrences(of:"/",with:"-") + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            perform {
                try engine.exportMarkdown(record.id,mode:mode,to:url)
            }
        }
    }
}
struct EditSheet: View {
    let title: String
    @Binding var text: String
    let save: () -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {VStack(alignment:.leading,spacing:16) {
        Text(L("編輯逐字稿")).font(.title2.bold()); Text(L("\(title) · 原始逐字稿會另外保留")).foregroundStyle(.secondary)
        TextEditor(text:$text).font(.system(size:14)).border(.quaternary).frame(minHeight:350)
        HStack {Button(L("取消")) {dismiss()}.keyboardShortcut(.cancelAction); Spacer(); Button(L("另存編輯版本"),action:save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)}
    }.padding(24).frame(width:720,height:570)}
}
struct InfoSheet: View {
    let record: Recording
    let save: (String,String,Bool,Date?,Bool,Bool)->Void
    @State private var title: String
    @State private var category: String
    @State private var keep: Bool
    @State private var date: Date
    @State private var originalTitle: String
    @State private var originalCategory: String
    @State private var originalDate: Date
    @Environment(\.dismiss) var dismiss
    init(record:Recording,save:@escaping (String,String,Bool,Date?,Bool,Bool)->Void) { self.record = record; self.save = save; _title = State(initialValue:record.title); _category = State(initialValue:record.category); _keep = State(initialValue:record.keepForever); _date = State(initialValue:record.namingDate); _originalTitle = State(initialValue:record.title); _originalCategory = State(initialValue:record.category); _originalDate = State(initialValue:record.namingDate) }
    var body: some View {VStack(alignment:.leading,spacing:20) {
        Text(L("錄音資訊")).font(.title2.bold())
        Form {
            TextField(L("名稱"),text:$title)
            Picker(L("分類"),selection:$category) {ForEach(Array(Set(recordingCategories + [record.category])).sorted(),id:\.self) {Text(L($0)).tag($0)}}
            DatePicker(L("錄音日期"),selection:$date,displayedComponents:.date).environment(\.timeZone,TimeZone.current)
            Toggle(L("永久保留"),isOn:$keep)
        }
        Text(L("日期來源：" + (record.recordedDateSource ?? "匯入日期") + "。手動變更的名稱與分類會保留。")).font(.caption).foregroundStyle(.secondary)
        Text(L("永久保留會鎖定 Library 的手動刪除。此版本不會自動清理音檔。")).font(.caption).foregroundStyle(.secondary)
        HStack {Button(L("取消")) {dismiss()}.keyboardShortcut(.cancelAction); Spacer(); Button(L("儲存")) {save(title,category,keep,recordingDatePrefix(date) == recordingDatePrefix(originalDate) ? nil : date,title != originalTitle,category != originalCategory)}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)}
    }.padding(24).frame(width:470)}
}
struct HistorySheet: View {
    @EnvironmentObject var engine: LibraryEngine
    @Environment(\.dismiss) var dismiss
    let record: Recording
    @State private var selectedText: String?
    var body: some View {VStack(alignment:.leading,spacing:16) {
        HStack {Text(L("轉錄與編輯版本")).font(.title2.bold()); Spacer(); Button(L("完成")) {dismiss()}.keyboardShortcut(.cancelAction)}
        List {
            Section(L("原始轉錄 · 每次執行分開保存")) {
                ForEach(record.attempts.reversed()) { attempt in
                    VStack(alignment:.leading,spacing:6) {
                        HStack {Text(attempt.created,style:.date); Text(attempt.created,style:.time); Spacer(); Text(L(attempt.status))}
                        Text(L("語言：" + (TranscriptionLanguage(rawValue:attempt.language ?? "auto")?.label ?? "自動偵測"))).font(.caption).foregroundStyle(.secondary)
                        Text(L(attempt.message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {Button(L("在 Finder 顯示")) {NSWorkspace.shared.open(engine.store.attemptFolder(record,attempt.id))}; if attempt.status == "completed" {Button(L("閱讀原始文字")) {do {selectedText = try TranscriptDocument.read(engine.store.attemptFolder(record,attempt.id)).text} catch {engine.errorMessage = error.localizedDescription}}}}
                    }.padding(.vertical,6)
                }
            }
            Section(L("命名與分類 · Qwen 本機模型")) {
                ForEach((record.metadataAttempts ?? []).reversed()) { attempt in
                    VStack(alignment:.leading,spacing:5) {
                        HStack {Text(attempt.created,style:.date); Text(attempt.created,style:.time); Spacer(); Text(L(attempt.status))}
                        Text(L(attempt.message)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let title = attempt.proposedTitle, let category = attempt.proposedCategory {Text(L("建議：\(title) · \(category)")).textSelection(.enabled)}
                        Text(L("來源轉錄：\(attempt.rawAttemptID.uuidString)")).font(.caption2).foregroundStyle(.secondary)
                        Button(L("查看命名紀錄")) {NSWorkspace.shared.open(engine.store.metadataFolder(record,attempt.id))}
                    }.padding(.vertical,6)
                }
            }
            Section(L("編輯版本 · 可追溯原始轉錄")) {
                ForEach(revisions) { revision in
                    VStack(alignment:.leading,spacing:5) {Text(L(revision.created.formatted(date:.abbreviated,time:.standard))); Text(L("來源轉錄：\(revision.rawAttemptID.uuidString)")).font(.caption).foregroundStyle(.secondary); Button(L("閱讀這個版本")) {selectedText = revision.text} }
                }
            }
        }
        if let selectedText {ScrollView {Text(selectedText).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12)}.frame(height:220).background(.quaternary.opacity(0.3))}
    }.padding(24).frame(width:760,height:650)}
    var revisions: [EditRevision] {
        let folder = engine.store.folder(record).appendingPathComponent("edits")
        return ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).compactMap {url in guard let data = try? Data(contentsOf:url) else {return nil}; return try? JSONDecoder().decode(EditRevision.self,from:data)}.sorted {$0.created > $1.created}
    }
}

struct ArchiveSheet: View {
    @EnvironmentObject var engine: LibraryEngine
    @Environment(\.dismiss) var dismiss
    let record: Recording
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text(L("歸檔與校驗資訊")).font(.title2.bold()); Spacer(); Button(L("完成")) {dismiss()}}
            Text(L("Library 管理一份媒體副本。重複匯入不會另存媒體或重新轉錄；來源檔案不會移動或刪除。")).foregroundStyle(.secondary)
            LabeledContent(L("檔案大小"),value:ByteCountFormatter.string(fromByteCount:record.bytes,countStyle:.file))
            LabeledContent(L("歸檔校驗"),value:record.archivedAt?.formatted(date:.abbreviated,time:.standard) ?? L("舊版項目：下次匯入時驗證"))
            Text(L(engine.store.media(record).path)).textSelection(.enabled).font(.caption)
            Text(L("SHA256：\(record.contentSHA256 ?? "尚未建立")")).textSelection(.enabled).font(.system(.caption,design:.monospaced))
            if record.audioSHA256 != nil {Text(L("已建立音軌指紋，可辨認只更名或改變容器 metadata 的相同音訊。")).font(.caption).foregroundStyle(.secondary)}
            Button(L("在 Finder 顯示歸檔副本")) {NSWorkspace.shared.activateFileViewerSelecting([engine.store.media(record)])}
        }.padding(24).frame(width:570)
    }
}

struct LivePreviewView: View {
    let snapshot: PreviewSnapshot?
    let isWorking: Bool
    @State private var follow = true
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Label(L(isWorking ? "轉錄中 · 預覽文字可能調整" : snapshot?.isFinal == true ? "轉錄預覽紀錄 · 正式結果請看原始文字" : "未完成預覽 · 非正式原始稿"),systemImage:isWorking ? "waveform" : "exclamationmark.circle")
                Spacer()
                Toggle(L("跟隨文字"),isOn:$follow).toggleStyle(.checkbox)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,10)
            if let snapshot, !snapshot.text.isEmpty {
                ScrollViewReader {reader in
                    ScrollView {
                        VStack(alignment:.leading,spacing:12) {
                            Text(snapshot.text).font(.system(size:15)).lineSpacing(8).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                            Color.clear.frame(height:1).id("preview-bottom")
                        }.padding(24)
                    }.onChange(of:snapshot.updatedAt) {_,_ in if follow {reader.scrollTo("preview-bottom",anchor:.bottom)}}
                }
            } else {
                ContentUnavailableView(L("準備逐字稿預覽"),systemImage:"waveform",description:Text(L("模型載入及音訊準備完成後，辨識中的文字會逐步顯示。")))
            }
        }
    }
}

struct CaptureControls: View {
    @EnvironmentObject var capture: CaptureController
    @AppStorage("importTranscriptionLanguage") private var language = "auto"
    @State private var showingDrafts = false
    @AppStorage("captureMode") private var modeValue = "both"
    var mode:CaptureMode {CaptureMode(rawValue:modeValue) ?? .both}
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label(L("錄音"),systemImage:"record.circle").font(.headline)
            if !capture.busy {
                Picker(L("來源"),selection:$modeValue) {ForEach(CaptureMode.allCases,id:\.rawValue) {Text(L($0.label)).tag($0.rawValue)}}.font(.caption)
                Text(L(mode == .both ? "Mac 內建麥克風＋全部系統聲音" : mode == .system ? "全部 App 播放的聲音，含通知音" : "系統預設麥克風與輸入音量")).font(.caption).foregroundStyle(.secondary)
            } else {Text(L(capture.activeMode.label + " · " + capture.inputLabel)).font(.caption).foregroundStyle(.secondary)}
            if capture.recording {
                HStack {
                    Circle().fill(capture.state == .paused ? .orange : .red).frame(width:8,height:8)
                    Text(L(timeLabel(capture.elapsed))).monospacedDigit().font(.title2)
                    Spacer()
                    Text(L(capture.state == .paused ? "已暫停" : "錄音中")).font(.caption).foregroundStyle(.secondary)
                }
                if capture.activeMode.hasMicrophone {HStack {Text(L("麥克風")).font(.caption2).frame(width:76,alignment:.leading);ProgressView(value:capture.microphoneLevel).tint(.teal).accessibilityLabel(L("麥克風音量"))}}
                if capture.activeMode.hasSystem {HStack {Text(L("系統聲音")).font(.caption2).frame(width:76,alignment:.leading);ProgressView(value:capture.systemLevel).tint(.blue).accessibilityLabel(L("系統聲音音量"))}}
                if capture.activeMode.hasSystem {Text(L("請確認播放聲音時，系統音量條有反應。")).font(.caption2).foregroundStyle(.secondary)}
                HStack {
                    Button(L(capture.state == .paused ? "繼續" : "暫停")) {capture.pauseOrResume()}
                    Button(L("停止並儲存")) {capture.stop()}.buttonStyle(.borderedProminent)
                }
            } else if capture.busy {
                HStack {ProgressView().controlSize(.small);Text(L(capture.state == .requesting ? "正在準備與授權…" : "正在儲存錄音…")).font(.caption)}
            } else {
                Picker(L("語言"),selection:$language) {ForEach(TranscriptionLanguage.allCases,id:\.rawValue) {Text(L($0.label)).tag($0.rawValue)}}.font(.caption)
                Button {Task {await capture.start(language:language,mode:mode)}} label:{Label(L("開始錄音"),systemImage:"record.circle").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).tint(.red)
            }
            if !capture.drafts.isEmpty {
                Button(L("待處理錄音 \(capture.drafts.count) 份…")) {showingDrafts = true}.font(.caption).disabled(capture.busy)
            }
            if let error = capture.errorMessage {
                Text(L(error)).font(.caption).foregroundStyle(.orange).lineLimit(4).help(L(error))
                VStack(alignment:.leading,spacing:5) {
                    Button(L("麥克風設定")) {NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)}
                    Button(L("系統錄音設定")) {NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
                    Button(L("關閉提示")) {capture.errorMessage = nil}
                }.font(.caption).buttonStyle(.link)
            }
        }
        .sheet(isPresented:$showingDrafts) {CaptureDraftsView().environmentObject(capture)}
    }
}
struct CaptureDraftsView: View {
    @EnvironmentObject var capture: CaptureController
    @Environment(\.dismiss) private var dismiss
    @State private var discarding: CaptureDraft?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L("待處理錄音")).font(.title2.bold())
            Text(L("先前中斷或尚未歸檔的錄音會保留在這裡。儲存後會加入 Library 並開始轉錄。")).foregroundStyle(.secondary)
            List(capture.drafts) {draft in
                VStack(alignment:.leading,spacing:8) {
                    Text(L(draft.startedAt.formatted(date:.abbreviated,time:.standard))).font(.headline)
                    Text(L((draft.mode ?? .microphone).label)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L("儲存並轉錄")) {Task {await capture.saveDraft(draft);if capture.drafts.isEmpty {dismiss()}}}.buttonStyle(.borderedProminent)
                        Button(L("顯示檔案")) {NSWorkspace.shared.activateFileViewerSelecting([capture.engine.captureMedia(draft)])}
                        Button(L("捨棄…"),role:.destructive) {discarding = draft}
                    }.disabled(capture.busy)
                }.padding(.vertical,6)
            }.frame(minHeight:160)
            if let error = capture.errorMessage {Text(L(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
            HStack {if capture.busy {ProgressView().controlSize(.small);Text(L("正在儲存…"))};Spacer();Button(L("關閉")) {dismiss()}.keyboardShortcut(.cancelAction)}
        }.padding(24).frame(width:570,height:410)
        .alert(L("捨棄這份未歸檔錄音？"),isPresented:Binding(get:{discarding != nil},set:{if !$0 {discarding = nil}})) {
            Button(L("取消"),role:.cancel) {discarding = nil}
            Button(L("捨棄"),role:.destructive) {if let draft = discarding {capture.discard(draft)};discarding = nil}
        } message:{Text(L("將刪除這份待處理錄音，無法復原。已歸檔的 Library 錄音不受影響。"))}
    }
}
