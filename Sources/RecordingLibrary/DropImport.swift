import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A real AppKit destination is required for file promises exported by Voice Memos.
struct RecordingDropZone: NSViewRepresentable {
    var expanded = false
    var onReceive: ([URL], URL?) -> Void
    var onError: (String) -> Void
    func makeNSView(context: Context) -> RecordingDropView {
        let view = RecordingDropView()
        view.onReceive = onReceive; view.onError = onError; view.configure(expanded:expanded)
        return view
    }
    func updateNSView(_ view: RecordingDropView, context: Context) {
        view.onReceive = onReceive; view.onError = onError; view.configure(expanded:expanded)
    }
}
final class RecordingDropView: NSView {
    var onReceive: (([URL], URL?) -> Void)?
    var onError: ((String) -> Void)?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated; queue.name = "RecordingLibrary.FilePromises"
        return queue
    }()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = 9; layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.stringValue = L("拖入語音備忘錄或 Finder 檔案\n自動歸檔・相同錄音只保留一份")
        label.alignment = .center; label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor; label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo:centerYAnchor),label.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10)])
        var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        types += [.fileURL, .URL, .string, .fileContents, NSPasteboard.PasteboardType(UTType.audio.identifier), NSPasteboard.PasteboardType(UTType.movie.identifier),NSPasteboard.PasteboardType("public.mpeg-4-audio"),NSPasteboard.PasteboardType("public.mpeg-4")]
        registerForDraggedTypes(types)
        setAccessibilityLabel(L("錄音歸檔拖放區"))
    }
    func configure(expanded: Bool) {
        label.stringValue = L(expanded ? "把錄音或影片拖到這裡\n\n支援直接從語音備忘錄、Finder 拖入\n完成歸檔後自動轉錄，相同錄音不重複複製" : "拖入語音備忘錄或 Finder 檔案\n自動歸檔・相同錄音只保留一份")
        label.font = .systemFont(ofSize:expanded ? 16 : 11)
        layer?.borderWidth = expanded ? 1.5 : 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderColor = NSColor.systemTeal.cgColor
        layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.12).cgColor
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { reset() }
    override func draggingEnded(_ sender: NSDraggingInfo) { reset() }
    private func reset() { layer?.borderColor = NSColor.separatorColor.cgColor; layer?.backgroundColor = NSColor.clear.cgColor }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        reset(); return receive(sender.draggingPasteboard)
    }
    /// Kept separate so real file-URL pasteboards and promise batches can be tested without moving the user's pointer.
    @discardableResult func receive(_ pasteboard: NSPasteboard) -> Bool {
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            do {
                let destination = try Self.stagingDirectory()
                let batch = PromiseBatch(expected: promises.reduce(0) { $0 + max(1,$1.fileNames.count) }, directory: destination, onReceive: onReceive, onError: onError)
                for promise in promises {
                    promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                        DispatchQueue.main.async { batch.received(url, error: error) }
                    }
                }
                return true
            } catch { onError?(error.localizedDescription); return false }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onReceive?(urls, nil); return true
        }
        if let string = pasteboard.string(forType: .string) {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: value), url.isFileURL { onReceive?([url], nil); return true }
            if value.hasPrefix("/"), FileManager.default.fileExists(atPath:value) { onReceive?([URL(fileURLWithPath:value)],nil); return true }
        }
        // Some sources supply audio data rather than URLs or AppKit file promises.
        for type in pasteboard.types ?? [] {
            guard let contentType = UTType(type.rawValue), contentType.conforms(to: .audio) || contentType.conforms(to: .movie), let ext = contentType.preferredFilenameExtension, let data = pasteboard.data(forType:type), !data.isEmpty else { continue }
            do {
                let directory = try Self.stagingDirectory()
                let file = directory.appendingPathComponent("拖入錄音.\(ext)")
                try data.write(to:file,options:.atomic); onReceive?([file],directory); return true
            } catch { onError?(error.localizedDescription); return false }
        }
        onError?(L("這次拖曳沒有提供可讀取的檔案。請拖到錄音歸檔區，或先從語音備忘錄匯出 m4a 再匯入。"))
        return false
    }
    nonisolated static func stagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingLibrary-Drop-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return directory
    }
}
final class PromiseBatch {
    private var remaining: Int
    private var urls: [URL] = []
    private var failures: [String] = []
    private let directory: URL
    private let onReceive: (([URL],URL?) -> Void)?
    private let onError: ((String) -> Void)?
    init(expected: Int, directory: URL, onReceive: (([URL],URL?) -> Void)?, onError: ((String) -> Void)?) {
        remaining = expected; self.directory = directory; self.onReceive = onReceive; self.onError = onError
    }
    func received(_ url: URL, error: Error?) {
        guard remaining > 0 else { return }
        if let error { failures.append(error.localizedDescription) } else { urls.append(url) }
        remaining -= 1
        if remaining == 0 {
            if !failures.isEmpty { onError?("部分拖入檔案無法匯出：\n" + failures.joined(separator:"\n")) }
            if urls.isEmpty { try? FileManager.default.removeItem(at:directory) }
            else { onReceive?(urls,directory) }
        }
    }
}

/// Copy file-representation URLs before their completion handler returns: those URLs can expire immediately.
enum ProviderDropResolver {
    static func resolve(_ providers: [NSItemProvider]) async throws -> (urls: [URL], staging: URL) {
        let directory = try RecordingDropView.stagingDirectory()
        var urls: [URL] = []
        do {
            for provider in providers {
                let type = provider.registeredTypeIdentifiers.first { value in
                    guard let type = UTType(value) else {return false}
                    return type.conforms(to:.audio) || type.conforms(to:.movie)
                }
                if let type {
                    let targetDirectory = directory.appendingPathComponent(UUID().uuidString,isDirectory:true)
                    try FileManager.default.createDirectory(at:targetDirectory,withIntermediateDirectories:true)
                    let suggestedName = provider.suggestedName
                    let copied: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier:type) { url,error in
                            guard let url else {continuation.resume(throwing:error ?? LibraryError("拖曳來源沒有提供檔案。")); return}
                            do {
                                var name = suggestedName ?? url.lastPathComponent
                                name = URL(fileURLWithPath:name).lastPathComponent
                                if URL(fileURLWithPath:name).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {name += "." + ext}
                                let destination = targetDirectory.appendingPathComponent(name)
                                try FileManager.default.copyItem(at:url,to:destination)
                                continuation.resume(returning:destination)
                            } catch {continuation.resume(throwing:error)}
                        }
                    }
                    urls.append(copied)
                } else {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { value,error in
                            if let url = value as? URL, url.isFileURL {continuation.resume(returning:url)}
                            else if let data = value as? Data, let url = URL(dataRepresentation:data,relativeTo:nil), url.isFileURL {continuation.resume(returning:url)}
                            else if let value = value as? String, let url = URL(string:value), url.isFileURL {continuation.resume(returning:url)}
                            else {continuation.resume(throwing:error ?? LibraryError("這次拖曳沒有提供本地檔案。請使用錄音歸檔拖放區。"))}
                        }
                    }
                    urls.append(url)
                }
            }
            return (urls,directory)
        } catch {try? FileManager.default.removeItem(at:directory); throw error}
    }
}
