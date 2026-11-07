// Reproducible illustrated workflow. No live UI, user Library, audio or models are accessed.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let destination = repo.appendingPathComponent("Docs/Media")
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
let width = 1024, height = 680
let ink = NSColor(calibratedRed:0.91,green:0.94,blue:0.97,alpha:1)
let muted = NSColor(calibratedRed:0.59,green:0.65,blue:0.72,alpha:1)
let teal = NSColor(calibratedRed:0.29,green:0.85,blue:0.75,alpha:1)
let red = NSColor(calibratedRed:0.98,green:0.36,blue:0.39,alpha:1)
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat)->NSColor {NSColor(calibratedRed:r,green:g,blue:b,alpha:1)}
func box(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ fill:NSColor,_ radius:CGFloat = 10) {
    fill.setFill();NSBezierPath(roundedRect:NSRect(x:x,y:y,width:w,height:h),xRadius:radius,yRadius:radius).fill()
}
func text(_ value:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat = 14,_ tint:NSColor = ink,_ w:CGFloat = 900,_ bold:Bool = false) {
    let style = NSMutableParagraphStyle();style.lineBreakMode = .byWordWrapping;style.lineSpacing = 4
    (value as NSString).draw(in:NSRect(x:x,y:y,width:w,height:160),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold : .regular),.foregroundColor:tint,.paragraphStyle:style])
}
let steps = ["Record", "Stop & save", "Transcribe", "Name & classify", "Review & copy", "Manage"]
struct Scene {let step:Int;let title:String;let note:String;let variant:Int;let delay:Double}
let scenes:[Scene] = [
    .init(step:0,title:"Your next meeting starts with Record.",note:"Choose microphone, system audio, or both. Keep listening through headphones.",variant:0,delay:2.5),
    .init(step:0,title:"Capture the conversation on your Mac.",note:"Microphone + system audio • Separate level meters • No virtual audio driver",variant:1,delay:1),
    .init(step:0,title:"Capture the conversation on your Mac.",note:"Recording time is shortened in this illustration.",variant:2,delay:1),
    .init(step:1,title:"Stop recording. The app takes it from here.",note:"Save in place → Queue local transcription. No extra full recording copy.",variant:3,delay:2.5),
    .init(step:2,title:"Watch the transcript appear as Whisper works.",note:"Runs locally with WhisperKit / Core ML. Preview text may change until finalized.",variant:4,delay:1.7),
    .init(step:2,title:"Watch the transcript appear as Whisper works.",note:"This text is fictional; transcription time is shortened.",variant:5,delay:1.7),
    .init(step:2,title:"Keep the original transcript.",note:"Raw results remain separate from your later corrections.",variant:6,delay:1.7),
    .init(step:3,title:"A title and category, ready to find later.",note:"Optional Qwen3-1.7B runs locally. It names and classifies; it does not rewrite the transcript.",variant:7,delay:3),
    .init(step:4,title:"Review, correct, and take the text with you.",note:"Play audio at a timestamp. Save corrections as a linked edit. Copy or export Markdown.",variant:8,delay:3),
    .init(step:4,title:"Find the detail you remember.",note:"Search titles and transcript text, including Chinese phrases and English terms.",variant:9,delay:2.5),
    .init(step:4,title:"One click to copy your transcript.",note:"Paste into your notes or ChatGPT yourself. No account or cloud integration is required.",variant:10,delay:2.5),
    .init(step:5,title:"A Library you can keep organized.",note:"Date + category + title. Move to Trash and restore; pin recordings you want to keep.",variant:11,delay:3),
    .init(step:5,title:"Record now. Find it when you need it.",note:"Also supports importing existing audio and video. Apple Silicon • Early preview",variant:12,delay:3)
]
func frame(_ scene:Scene)->CGImage {
    let image = NSImage(size:NSSize(width:width,height:height),flipped:true) {_ in
        box(0,0,1024,680,color(0.055,0.071,0.09),0)
        text("Recording Library",26,20,23,ink,800,true)
        text("LOCAL AUDIO → USEFUL TEXT",26,53,11,teal,800,true)
        box(780,23,218,29,color(0.14,0.18,0.22));text("Apple Silicon · Early preview",793,29,12,muted,210)
        for (i,step) in steps.enumerated() {
            let x = CGFloat(26+i*166)
            box(x,82,156,31,i == scene.step ? teal : color(0.12,0.15,0.18),7)
            text("\(i+1)  \(step)",x+11,89,12,i == scene.step ? color(0.05,0.12,0.11) : muted,150,true)
        }
        box(26,131,972,408,color(0.105,0.127,0.153),12)
        box(26,131,188,408,color(0.085,0.105,0.127),12)
        text("LIBRARY",42,149,10,muted,170,true)
        let sidebar = ["All recordings", "In progress", "Completed", "Trash"]
        for (i,label) in sidebar.enumerated() {
            let y = CGFloat(178+i*30)
            if (scene.step == 2 && i == 1) || (scene.step > 2 && i == 2) || (scene.step < 2 && i == 0) {box(35,y-3,170,26,color(0.16,0.21,0.24),6)}
            text(label,45,y,12,ink,160)
        }
        text("CATEGORIES",42,310,10,muted,170,true)
        text("Product discussion\nPersonal ideas\nLearning notes",45,335,12,muted,160)
        box(37,420,166,105,color(0.13,0.16,0.19),8)
        text("Mic + system audio",48,430,11,muted,150)
        let isRecording = scene.variant == 1 || scene.variant == 2
        box(47,455,146,30,isRecording ? red : color(0.75,0.23,0.28),7)
        text(isRecording ? "Stop and save" : "Start recording",59,462,12,ink,135,true)
        text(isRecording ? (scene.variant == 1 ? "00:18  •  Recording" : "00:36  •  Recording") : "Local · Private",48,497,11,isRecording ? red : teal,150)
        box(215,131,236,408,color(0.115,0.14,0.165),0)
        text(scene.variant == 9 ? "Search: offline" : "All recordings",233,149,16,ink,210,true)
        if scene.variant == 0 {
            text("Press Record to begin",237,274,15,muted,185,true)
            text("Meetings. Ideas. Notes.",237,310,12,muted,190)
            text("Import audio / video…",237,491,11,muted,190)
        } else {
            box(225,189,216,100,color(0.16,0.22,0.25),7)
            let named = scene.variant >= 7
            text(named ? "2026-01-15\n離線錄音流程" : "2026-01-15\nRecording 10:00",237,201,13,ink,192,true)
            text(scene.step < 2 ? "Recording…" : scene.step == 2 ? "Transcribing…" : named ? "Completed · Product discussion" : "Preparing…",237,260,10,scene.step > 2 ? teal : muted,195)
            if scene.variant >= 11 {
                box(225,309,216,72,color(0.14,0.17,0.20),7)
                text("2026-01-14 · A walk idea",237,321,12,ink,195,true)
                text("Personal ideas · Completed",237,349,10,muted,195)
            }
        }
        let x:CGFloat = 473
        text(scene.variant >= 7 ? "離線錄音流程" : "Your recording",x,152,20,ink,500,true)
        text(scene.variant >= 7 ? "Jan 15, 2026  ·  Product discussion" : "Microphone + system audio",x,184,12,muted,490)
        if scene.step < 2 {
            text(isRecording ? "Recording locally" : scene.step == 1 ? "Saved. Preparing transcription…" : "Ready when you are.",x,238,21,isRecording ? red : teal,490,true)
            for i in 0..<42 {
                let wave:CGFloat = isRecording ? CGFloat(8+(i*17+scene.variant*13)%56) : 6
                box(x+CGFloat(i)*11,328-wave/2,5,wave,isRecording ? teal : color(0.22,0.28,0.32),2)
            }
            text("Headphones keep playing normally.",x,396,14,muted,480)
            text("Select your sources and check the level meters.",x,425,12,muted,470)
        } else {
            box(x,215,497,32,color(0.14,0.19,0.22),6)
            text(scene.step == 2 ? "Whisper · Transcribing locally…" : "✓ Completed     ✓ Archived",x+10,224,12,teal,470,true)
            text("▶   00:00 ━━━━━━━━━━━━━━━━━━ 00:36",x,262,12,muted,480)
            text(scene.variant == 8 ? "Transcript    Original    Edit revision" : "Transcript    Original    Timestamps",x,300,12,teal,480,true)
            let lines = ["We want to test recording a meeting\nwhile wearing headphones.", "The first milestone is an offline workflow.\nWhisper should transcribe the audio locally.", "Keep the original transcript. Save manual\ncorrections separately so we can review them."]
            let count = scene.variant == 4 ? 1 : scene.variant == 5 ? 2 : 3
            for i in 0..<count {
                let y = CGFloat(336+i*57)
                text(["00:00","00:12","00:24"][i],x,y,10,teal,47)
                if scene.variant == 9 && i == 1 {box(x+55,y-2,430,49,color(0.24,0.23,0.12),5)}
                text(lines[i],x+59,y,13,ink,434)
            }
            if scene.variant == 10 {box(x+295,491,197,28,teal,6);text("✓ Transcript copied",x+309,497,12,color(0.04,0.12,0.10),185,true)}
            else if scene.variant == 11 {text("Keep forever  ·  Trash → Restore",x,499,12,teal,490,true)}
            else if scene.variant == 7 {text("Title & category suggested by local Qwen",x,499,12,teal,490)}
            else {text("Copy transcript     Export Markdown",x,499,12,muted,490)}
        }
        text(scene.title,26,560,24,ink,960,true)
        text(scene.note,26,599,14,muted,960)
        text("ILLUSTRATED WORKFLOW · FICTIONAL DATA · TIMINGS SHORTENED",26,651,10,teal,960,true)
        return true
    }
    return image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
}
let gifURL = destination.appendingPathComponent("workflow.gif")
let gif = CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,scenes.count,nil)!
CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
for scene in scenes {CGImageDestinationAddImage(gif,frame(scene),[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:scene.delay]] as CFDictionary)}
guard CGImageDestinationFinalize(gif) else {fatalError("Could not write GIF")}
let png = CGImageDestinationCreateWithURL(destination.appendingPathComponent("workflow-poster.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(png,frame(scenes[7]),nil)
guard CGImageDestinationFinalize(png) else {fatalError("Could not write poster")}
print("Rendered \(scenes.count) illustrated frames: \(gifURL.path)")
