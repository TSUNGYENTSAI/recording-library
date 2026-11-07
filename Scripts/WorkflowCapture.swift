// Capture the production SwiftUI/AppKit view tree with fictional fixture state.
// This executable is separate from the shipped app. No microphone, system tap or models are started.
import AppKit
import SwiftUI
import AVFoundation

@MainActor final class FixtureInput: AudioRecordingSession {
    var position: Double = 12
    var elapsed:TimeInterval {position}
    var power:Float {-7}
    var systemPower:Float {-10}
    var inputLabel:String {L("麥克風＋系統聲音")}
    var finished:((Bool,String?)->Void)?
    init(url:URL) throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let file=try AVAudioFile(forWriting:url,settings:format.settings)
        let silence=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
        silence.frameLength=16000
        silence.floatChannelData![0].initialize(repeating:0,count:16000)
        for _ in 0..<45 {try file.write(from:silence)}
    }
    func record()->Bool {true}
    func pause() {}
    func stop() {let callback=finished;finished=nil;callback?(true,nil)}
    func updateMeters() {}
}

@MainActor final class WorkflowRenderer {
    let root:URL
    let engine:LibraryEngine
    var capture:CaptureController
    let window:NSWindow
    let host:NSHostingView<AnyView>
    var input:FixtureInput?
    var frames:[String]=[]
    let lines=[
        "今天討論戴耳機開會時，如何把麥克風與系統聲音一起錄下來。",
        "停止錄音後，用 Whisper 在本機轉錄，再由 Qwen 建議標題與分類。",
        "我們希望離線工作，也能搜尋 API 和中文關鍵字。原始逐字稿要另外保留。"
    ]
    init(root:URL) throws {
        self.root=root
        guard root.path.contains("/.build/workflow."), !FileManager.default.fileExists(atPath:root.path) else {throw LibraryError("Capture requires a fresh isolated .build/workflow directory")}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let model=root.appendingPathComponent("fixture-model")
        for folder in ["AudioEncoder.mlmodelc","TextDecoder.mlmodelc"] {try FileManager.default.createDirectory(at:model.appendingPathComponent(folder),withIntermediateDirectories:true)}
        for name in ["tokenizer.json","config.json"] {try Data("{}".utf8).write(to:model.appendingPathComponent(name))}
        let config=ModelConfiguration(whisperModelPath:model.path,tokenizerPath:model.path,textModelPath:model.path,pythonPath:"/usr/bin/true",ffmpegPath:ModelConfiguration.executable("ffmpeg"),ffprobePath:ModelConfiguration.executable("ffprobe"),automaticMetadata:true)
        engine=try LibraryEngine(root:root.appendingPathComponent("Library"),helper:URL(fileURLWithPath:"/usr/bin/false"),recover:false,configuration:config)
        capture=CaptureController(engine:engine,permission:{true})
        host=NSHostingView(rootView:AnyView(EmptyView()))
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.ignoresMouseEvents=true
        window.title="Recording Library";window.appearance=NSAppearance(named:.darkAqua)
        window.contentView=host;window.setContentSize(NSSize(width:1280,height:820))
        window.center();window.orderBack(nil)
        UserDefaults.standard.set("both",forKey:"captureMode")
        UserDefaults.standard.set("auto",forKey:"importTranscriptionLanguage")
    }
    func shot(_ name:String,selection:UUID?=nil,query:String="",filter:String="全部錄音") async throws {
        host.rootView=AnyView(LibraryView.workflowFixture(selection:selection,query:query,filter:filter).environmentObject(engine).environmentObject(capture).frame(minWidth:1040,minHeight:660).id(name))
        try await Task.sleep(nanoseconds:1_200_000_000)
        host.layoutSubtreeIfNeeded();host.displayIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw LibraryError("Could not allocate native view capture")}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else {throw LibraryError("Could not encode capture")}
        try data.write(to:root.appendingPathComponent(name+".png"));frames.append(name)
    }
    func save(_ record:Recording) throws {try engine.store.save(record);try engine.reload()}
    func run() async throws {
        capture=CaptureController(engine:engine,permission:{true},makeSession:{[weak self] url in let input=try FixtureInput(url:url);self?.input=input;return input})
        try await shot("01-start")
        await capture.start(language:"auto",mode:.both)
        capture.refreshMeters()
        try await shot("02-recording")
        input?.position=26;capture.refreshMeters()
        try await shot("03-stop")
        // Termination path saves this synthetic CAF without enqueueing a real transcription job.
        await capture.finishForTermination()
        guard var record=engine.recordings.first else {throw LibraryError("Synthetic recording was not archived: "+(capture.errorMessage ?? ""))}
        capture=CaptureController(engine:engine,permission:{true})
        record.title="2026-01-15 錄音 10-00-00"
        record.recordedAt=ISO8601DateFormatter().date(from:"2026-01-15T02:00:00Z")
        record.created=record.recordedAt!
        var attempt=Attempt();attempt.status="running";attempt.loadingMode="incremental";attempt.language="auto"
        record.attempts=[attempt];try save(record)
        engine.activeID=record.id;engine.activity="正在轉錄";engine.activeSince=Date()
        engine.livePreviews[record.id]=PreviewSnapshot(text:lines[0],processedSeconds:12,updatedAt:Date().timeIntervalSince1970,isFinal:false)
        try await shot("04-transcribing",selection:record.id)
        engine.livePreviews[record.id]=PreviewSnapshot(text:lines.prefix(2).joined(separator:"\n\n"),processedSeconds:26,updatedAt:Date().timeIntervalSince1970,isFinal:false)
        try await shot("05-preview",selection:record.id)
        let raw=engine.store.attemptFolder(record,attempt.id)
        try FileManager.default.createDirectory(at:raw,withIntermediateDirectories:true)
        let text=lines.joined(separator:"\n\n")
        try text.write(to:raw.appendingPathComponent("transcript.txt"),atomically:true,encoding:.utf8)
        let segments=lines.enumerated().map {i,line in ["id":i,"start":i*15,"end":(i+1)*15,"text":line] as [String:Any]}
        try JSONSerialization.data(withJSONObject:[["text":text,"segments":segments]]).write(to:raw.appendingPathComponent("transcript.json"))
        record.attempts[0].status="completed";record.currentRawID=attempt.id
        var metadata=MetadataAttempt(rawAttemptID:attempt.id);metadata.status="running"
        record.metadataAttempts=[metadata];try save(record)
        engine.activity="整理標題與分類"
        try await shot("06-naming",selection:record.id)
        record.title="2026-01-15 · 耳機會議的本機錄音流程";record.category="產品討論"
        metadata.status="completed";metadata.proposedTitle=record.title;metadata.proposedCategory=record.category;metadata.titleApplied=true;metadata.categoryApplied=true;metadata.finished=Date()
        record.metadataAttempts=[metadata];try save(record)
        engine.activeID=nil;engine.activity="";engine.livePreviews=[:]
        try await shot("07-completed",selection:record.id)
        record=try engine.store.saveEdit(record,text:text+"\n\n（人工補充：API 是工程術語，原始稿維持不變。）")
        try engine.reload()
        try await shot("08-review",selection:record.id)
        try await shot("09-search",selection:record.id,query:"API")
        try engine.store.remove(record);try engine.reload()
        try await shot("10-trash",selection:record.id,filter:"垃圾桶")
        record=try engine.store.restore(record);record.keepForever=true;try save(record)
        try await shot("11-restored",selection:record.id,filter:"永久保留")
        try JSONSerialization.data(withJSONObject:["frames":frames,"source":"production LibraryView with fictional fixture state","recordingAndInference":"replayed; no live capture or inference"],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("manifest.json"))
        engine.shutdown();window.orderOut(nil)
        print("Captured native views: \(root.lastPathComponent) (\(frames.count) frames)")
    }
}
@main struct WorkflowCapture {
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task {@MainActor in
            do {
                guard CommandLine.arguments.count>1 else {throw LibraryError("Pass a fresh isolated capture directory")}
                let renderer=try WorkflowRenderer(root:URL(fileURLWithPath:CommandLine.arguments[1]))
                try await renderer.run()
                exit(0)
            } catch {fputs("Native capture failed: \(error)\n",stderr);exit(1)}
        }
        app.run()
    }
}
