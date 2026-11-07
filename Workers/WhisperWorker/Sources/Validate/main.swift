import Foundation
import WhisperKit
import Darwin

final class PreviewEmitter: @unchecked Sendable {
 private let lock = NSLock()
 private let directory: URL
 private var confirmed: [TranscriptionSegment] = []
 private var draft = ""
 private var lastWrite = Date.distantPast
 private var finished = false
 private var completedWindows = 0
 private var pendingWindow = -1
 private var highestTokenCount = 0
 init(directory: URL) throws {
  self.directory = directory
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
 }
 func partial(_ progress: TranscriptionProgress) {
  lock.lock(); defer {lock.unlock()}
  guard !finished, progress.windowId >= completedWindows else {return}
  if progress.windowId > pendingWindow {pendingWindow = progress.windowId; highestTokenCount = 0}
  guard progress.windowId == pendingWindow, progress.tokens.count >= highestTokenCount else {return}
  highestTokenCount = progress.tokens.count; draft = progress.text
  if Date().timeIntervalSince(lastWrite) >= 0.35 {write()}
 }
 func segments(_ segments: [TranscriptionSegment]) {
  lock.lock(); defer {lock.unlock()}
  guard !finished else {return}
  confirmed.append(contentsOf:segments); completedWindows += 1; pendingWindow = completedWindows; highestTokenCount = 0; draft = ""; write()
 }
 func finish(_ text: String) {
  lock.lock(); defer {lock.unlock()}
  finished = true; draft = ""; write(finalText:text)
 }
 private func write(finalText: String? = nil) {
  let text = finalText ?? (confirmed.map(\.text).joined(separator:"\n") + (draft.isEmpty ? "" : "\n" + draft))
  guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
  let event: [String:Any] = ["text":text,"processedSeconds":confirmed.map {Double($0.end)}.max() ?? 0,"updatedAt":Date().timeIntervalSince1970,"isFinal":finalText != nil]
  do {
   let data = try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys])
   try data.write(to:directory.appendingPathComponent("preview.json"),options:.atomic)
   lastWrite = Date(); print("RL_PREVIEW"); fflush(stdout)
  } catch {print("RL_PREVIEW_WARNING: \(error.localizedDescription)"); fflush(stdout)}
 }
}

@main struct Validate {
 static func main() async throws {
  let args = CommandLine.arguments
  guard args.count == 3 else { print("Usage: Validate AUDIO OUTPUT_DIRECTORY"); exit(2) }
  let settings = ProcessInfo.processInfo.environment
  guard let modelPath = settings["RECORDING_LIBRARY_MODEL_DIR"], let tokenizerPath = settings["RECORDING_LIBRARY_TOKENIZER_DIR"] else {throw NSError(domain:"RecordingLibrary",code:2,userInfo:[NSLocalizedDescriptionKey:"Select model and tokenizer paths in App settings."])}
  let model = URL(fileURLWithPath:modelPath)
  let tokenizer = URL(fileURLWithPath:tokenizerPath)
  guard FileManager.default.fileExists(atPath:tokenizer.appendingPathComponent("tokenizer.json").path) else {throw NSError(domain:"RecordingLibrary",code:2,userInfo:[NSLocalizedDescriptionKey:"Local tokenizer missing"])}
  let started = Date()
  print("Loading selected local Whisper model"); fflush(stdout)
  let kit = try await WhisperKit(WhisperKitConfig(modelFolder: model.path, tokenizerFolder: tokenizer, verbose: false, prewarm: true, load: true, download: false))
  let loaded = Date()
  print("Model loaded in \(loaded.timeIntervalSince(started)) seconds; transcribing \(args[1])"); fflush(stdout)
  let env = ProcessInfo.processInfo.environment
  let mode: AudioInputOptions.AudioLoadingMode = env["VALIDATION_INCREMENTAL"] == "1" ? .incremental : .fullFile
  let prompt = env["VALIDATION_PROMPT"]
  let requestedLanguage = env["VALIDATION_LANGUAGE"].flatMap { ["zh","en"].contains($0) ? $0 : nil }
  let options = DecodingOptions(task: .transcribe, language:requestedLanguage, detectLanguage:requestedLanguage == nil, skipSpecialTokens: true, promptTokens: prompt.flatMap { kit.tokenizer?.encode(text: $0) }, concurrentWorkerCount: 1)
  let reporter = Task {
   while !Task.isCancelled {
    try? await Task.sleep(nanoseconds: 30_000_000_000)
    if !Task.isCancelled { print("Still transcribing: \(Int(Date().timeIntervalSince(loaded))) seconds elapsed"); fflush(stdout) }
   }
  }
  defer { reporter.cancel() }
  let preview = try PreviewEmitter(directory:URL(fileURLWithPath:args[2],isDirectory:true))
  kit.segmentDiscoveryCallback = {segments in preview.segments(segments)}
  let results = try await kit.transcribe(audioPath: args[1], audioInputOptions: AudioInputOptions(audioLoadingMode: mode), decodeOptions: options, callback:{progress in preview.partial(progress); return nil})
  preview.finish(results.map(\.text).joined(separator:"\n"))
  let ended = Date()
  let out = URL(fileURLWithPath: args[2], isDirectory: true)
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(results).write(to: out.appendingPathComponent("transcript.json"))
  try results.map(\.text).joined(separator: "\n").write(to: out.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
  let timestamped = results.flatMap(\.segments).map { String(format: "[%.2f–%.2f] %@", $0.start, $0.end, $0.text) }.joined(separator: "\n")
  try timestamped.write(to: out.appendingPathComponent("timestamped.txt"), atomically: true, encoding: .utf8)
  var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
  let metrics: [String: Any] = ["input": args[1], "requestedLanguage":requestedLanguage ?? "auto", "fullFile": env["VALIDATION_INCREMENTAL"] != "1", "prompt": prompt ?? "", "model": model.lastPathComponent, "loadSeconds": loaded.timeIntervalSince(started), "transcribeSeconds": ended.timeIntervalSince(loaded), "peakRSSBytes": usage.ru_maxrss, "segments": results.flatMap(\.segments).count, "languages": results.map(\.language)]
  try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("metrics.json"))
  print(String(data: try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted]), encoding: .utf8)!); fflush(stdout)
 }
}
