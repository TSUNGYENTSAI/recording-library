import Foundation

struct ModelConfiguration: Codable, Equatable {
    var whisperModelPath:String
    var tokenizerPath:String
    var textModelPath:String
    var pythonPath:String
    var ffmpegPath:String
    var ffprobePath:String
    var automaticMetadata:Bool
    static func executable(_ name:String) -> String {
        for directory in ["/opt/homebrew/bin","/usr/local/bin","/usr/bin"] {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath:path) {return path}
        }
        return "/opt/homebrew/bin/" + name
    }
    static func defaults(root:URL) -> ModelConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appendingPathComponent("Library/Application Support/MacWhisper/models/whisperkit/models")
        let model = "openai_whisper-large-v3-v20240930"
        func prefer(_ owned:URL,_ existing:URL) -> String {FileManager.default.fileExists(atPath:owned.path) || !FileManager.default.fileExists(atPath:existing.path) ? owned.path : existing.path}
        return ModelConfiguration(
            whisperModelPath:prefer(root.appendingPathComponent("Models/WhisperKit/"+model),legacy.appendingPathComponent("argmaxinc/whisperkit-coreml/"+model)),
            tokenizerPath:prefer(root.appendingPathComponent("Models/Tokenizers/whisper-large-v3"),legacy.appendingPathComponent("openai/whisper-large-v3")),
            textModelPath:root.appendingPathComponent("Models/Qwen3-1.7B-4bit").path,
            pythonPath:root.appendingPathComponent("Runtime/text-model/bin/python").path,
            ffmpegPath:executable("ffmpeg"),ffprobePath:executable("ffprobe"),automaticMetadata:true)
    }
    static func load(root:URL) throws -> ModelConfiguration {
        let file = root.appendingPathComponent("model-settings.json")
        guard FileManager.default.fileExists(atPath:file.path) else {return defaults(root:root)}
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:file))
    }
    func save(root:URL) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to:root.appendingPathComponent("model-settings.json"),options:.atomic)
    }
    var readiness:[String] {
        var missing:[String] = []
        for (label,path) in [("Whisper AudioEncoder",whisperModelPath+"/AudioEncoder.mlmodelc"),("Whisper TextDecoder",whisperModelPath+"/TextDecoder.mlmodelc"),("tokenizer",tokenizerPath+"/tokenizer.json")] {
            if !FileManager.default.fileExists(atPath:path) {missing.append(label)}
        }
        for (label,path) in [("FFmpeg",ffmpegPath),("FFprobe",ffprobePath)] {if !FileManager.default.isExecutableFile(atPath:path) {missing.append(label)}}
        if automaticMetadata {
            if !FileManager.default.isExecutableFile(atPath:pythonPath) {missing.append("Python / MLX runtime")}
            if !FileManager.default.fileExists(atPath:textModelPath+"/config.json") {missing.append("Qwen / MLX model")}
        }
        return missing
    }
}
