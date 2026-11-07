// Add explanatory headers to captures of production SwiftUI views; never redraw the app UI.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args=CommandLine.arguments
precondition(args.count==3,"Usage: swift Scripts/render-demo.swift REPO CAPTURE_DIRECTORY")
let repo=URL(fileURLWithPath:args[1]), captures=URL(fileURLWithPath:args[2])
let media=repo.appendingPathComponent("Docs/Media")
let names=["01-start","02-recording","03-stop","04-transcribing","05-preview","06-naming","07-completed","08-review","09-search","10-trash","11-restored"]
let delays:[Double]=[3,2,2,2,2,2.5,3,3.5,3,3,3]
let english:[(String,String)]=[
    ("Start with a recording","Choose microphone, system audio, or both. Press Start recording."),
    ("Capture a meeting or an idea","Separate level meters help you check both audio sources."),
    ("Stop and save when you are finished","Your recording is archived in place, then queued for transcription."),
    ("Whisper transcribes locally","Text starts appearing after audio preparation and model loading."),
    ("Read the growing transcript","Follow the live preview. Words may change until the result is finalized."),
    ("Qwen suggests a title and category","Naming currently uses Traditional Chinese; example titles here are translated into English."),
    ("Completed, dated and categorized","Return later to find the conversation in your Library."),
    ("Review, edit, copy or export","Edits are saved separately. Copy the transcript or export Markdown using the upper-right icons."),
    ("Find Chinese phrases or English terms","Search titles and transcript text. Here we search for API."),
    ("Move a recording to Trash","Audio, original transcripts and edits stay available to restore."),
    ("Restore it, or mark it Keep forever","Keep forever protects a recording from manual deletion. Import is also available for existing files.")
]
let chinese:[(String,String)]=[
    ("從錄音開始","選擇麥克風、系統聲音或兩者一起錄，再按「開始錄音」。"),
    ("錄下會議或想法","兩個來源有各自的音量條，方便確認聲音有被收錄。"),
    ("結束時，按「停止並儲存」","錄音原地歸檔，接著排入本機轉錄工作。"),
    ("Whisper 在本機轉錄","音訊準備與模型載入完成後，辨識文字會逐步顯示。"),
    ("邊轉錄，邊閱讀","可跟隨預覽文字；正式完成前，辨識結果仍可能調整。"),
    ("Qwen 建議標題與分類","選用的本機文字模型協助整理，原始逐字稿保持不變。"),
    ("完成：日期、標題、分類都整理好了","之後回到 Library，就能找回這場對話。"),
    ("閱讀、修改、複製或匯出","修改另存為編輯版；右上角可複製逐字稿或匯出 Markdown。"),
    ("用中文或英文關鍵字找回內容","搜尋名稱與逐字稿內容，這裡示範搜尋 API。"),
    ("移到垃圾桶，仍然可以復原","音檔、原始逐字稿與編輯版都會保留。"),
    ("復原，也能標記永久保留","永久保留可防止手動刪除；已有錄音或影片也能透過匯入加入。")
]
let width=1280,height=962
let ink=NSColor(calibratedRed:0.94,green:0.96,blue:0.98,alpha:1)
let muted=NSColor(calibratedRed:0.70,green:0.76,blue:0.81,alpha:1)
let accent=NSColor(calibratedRed:0.30,green:0.86,blue:0.75,alpha:1)
func text(_ value:String,_ rect:NSRect,_ size:CGFloat,_ color:NSColor,_ bold:Bool=false) {
    let style=NSMutableParagraphStyle();style.lineBreakMode = .byWordWrapping;style.lineSpacing=3
    (value as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold : .regular),.foregroundColor:color,.paragraphStyle:style])
}
func render(_ file:URL,_ caption:(String,String),_ number:Int,_ zh:Bool)throws->CGImage {
    guard let native=NSImage(contentsOf:file) else {throw NSError(domain:"Missing native view capture",code:1,userInfo:[NSFilePathErrorKey:file.path])}
    let image=NSImage(size:NSSize(width:width,height:height),flipped:true) {_ in
        NSColor(calibratedRed:0.06,green:0.08,blue:0.10,alpha:1).setFill();NSRect(x:0,y:0,width:width,height:height).fill()
        text("Recording Library  /  \(number+1) · \(names.count)",NSRect(x:24,y:12,width:1100,height:20),12,accent,true)
        text(caption.0,NSRect(x:24,y:35,width:1232,height:33),24,ink,true)
        text(caption.1,NSRect(x:24,y:72,width:1232,height:26),14,muted)
        native.draw(in:NSRect(x:0,y:104,width:1280,height:820),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
        text(zh ? "實際 App 介面・虛構示範資料・錄音／推論狀態以測試資料重播・等待時間縮短" : "Real app UI · Fictional data · Recording / inference states replayed · Waits shortened",NSRect(x:24,y:935,width:1232,height:20),12,muted)
        return true
    }
    return image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
}
for language in ["en","zh-Hant"] {
    let zh=language=="zh-Hant", captions=language=="zh-Hant" ? chinese : english
    let suffix=zh ? "-zh-TW" : ""
    let url=media.appendingPathComponent("workflow\(suffix).gif")
    let output=CGImageDestinationCreateWithURL(url as CFURL,UTType.gif.identifier as CFString,names.count,nil)!
    CGImageDestinationSetProperties(output,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
    for (i,name) in names.enumerated() {
        let image=try render(captures.appendingPathComponent(language+"/"+name+".png"),captions[i],i,zh)
        CGImageDestinationAddImage(output,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delays[i]] ] as CFDictionary)
        if i==6 {
            let poster=CGImageDestinationCreateWithURL(media.appendingPathComponent("workflow-poster\(suffix).png") as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(poster,image,nil);precondition(CGImageDestinationFinalize(poster))
        }
    }
    precondition(CGImageDestinationFinalize(output));print("Rendered captioned native workflow: \(url.lastPathComponent)")
}
