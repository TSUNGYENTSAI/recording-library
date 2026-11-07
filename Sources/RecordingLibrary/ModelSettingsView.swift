import SwiftUI
import AppKit

struct ModelSettingsView:View {
    @EnvironmentObject var engine:LibraryEngine
    @State private var draft:ModelConfiguration?
    @State private var message = ""
    @State private var installing = false
    @State private var confirmingSetup = false
    @State private var runner:ProcessRunner?
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text(L("模型與本機工具")).font(.title2.bold())
                Text(L("Early preview · Apple Silicon · 模型與 runtime 另行下載；轉錄與命名時不連線。")).font(.caption).foregroundStyle(.secondary)
                if draft != nil {
                    path("Whisper Core ML 模型",key:\.whisperModelPath,directory:true)
                    path("相符的 tokenizer",key:\.tokenizerPath,directory:true)
                    Toggle(L("轉錄後自動命名與分類"),isOn:value(\.automaticMetadata))
                    Text(L("關閉時，Whisper 轉錄完成即標示已完成；不需要 Qwen。逐字稿不會交給文字模型改寫。")).font(.caption).foregroundStyle(.secondary)
                    if draft?.automaticMetadata == true {
                        path("Qwen / 相容 MLX 文字模型",key:\.textModelPath,directory:true)
                        path("Python（已安裝 MLX-LM）",key:\.pythonPath,directory:false)
                    }
                    path("FFmpeg",key:\.ffmpegPath,directory:false)
                    path("FFprobe",key:\.ffprobePath,directory:false)
                    let missing = draft!.readiness
                    Label(L(missing.isEmpty ? "模型與工具路徑已就緒" : "缺少："+missing.joined(separator:"、")),systemImage:missing.isEmpty ? "checkmark.circle" : "exclamationmark.circle").font(.caption).foregroundStyle(missing.isEmpty ? Color.teal : Color.orange)
                    HStack {
                        Button(L("儲存設定")) {save()}.buttonStyle(.borderedProminent)
                        Button(L("重新偵測預設位置")) {draft = .defaults(root:engine.store.root)}
                    }.disabled(engine.isBusy || installing)
                    Divider()
                    Button(L("準備推薦模型與 runtime…")) {confirmingSetup = true}.disabled(engine.isBusy || installing)
                    Text(L("先安裝 Homebrew 的 uv、ffmpeg：brew install uv ffmpeg。推薦 Whisper large-v3 + Qwen3-1.7B-4bit；既有相容模型原地重用，不複製或移除。自選模型需符合 WhisperKit/Core ML 或 MLX 格式，其他變體尚未驗證。")).font(.caption).foregroundStyle(.secondary)
                    if installing {HStack {ProgressView().controlSize(.small);Text(L("安裝中，詳情請看 Library/setup.log"))};Button(L("停止安裝")) {runner?.cancel()}}
                    if !message.isEmpty {Text(L(message)).font(.caption).textSelection(.enabled)}
                    Button(L("開啟 Library 儲存位置")) {NSWorkspace.shared.open(engine.store.root)}
                }
            }.padding(24)
        }.frame(width:650,height:650)
        .onAppear {draft = engine.configuration}
        .alert(L("下載本機模型與執行環境？"),isPresented:$confirmingSetup) {
            Button(L("取消"),role:.cancel) {}
            Button(L("開始準備")) {Task {await setup()}}
        } message:{Text(L("這個步驟會連線至 Hugging Face 與 Python 套件來源；模型合計約 2.5 GB，另有執行環境與暫存。請準備至少 6 GB 可用空間。錄音與逐字稿不會上傳。"))}
    }
    private func value<T>(_ key:WritableKeyPath<ModelConfiguration,T>) -> Binding<T> {Binding(get:{draft![keyPath:key]},set:{draft![keyPath:key] = $0})}
    private func path(_ title:String,key:WritableKeyPath<ModelConfiguration,String>,directory:Bool) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(L(title)).font(.caption)
            HStack {TextField(L(title),text:value(key)).textFieldStyle(.roundedBorder);Button(L("選擇…")) {
                let panel = NSOpenPanel();panel.canChooseDirectories = directory;panel.canChooseFiles = !directory;panel.allowsMultipleSelection = false
                if panel.runModal() == .OK,let url = panel.url {draft![keyPath:key] = url.path}
            }}
        }.disabled(installing || engine.isBusy)
    }
    private func save() {do {if let draft {try engine.updateConfiguration(draft);message = "設定已儲存，下次工作使用新設定。"}} catch {message = error.localizedDescription}}
    private func setup() async {
        guard !engine.isBusy else {return}
        installing = true;message = "";let job = ProcessRunner();runner = job
        defer {installing = false;runner = nil}
        do {
            guard let script = Bundle.main.resourceURL?.appendingPathComponent("Setup/setup-models.sh"),FileManager.default.fileExists(atPath:script.path) else {throw LibraryError("找不到安裝工具；請依 README 執行 Scripts/setup-models.sh。")}
            _ = try await job.run("/bin/bash",[script.path,engine.store.root.path] + (draft?.automaticMetadata == false ? ["--no-text-model"] : []),log:engine.store.root.appendingPathComponent("setup.log"))
            let settings = try ModelConfiguration.load(root:engine.store.root)
            try engine.updateConfiguration(settings);draft = settings;message = "準備完成。已保留既有模型選擇，請確認上方路徑。"
        } catch {message = error.localizedDescription}
    }
}
