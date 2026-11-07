import Foundation
import CryptoKit

@main struct StorageChecks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try LibraryStore(root:root)
        func check(_ value: Bool, _ message: String) throws {if !value {throw LibraryError(message)}}
        var record = Recording(title:"工程討論",sourcePath:"/untouched/original.m4a",managedName:"source.m4a",duration:90,bytes:5,isVideo:false)
        try FileManager.default.createDirectory(at:store.folder(record),withIntermediateDirectories:true)
        try Data("owned".utf8).write(to:store.media(record))
        func raw(_ text:String) throws -> Attempt {
            var attempt = Attempt(); attempt.status = "completed"
            let directory = store.attemptFolder(record,attempt.id)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try text.write(to:directory.appendingPathComponent("transcript.txt"),atomically:true,encoding:.utf8)
            let data = try JSONSerialization.data(withJSONObject:[["text":text,"segments":[["id":0,"start":0,"end":10,"text":text]]]])
            try data.write(to:directory.appendingPathComponent("transcript.json"))
            return attempt
        }
        let original = try raw("原始中文逐字稿 Revit API")
        record.attempts.append(original); record.currentRawID = original.id; try store.save(record)
        let originalURL = store.attemptFolder(record,original.id).appendingPathComponent("transcript.json")
        let before = try Data(contentsOf:originalURL)
        record = try store.saveEdit(record,text:"第一版連續中文搜尋與 Revit API")
        let firstEdit = try store.edit(record)!
        let secondRaw = try raw("新一次辨識結果")
        record.attempts.append(secondRaw); record.currentRawID = secondRaw.id; try store.save(record)
        record = try store.saveEdit(record,text:"原編輯版本的後續修正")
        let secondEdit = try store.edit(record)!
        try check(secondEdit.rawAttemptID == original.id && secondEdit.parentEditID == firstEdit.id,"重新轉錄後編輯來源鏈錯誤")
        record = try store.saveEdit(record,text:"改以最新原始文字編輯",sourceID:secondRaw.id)
        let newEdit = try store.edit(record)!
        try check(newEdit.rawAttemptID == secondRaw.id && newEdit.parentEditID == nil,"切換原始來源錯誤")
        try check(try Data(contentsOf:originalURL) == before,"原始結果被改寫")
        try check(try store.list(query:"連續中文搜尋").count == 1,"中文舊編輯版本搜尋失敗")
        try check(try store.list(query:"rEvIt api").count == 1,"英文大小寫搜尋失敗")
        try check(try store.list(query:"' OR 1=1 --").isEmpty,"參數化搜尋失敗")
        let reopened = try LibraryStore(root:root)
        try check(try reopened.list().first?.currentEditID == record.currentEditID,"重開資料庫遺失編輯來源")
        record.keepForever = true; try store.save(record)
        do {try store.remove(record); throw LibraryError("保留標記未阻止刪除")} catch let error as LibraryError {try check(error.message.contains("解除"),"錯誤的刪除回報")}
        let doc = TranscriptDocument(text:"x",segments:[Segment(id:0,start:10,end:20,text:"正常"),Segment(id:1,start:9,end:100,text:" ")])
        try check(doc.audit(duration:90).count == 3,"未回報空白、越界與倒退")
        record.keepForever = false; try store.save(record); try store.remove(record)
        try check(try store.list().isEmpty && store.list(onlyTrashed:true).count == 1 && FileManager.default.fileExists(atPath:store.media(record).path),"垃圾桶未保留媒體")
        record = try store.restore(record)
        try check(try store.list().count == 1,"垃圾桶復原失敗")
        try store.remove(record); try store.purge(record)
        try check(try store.list(includeTrashed:true).isEmpty && !FileManager.default.fileExists(atPath:store.media(record).path),"永久刪除 Library 副本失敗")
        print("STORAGE CHECKS PASSED: lineage, immutable raw, Chinese and English search, persistence, diagnostics, protected deletion")
    }
}
