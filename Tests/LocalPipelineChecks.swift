import Foundation
@main struct LocalPipelineChecks {
 static func check(_ condition:@autoclosure () throws -> Bool,_ message:String) throws {if try !condition() {throw LibraryError(message)}}
 @MainActor static func wait(_ engine:LibraryEngine) async throws {
  let deadline=Date().addingTimeInterval(300)
  while engine.isBusy && Date()<deadline {try await Task.sleep(nanoseconds:200_000_000)}
  try check(!engine.isBusy,"Pipeline timed out")
 }
 @MainActor static func main() async throws {
  let repo=URL(fileURLWithPath:CommandLine.arguments[1]);let source=URL(fileURLWithPath:CommandLine.arguments[2])
  let root=repo.appendingPathComponent(".build/local-pipeline/\(UUID().uuidString)")
  defer {try? FileManager.default.removeItem(at:root)}
  let app=repo.appendingPathComponent("dist/Recording Library.app")
  let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:app.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
  let helper=app.appendingPathComponent("Contents/Resources/WhisperValidation/"+(info["RecordingLibraryWorker"] as! String))
  var configuration=try ModelConfiguration.load(root:LibraryEngine.defaultRoot)
  try check(configuration.readiness.isEmpty,"Configure local model files and runtime before integration testing")
  configuration.automaticMetadata=false
  let engine=try LibraryEngine(root:root,helper:helper,configuration:configuration)
  defer {engine.shutdown()}
  let before=try contentDigest(source)
  let ids=await engine.importURLs([source],language:"en");try check(ids.count==1,"Import failed")
  try await wait(engine)
  let off=try engine.record(ids[0])
  try check(off.status=="completed" && off.metadataSkipped==true && off.currentRawID != nil,"Whisper-only flow failed: \(off.attempts.last?.message ?? "")")
  print("WHISPER-ONLY COMPLETED");fflush(stdout)
  let rawURL=engine.store.attemptFolder(off,off.currentRawID!).appendingPathComponent("transcript.json")
  let rawHash=try contentDigest(rawURL)
  try engine.enqueueOrganization(off.id);try await wait(engine)
  let named=try engine.record(off.id)
  try check(named.status=="completed" && named.metadataSkipped==false && named.currentMetadata?.status=="completed","Manual local naming failed: \(named.currentMetadata?.message ?? "")")
  try check(named.attempts.count==1 && contentDigest(rawURL)==rawHash,"Naming reran ASR or changed raw")
  configuration.automaticMetadata=true;try engine.updateConfiguration(configuration)
  try engine.enqueue(off.id,language:"en");try await wait(engine)
  let automatic=try engine.record(off.id)
  try check(automatic.status=="completed" && automatic.attempts.count==2 && automatic.currentMetadata?.status=="completed","Automatic pipeline failed")
  let duplicate=await engine.importURLs([source]);try check(duplicate==[off.id] && !engine.isBusy,"Duplicate import started another job")
  let reopened=try LibraryEngine(root:root,helper:helper,configuration:configuration)
  try check(try reopened.record(off.id).status=="completed" && reopened.record(off.id).currentRawID==automatic.currentRawID,"Restart lost result")
  try check(try contentDigest(source)==before && contentDigest(rawURL)==rawHash,"Original fixture or previous raw modified")
  print("LOCAL PIPELINE CHECKS PASSED: selected model paths, Whisper-only, manual Qwen, automatic Whisper/Qwen, restart, dedup and raw integrity")
 }
}
