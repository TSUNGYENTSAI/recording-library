import Foundation
import SQLite3

final class LibraryStore {
    let root: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        let path = self.root.appendingPathComponent("library.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw LibraryError("無法開啟 Library 資料庫") }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("CREATE TABLE IF NOT EXISTS recordings (id TEXT PRIMARY KEY, payload TEXT NOT NULL, search_text TEXT NOT NULL, created REAL NOT NULL);")
        try execute("PRAGMA user_version=2;")
    }
    deinit { sqlite3_close(db) }
    private var error: LibraryError { LibraryError(String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error }
        return stmt
    }
    private func bind(_ text: String, to stmt: OpaquePointer, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    func folder(_ record: Recording) -> URL { root.appendingPathComponent("recordings/\(record.id.uuidString)", isDirectory: true) }
    func media(_ record: Recording) -> URL { folder(record).appendingPathComponent(record.managedName) }
    func attemptFolder(_ record: Recording, _ attemptID: UUID) -> URL { folder(record).appendingPathComponent("raw/\(attemptID.uuidString)", isDirectory: true) }
    func metadataFolder(_ record: Recording, _ attemptID: UUID) -> URL {folder(record).appendingPathComponent("metadata/\(attemptID.uuidString)",isDirectory:true)}
    func edit(_ record: Recording) throws -> EditRevision? {
        guard let id = record.currentEditID else { return nil }
        return try decoder.decode(EditRevision.self, from: Data(contentsOf: folder(record).appendingPathComponent("edits/\(id.uuidString).json")))
    }
    func raw(_ record: Recording) throws -> TranscriptDocument? {
        guard let id = record.currentRawID else { return nil }
        return try TranscriptDocument.read(attemptFolder(record, id))
    }
    func save(_ record: Recording) throws {
        if let existing = try lookup(record.id), existing.trashedAt != nil, record.trashedAt == nil {throw LibraryError("錄音已移到垃圾桶，請先復原。")}
        let payload = String(decoding: try encoder.encode(record), as: UTF8.self)
        // Search all successful raw attempts and all edit revisions, without altering the originals.
        var texts = [record.title, record.category, record.datePrefix]
        for attempt in record.attempts where attempt.status == "completed" {
            let file = attemptFolder(record, attempt.id).appendingPathComponent("transcript.txt")
            texts.append(try String(contentsOf: file, encoding: .utf8))
        }
        let edits = folder(record).appendingPathComponent("edits")
        if FileManager.default.fileExists(atPath: edits.path) {
            for url in try FileManager.default.contentsOfDirectory(at: edits, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                texts.append(try decoder.decode(EditRevision.self, from: Data(contentsOf: url)).text)
            }
        }
        let stmt = try statement("INSERT INTO recordings(id,payload,search_text,created) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, search_text=excluded.search_text, created=excluded.created;")
        defer { sqlite3_finalize(stmt) }
        bind(record.id.uuidString, to: stmt, at: 1); bind(payload, to: stmt, at: 2)
        bind(searchFold(texts.joined(separator: "\n")), to: stmt, at: 3)
        sqlite3_bind_double(stmt, 4, record.created.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error }
    }
    func list(query: String = "", includeTrashed: Bool = false, onlyTrashed: Bool = false) throws -> [Recording] {
        let terms = searchFold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var clauses: [String] = []
        if onlyTrashed {clauses.append("json_extract(payload, '$.trashedAt') IS NOT NULL")}
        else if !includeTrashed {clauses.append("json_extract(payload, '$.trashedAt') IS NULL")}
        clauses += terms.map {_ in "instr(search_text, ?) > 0"}
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator:" AND ")
        let order = onlyTrashed ? "json_extract(payload, '$.trashedAt') DESC" : "(json_extract(payload, '$.trashedAt') IS NOT NULL) ASC, created DESC"
        let stmt = try statement("SELECT payload FROM recordings" + whereSQL + " ORDER BY " + order + ";")
        defer { sqlite3_finalize(stmt) }
        for (i, term) in terms.enumerated() { bind(term, to: stmt, at: Int32(i+1)) }
        var records: [Recording] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) else { throw error }
            records.append(try decoder.decode(Recording.self, from: Data(String(cString: ptr).utf8)))
        }
        return records
    }
    func saveEdit(_ record: Recording, text: String, sourceID: UUID? = nil) throws -> Recording {
        let existing = try edit(record)
        guard let rawID = sourceID ?? existing?.rawAttemptID ?? record.currentRawID,
              record.attempts.contains(where: { $0.id == rawID && $0.status == "completed" }) else { throw LibraryError("尚無可編輯的原始逐字稿") }
        let revision = EditRevision(rawAttemptID: rawID, parentEditID: existing?.rawAttemptID == rawID ? existing?.id : nil, text: text)
        let directory = folder(record).appendingPathComponent("edits", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(revision.id.uuidString).json")
        try encoder.encode(revision).write(to: file, options: .atomic)
        var updated = record; updated.currentEditID = revision.id
        do { try save(updated) } catch { try? FileManager.default.removeItem(at: file); throw error }
        return updated
    }
    func lookup(_ id: UUID) throws -> Recording? {
        let stmt = try statement("SELECT payload FROM recordings WHERE id=?;")
        defer {sqlite3_finalize(stmt)}; bind(id.uuidString,to:stmt,at:1)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE {return nil}
        guard result == SQLITE_ROW, let ptr = sqlite3_column_text(stmt,0) else {throw error}
        return try decoder.decode(Recording.self,from:Data(String(cString:ptr).utf8))
    }
    private func updatePayload(_ record: Recording) throws {
        let stmt = try statement("UPDATE recordings SET payload=? WHERE id=?;")
        defer {sqlite3_finalize(stmt)}
        bind(String(decoding:try encoder.encode(record),as:UTF8.self),to:stmt,at:1)
        bind(record.id.uuidString,to:stmt,at:2)
        guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {throw LibraryError("錄音紀錄已不存在。")}
    }
    /// Reversible logical removal. Media and every raw/edit/metadata file stay in their original owned folder.
    func remove(_ record: Recording) throws {
        guard var current = try lookup(record.id), current.trashedAt == nil else {throw LibraryError("錄音已在垃圾桶或不存在。")}
        guard !current.keepForever else {throw LibraryError("請先解除永久保留標記，再移到垃圾桶。")}
        guard !current.isProcessing else {throw LibraryError("請先停止背景工作，再移到垃圾桶。")}
        current.trashedAt = Date(); current.purgeStartedAt = nil; current.purgeError = nil
        try updatePayload(current)
    }
    func restore(_ record: Recording) throws -> Recording {
        guard var current = try lookup(record.id), current.trashedAt != nil else {throw LibraryError("垃圾桶中找不到錄音。")}
        guard current.purgeStartedAt == nil else {throw LibraryError("此項目已開始永久刪除，只能重試刪除剩餘資料。")}
        guard FileManager.default.fileExists(atPath:media(current).path) else {throw LibraryError("歸檔音檔遺失，無法完整復原。")}
        for attempt in current.attempts where attempt.status == "completed" {
            let directory = attemptFolder(current,attempt.id)
            guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("transcript.json").path), FileManager.default.fileExists(atPath:directory.appendingPathComponent("transcript.txt").path) else {throw LibraryError("部分原始逐字稿遺失，請先檢查儲存位置。")}
        }
        _ = try edit(current)
        current.trashedAt = nil; current.purgeError = nil
        try updatePayload(current)
        return current
    }
    /// Only confirmed permanent deletion calls this. Tombstones allow interrupted cleanup to be retried safely.
    func purge(_ record: Recording) throws {
        guard var current = try lookup(record.id), current.trashedAt != nil else {throw LibraryError("只能永久刪除垃圾桶內的項目。")}
        guard !current.keepForever, !current.isProcessing else {throw LibraryError("此項目受到保護或仍在處理中。")}
        let directory = folder(current)
        let managedRoot = root.appendingPathComponent("recordings").resolvingSymlinksInPath().standardizedFileURL.path
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(managedRoot + "/") else {throw LibraryError("歸檔路徑不在 Library 範圍內，已停止刪除。")}
        current.purgeStartedAt = current.purgeStartedAt ?? Date(); current.purgeError = nil
        try updatePayload(current)
        do {
            if FileManager.default.fileExists(atPath:directory.path) {try FileManager.default.removeItem(at:directory)}
            let stmt = try statement("DELETE FROM recordings WHERE id=?;")
            defer {sqlite3_finalize(stmt)}; bind(current.id.uuidString,to:stmt,at:1)
            guard sqlite3_step(stmt) == SQLITE_DONE else {throw error}
        } catch {
            current.purgeError = error.localizedDescription
            try? updatePayload(current)
            throw LibraryError("永久刪除尚未完成，項目留在垃圾桶，可重試。\n" + error.localizedDescription)
        }
    }
}
