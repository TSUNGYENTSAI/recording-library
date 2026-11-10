import Foundation
@MainActor final class SynchronizingSession:AudioRecordingSession {
 var elapsed:TimeInterval {12}
 var power:Float {-10}
 var warningMessage:String? {"已自動同步音訊來源，錄音持續中。"}
 var finished:((Bool,String?)->Void)?
 func record()->Bool {true}
 func pause() {}
 func updateMeters() {}
 func stop() {let callback=finished;finished=nil;callback?(false,"Synthetic session ended")}
}
@main struct ConfigurationChecks {
 static func check(_ condition:@autoclosure () throws -> Bool,_ message:String) throws {if try !condition() {throw LibraryError(message)}}
 @MainActor static func wait(_ engine:LibraryEngine) async throws {
  let deadline=Date().addingTimeInterval(15)
  while engine.isBusy && Date()<deadline {try await Task.sleep(nanoseconds:50_000_000)}
  try check(!engine.isBusy,"Fixture job timed out")
 }
 @MainActor static func main() async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  var settings=ModelConfiguration.defaults(root:root)
  settings.whisperModelPath=root.appendingPathComponent("Synthetic Model").path
  settings.tokenizerPath=root.appendingPathComponent("Synthetic Tokenizer").path
  settings.pythonPath="/missing/python";settings.textModelPath=root.appendingPathComponent("Missing Model").path
  settings.ffmpegPath="/usr/bin/true";settings.ffprobePath="/usr/bin/true";settings.automaticMetadata=false
  for directory in [settings.whisperModelPath+"/AudioEncoder.mlmodelc",settings.whisperModelPath+"/TextDecoder.mlmodelc",settings.tokenizerPath] {try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)}
  try Data("{}".utf8).write(to:URL(fileURLWithPath:settings.tokenizerPath+"/tokenizer.json"))
  try check(settings.readiness.isEmpty,"Whisper-only setup required Qwen")
  try settings.save(root:root);try check(try ModelConfiguration.load(root:root)==settings,"Settings round-trip failed")
  let helper=root.appendingPathComponent("fixture.py")
  try """
#!/usr/bin/python3
import sys,json
from pathlib import Path
folder=Path(sys.argv[2]);folder.mkdir(parents=True,exist_ok=True)
text='Synthetic Revit API review. This is public test data.'
(folder/'transcript.txt').write_text(text)
(folder/'transcript.json').write_text(json.dumps([{'text':text,'segments':[{'id':0,'start':0,'end':2,'text':text}]}]))
""".write(to:helper,atomically:true,encoding:.utf8)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
  let engine=try LibraryEngine(root:root,helper:helper,configuration:settings)
  var item=Recording(title:"Synthetic fixture",sourcePath:"/synthetic/original.m4a",managedName:"source.m4a",duration:2,bytes:1,isVideo:false)
  try FileManager.default.createDirectory(at:engine.store.folder(item),withIntermediateDirectories:true)
  try Data([0]).write(to:engine.store.media(item));try engine.store.save(item);try engine.reload()
  try engine.enqueue(item.id);try await wait(engine);item=try engine.record(item.id)
  try check(item.status=="completed" && item.metadataSkipped==true && item.metadataAttempts==nil,"Whisper-only did not complete")
  try check(try engine.store.raw(item)?.text.contains("Revit")==true,"Raw result missing")
  let raw=engine.store.attemptFolder(item,item.currentRawID!).appendingPathComponent("transcript.json")
  let digest=try contentDigest(raw)
  try engine.enqueueOrganization(item.id);try await wait(engine)
  let manual=try engine.record(item.id)
  try check(manual.status=="organization_failed" && manual.metadataSkipped==false && manual.currentRawID==item.currentRawID,"Manual naming damaged raw or hid failure")
  try check(try contentDigest(raw)==digest,"Naming modified raw")
  settings.automaticMetadata=true;try engine.updateConfiguration(settings)
  try check(!engine.configuration.readiness.isEmpty,"Missing text runtime not reported")
  let capture=CaptureController(engine:engine,permission:{true},makeSession:{_ in SynchronizingSession()})
  await capture.start(language:"auto",mode:.both)
  capture.refreshMeters()
  try check(capture.state == .recording && capture.warningMessage != nil && capture.errorMessage == nil,"Synchronization notice stopped recording or became a fatal error")
  capture.stop()
  engine.shutdown();print("CONFIGURATION CHECKS PASSED: including nonfatal recording synchronization notice")
 }
}
