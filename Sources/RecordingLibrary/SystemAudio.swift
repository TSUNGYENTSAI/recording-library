import Foundation
import AVFoundation
import CoreAudio

enum CaptureMode: String, Codable, CaseIterable {
    case microphone, system, both
    var label: String {switch self {case .microphone:return "麥克風";case .system:return "系統聲音";case .both:return "麥克風＋系統聲音"}}
    var hasMicrophone: Bool {self != .system}
    var hasSystem: Bool {self != .microphone}
}

/// Runs only on the capture's serial writer queue. One private aggregate device supplies a shared
/// hardware timeline; Core Audio drift compensation aligns its mic and system-tap streams.
final class MixedAudioWriter {
    let format: AVAudioFormat
    let outputFormat = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private(set) var frames: Int64 = 0
    init(url:URL, sampleRate:Double) throws {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 192000 else {throw LibraryError("音訊取樣率不受支援。")}
        format = AVAudioFormat(standardFormatWithSampleRate:sampleRate,channels:1)!
        guard let converter = AVAudioConverter(from:format,to:outputFormat) else {throw LibraryError("無法建立音訊轉換器。")}
        self.converter = converter
        file = try AVAudioFile(forWriting:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false],commonFormat:.pcmFormatFloat32,interleaved:false)
    }
    static func mix(microphone:[Float], system:[Float], mode:CaptureMode) throws -> [Float] {
        let count = mode.hasMicrophone ? microphone.count : system.count
        guard (!mode.hasMicrophone || microphone.count == count), (!mode.hasSystem || system.count == count) else {throw LibraryError("麥克風與系統聲音長度不符。")}
        return (0..<count).map {index in
            let mic = mode.hasMicrophone ? microphone[index] : 0
            let sys = mode.hasSystem ? system[index] : 0
            let value = mode == .both ? 0.5 * mic + 0.5 * sys : mic + sys
            return value.isFinite ? min(1,max(-1,value)) : 0
        }
    }
    func append(_ samples:[Float]) throws {
        guard !samples.isEmpty else {return}
        guard samples.count <= 262144, let input = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(samples.count)) else {throw LibraryError("音訊區塊過大。")}
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer {input.floatChannelData![0].update(from:$0.baseAddress!,count:samples.count)}
        let capacity = AVAudioFrameCount(ceil(Double(samples.count)*16000/format.sampleRate)+256)
        let output = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:capacity)!
        var provided = false; var error:NSError?
        let status = converter.convert(to:output,error:&error) {_,result in
            if provided {result.pointee = .noDataNow;return nil}
            provided = true;result.pointee = .haveData;return input
        }
        if let error {throw error}
        guard status != .error else {throw LibraryError("音訊轉換失敗。")}
        if output.frameLength > 0 {try file?.write(from:output);frames += Int64(output.frameLength)}
    }
    func finish() throws {
        guard file != nil else {return}
        defer {file = nil}
        for _ in 0..<4 {
            let output = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:1024)!
            var error:NSError?
            let status = converter.convert(to:output,error:&error) {_,result in result.pointee = .endOfStream;return nil}
            if let error {throw error}
            if output.frameLength > 0 {try file?.write(from:output);frames += Int64(output.frameLength)}
            if status == .endOfStream || output.frameLength == 0 {break}
        }
    }
}

struct CaptureInputBlock {
    let microphone:[Float]
    let system:[Float]
    static func decode(_ pointer:UnsafePointer<AudioBufferList>, microphoneChannels:Int, totalChannels:Int) throws -> CaptureInputBlock {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:pointer))
        guard microphoneChannels >= 0, totalChannels > microphoneChannels,
              buffers.reduce(0,{$0 + Int($1.mNumberChannels)}) == totalChannels else {throw LibraryError("音訊聲道配置已改變，錄音已停止。")}
        var planes:[[Float]] = [];var frames:Int?
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData, buffer.mDataByteSize % 4 == 0 else {throw LibraryError("音訊輸入資料中斷。")}
            let count = Int(buffer.mDataByteSize)/MemoryLayout<Float>.size
            guard count % channels == 0, count/channels > 0, count/channels <= 262144, frames == nil || frames == count/channels else {throw LibraryError("音訊區塊格式或同步狀態不符。")}
            frames = count/channels
            let source = data.assumingMemoryBound(to:Float.self)
            for channel in 0..<channels {
                let samples = (0..<(frames ?? 0)).map {source[$0*channels+channel]}
                guard samples.allSatisfy({$0.isFinite}) else {throw LibraryError("收到無效音訊樣本，已停止錄音。")}
                planes.append(samples)
            }
        }
        guard let frames else {throw LibraryError("音訊區塊為空。")}
        let microphone:[Float] = microphoneChannels == 0 ? [] : (0..<frames).map {frame in planes.prefix(microphoneChannels).reduce(Float(0)) {$0 + $1[frame]}/Float(microphoneChannels)}
        let system = (0..<frames).map {frame in planes.dropFirst(microphoneChannels).reduce(Float(0)) {$0 + $1[frame]}/Float(totalChannels-microphoneChannels)}
        return CaptureInputBlock(microphone:microphone,system:system)
    }
}

/// Read-only device discovery. Never changes the system's default input, output, volume or mute.
enum AudioHardwareInfo {
    static func address(_ selector:AudioObjectPropertySelector, scope:AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)}
    static func read<T>(_ object:AudioObjectID, _ selector:AudioObjectPropertySelector, into value:inout T, scope:AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var address = address(selector,scope:scope);var size = UInt32(MemoryLayout<T>.size)
        let result = withUnsafeMutablePointer(to:&value) {AudioObjectGetPropertyData(object,&address,0,nil,&size,$0)}
        guard result == noErr else {throw LibraryError("無法讀取音訊裝置（\(result)）。")}
    }
    static func string(_ object:AudioObjectID, _ selector:AudioObjectPropertySelector) throws -> String {
        var value:CFString = "" as CFString;try read(object,selector,into:&value);return value as String
    }
    static func channels(_ device:AudioObjectID) throws -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration,scope:kAudioDevicePropertyScopeInput);var size:UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device,&address,0,nil,&size) == noErr, size >= MemoryLayout<AudioBufferList>.size else {throw LibraryError("無法讀取輸入聲道。")}
        let memory = UnsafeMutableRawPointer.allocate(byteCount:Int(size),alignment:MemoryLayout<AudioBufferList>.alignment);defer {memory.deallocate()}
        guard AudioObjectGetPropertyData(device,&address,0,nil,&size,memory) == noErr else {throw LibraryError("無法讀取輸入配置。")}
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to:AudioBufferList.self)).reduce(0) {$0 + Int($1.mNumberChannels)}
    }
    static func builtInMicrophone() throws -> (AudioObjectID,String,String,Int) {
        var address = address(kAudioHardwarePropertyDevices);var size:UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr else {throw LibraryError("無法列出麥克風。")}
        var devices = [AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
        let status = devices.withUnsafeMutableBytes {AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!)}
        guard status == noErr else {throw LibraryError("無法列出麥克風。")}
        for device in devices {
            var transport:UInt32 = 0;try? read(device,kAudioDevicePropertyTransportType,into:&transport)
            guard transport == kAudioDeviceTransportTypeBuiltIn, let count = try? channels(device), count > 0 else {continue}
            return (device,try string(device,kAudioDevicePropertyDeviceUID),try string(device,kAudioObjectPropertyName),count)
        }
        throw LibraryError("找不到 Mac 內建麥克風。為避免意外切到耳機收音，本次沒有開始錄音。")
    }
}

@available(macOS 14.2, *)
@MainActor final class SystemAudioSession: AudioRecordingSession {
    var finished: ((Bool,String?) -> Void)?
    private let core: SystemAudioCore
    private var watchdog:Timer?
    init(url:URL,mode:CaptureMode) throws {core = try SystemAudioCore(url:url,mode:mode)}
    var elapsed:TimeInterval {core.snapshot().elapsed}
    var power:Float {max(microphonePower,systemPower)}
    var microphonePower:Float {core.snapshot().mic}
    var systemPower:Float {core.snapshot().system}
    var inputLabel:String {core.inputName}
    func record() -> Bool {
        do {
            try core.start()
            if watchdog == nil {watchdog = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.checkHealth() } }}
            return true
        } catch {core.startError = error.localizedDescription;return false}
    }
    var failureMessage:String? {core.startError}
    func pause() {core.pause()}
    func updateMeters() {}
    private func checkHealth() {if let error = core.healthError() {complete(error)}}
    func stop() {complete(nil)}
    private func complete(_ error:String?) {
        guard !core.closed else {return}
        watchdog?.invalidate();watchdog = nil
        let message = core.finish(error:error)
        finished?(message == nil,message)
    }
    deinit {watchdog?.invalidate();core.abandon()}
}

@available(macOS 14.2, *)
private final class SystemAudioCore {
    let inputName:String
    let mode:CaptureMode
    private var tap:AudioObjectID = 0
    private var aggregate:AudioObjectID = 0
    private var io:AudioDeviceIOProcID?
    private var micDevice:AudioObjectID = 0
    private var outputDevice:AudioObjectID = 0
    private var micChannels = 0
    private var totalChannels = 0
    private var inputMixer:PCMInputMixer?
    private var streamFormats:[(AudioObjectID,AudioStreamBasicDescription)] = []
    private var writer:MixedAudioWriter?
    private let queue = DispatchQueue(label:"RecordingLibrary.audio-writer",qos:.userInitiated)
    private let ioQueue = DispatchQueue(label:"RecordingLibrary.audio-input",qos:.userInteractive)
    private let lock = NSLock()
    private var accepting = false
    private var paused = false
    private var started = false
    private var pending = 0
    private var lastInput = Date()
    private var micLevel:Float = -160
    private var systemLevel:Float = -160
    private var systemHeard = false
    private var frameCount:Int64 = 0
    private var failure:String?
    var startError:String?
    private(set) var closed = false
    private let url:URL
    private var rate:Double = 0
    init(url:URL,mode:CaptureMode) throws {
        self.url = url;self.mode = mode
        if mode.hasMicrophone {
            let microphone = try AudioHardwareInfo.builtInMicrophone()
            micDevice = microphone.0;micChannels = microphone.3;inputName = microphone.2
        } else {inputName = "系統聲音（全部 App）"}
        do {try prepare()} catch {cleanupHardware();throw error}
    }
    private func require(_ status:OSStatus,_ operation:String) throws {
        guard status == noErr else {throw LibraryError("\(operation)失敗（\(status)）。請確認「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」的系統聲音權限。")}
    }
    private func prepare() throws {
        try AudioHardwareInfo.read(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultOutputDevice,into:&outputDevice)
        guard outputDevice != 0 else {throw LibraryError("找不到聲音輸出裝置。")}
        var pid = getpid();var ownProcess:AudioObjectID = 0
        var address = AudioHardwareInfo.address(kAudioHardwarePropertyTranslatePIDToProcessObject);var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,UInt32(MemoryLayout<pid_t>.size),&pid,&size,&ownProcess)
        // Exclude this app when Core Audio exposes its process object. Never mute the tapped output.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses:translated == noErr && ownProcess != 0 ? [ownProcess] : [])
        description.name = "Recording Library system audio";description.isPrivate = true;description.muteBehavior = .unmuted
        try require(AudioHardwareCreateProcessTap(description,&tap),"建立系統聲音擷取")
        var tapFormat = AudioStreamBasicDescription();try AudioHardwareInfo.read(tap,kAudioTapPropertyFormat,into:&tapFormat)
        let tapUID = try AudioHardwareInfo.string(tap,kAudioTapPropertyUID)
        totalChannels = micChannels + Int(tapFormat.mChannelsPerFrame)
        var configuration:[String:Any] = [kAudioAggregateDeviceNameKey:"Recording Library Capture",kAudioAggregateDeviceUIDKey:UUID().uuidString,kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceIsStackedKey:false,kAudioAggregateDeviceTapAutoStartKey:false,kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:tapUID,kAudioSubTapDriftCompensationKey:true]]]
        if micDevice != 0 {
            let uid = try AudioHardwareInfo.string(micDevice,kAudioDevicePropertyDeviceUID)
            configuration[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey:uid]]
            configuration[kAudioAggregateDeviceMainSubDeviceKey] = uid
        } else {configuration[kAudioAggregateDeviceSubDeviceListKey] = []}
        try require(AudioHardwareCreateAggregateDevice(configuration as CFDictionary,&aggregate),"建立私有錄音裝置")
        guard try AudioHardwareInfo.channels(aggregate) == totalChannels else {throw LibraryError("麥克風與系統聲音的聲道配置不符，已停止準備。")}
        try AudioHardwareInfo.read(aggregate,kAudioDevicePropertyNominalSampleRate,into:&rate)
        // Validate every stream: never reinterpret an unsupported sample layout as speech.
        var streamsAddress = AudioHardwareInfo.address(kAudioDevicePropertyStreams,scope:kAudioDevicePropertyScopeInput);var streamSize:UInt32 = 0
        try require(AudioObjectGetPropertyDataSize(aggregate,&streamsAddress,0,nil,&streamSize),"讀取音訊串流")
        guard streamSize > 0, streamSize % 4 == 0 else {throw LibraryError("錄音裝置沒有輸入串流。") }
        var streams = [AudioObjectID](repeating:0,count:Int(streamSize)/4)
        let result = streams.withUnsafeMutableBytes {AudioObjectGetPropertyData(aggregate,&streamsAddress,0,nil,&streamSize,$0.baseAddress!)}
        try require(result,"讀取音訊串流")
        guard !streams.isEmpty else {throw LibraryError("錄音裝置沒有輸入串流。")}
        var nextChannel:UInt32 = 1
        var layouts:[PCMInputLayout] = []
        var diagnostics:[[String:Any]] = []
        for stream in streams {
            var firstChannel:UInt32 = 0;try AudioHardwareInfo.read(stream,kAudioStreamPropertyStartingChannel,into:&firstChannel)
            guard firstChannel == nextChannel else {throw LibraryError("輸入串流聲道順序不符，已停止準備。")}
            var format = AudioStreamBasicDescription();try AudioHardwareInfo.read(stream,kAudioStreamPropertyVirtualFormat,into:&format)
            diagnostics.append(["firstChannel":firstChannel,"sampleRate":format.mSampleRate,"channels":format.mChannelsPerFrame,"bits":format.mBitsPerChannel,"flags":format.mFormatFlags,"formatID":format.mFormatID,"bytesPerFrame":format.mBytesPerFrame])
            try JSONSerialization.data(withJSONObject:["aggregateClockRate":rate,"microphoneChannels":micChannels,"streams":diagnostics],options:[.prettyPrinted,.sortedKeys]).write(to:url.deletingLastPathComponent().appendingPathComponent("capture-setup.json"),options:.atomic)
            layouts.append(try PCMInputLayout(format,firstChannel:Int(firstChannel)-1))
            streamFormats.append((stream,format));nextChannel += format.mChannelsPerFrame
        }
        guard Int(nextChannel)-1 == totalChannels else {throw LibraryError("音訊聲道總數不符。")}
        inputMixer = try PCMInputMixer(layouts:layouts,microphoneChannels:micChannels,totalChannels:totalChannels)
        writer = try MixedAudioWriter(url:url,sampleRate:16000)
        try require(AudioDeviceCreateIOProcIDWithBlock(&io,aggregate,ioQueue) { [weak self] _,data,_,_,_ in self?.receive(data) },"建立聲音接收器")
    }
    func start() throws {
        guard !closed else {throw LibraryError("錄音已結束。")}
        lock.lock();paused = false;lastInput = Date();accepting = true;lock.unlock()
        if !started {
            do {try require(AudioDeviceStart(aggregate,io),"啟動系統聲音錄製");started = true}
            catch {lock.lock();accepting = false;lock.unlock();throw error}
        }
    }
    func pause() {lock.lock();paused = true;micLevel = -160;systemLevel = -160;lock.unlock();queue.sync {}}
    private func receive(_ pointer:UnsafePointer<AudioBufferList>) {
        lock.lock();defer {lock.unlock()}
        lastInput = Date()
        guard accepting, !paused, failure == nil else {return}
        guard pending < 128 else {failure = "音訊寫入跟不上收音速度；錄音已停止，已寫入部分保留。";return}
        let inputs:[AVAudioPCMBuffer]
        guard let inputMixer else {failure = "音訊轉換器尚未準備好。";return}
        do {inputs = try inputMixer.copy(pointer)} catch {failure = error.localizedDescription;return}
        pending += 1
        queue.async { [weak self] in
            guard let self else {return}
            do {
                let block = try inputMixer.append(inputs)
                let microphone = block.microphone;let system = block.system
                let mixed = try MixedAudioWriter.mix(microphone:microphone,system:system,mode:self.mode)
                try self.writer?.append(mixed)
                func level(_ samples:[Float]) -> Float {
                    guard !samples.isEmpty else {return -160}
                    let square = samples.reduce(Double(0)) {$0 + Double($1)*Double($1)}/Double(samples.count)
                    return Float(10 * log10(max(1e-16,square)))
                }
                self.lock.lock();self.micLevel = level(microphone);self.systemLevel = level(system)
                self.systemHeard = self.systemHeard || system.contains {abs($0) > 0.00001}
                self.frameCount = self.writer?.frames ?? 0;self.pending -= 1;self.lock.unlock()
            } catch {self.lock.lock();self.failure = error.localizedDescription;self.pending -= 1;self.lock.unlock()}
        }
    }
    func snapshot() -> (elapsed:Double,mic:Float,system:Float) {lock.lock();defer {lock.unlock()};return (Double(frameCount)/16000,micLevel,systemLevel)}
    func healthError() -> String? {
        lock.lock();let error = failure;let stalled = accepting && !paused && Date().timeIntervalSince(lastInput) > 8;lock.unlock()
        if let error {return error}
        if stalled {return "沒有收到系統音訊資料。請檢查系統聲音錄製權限與輸出裝置；已寫入的錄音會保留。"}
        var output:AudioObjectID = 0
        if (try? AudioHardwareInfo.read(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultOutputDevice,into:&output)) == nil || output != outputDevice {return "聲音輸出裝置已切換；為避免錄音缺段，本次已停止。請確認裝置後重新錄音。"}
        var currentRate:Double = 0
        if (try? AudioHardwareInfo.read(aggregate,kAudioDevicePropertyNominalSampleRate,into:&currentRate)) == nil || abs(currentRate-rate) > 1 {return "音訊取樣率已改變，本次錄音已停止並保留。"}
        for (stream,original) in streamFormats {
            var current = AudioStreamBasicDescription()
            if (try? AudioHardwareInfo.read(stream,kAudioStreamPropertyVirtualFormat,into:&current)) == nil ||
                current.mSampleRate != original.mSampleRate || current.mFormatID != original.mFormatID ||
                current.mFormatFlags != original.mFormatFlags || current.mBitsPerChannel != original.mBitsPerChannel ||
                current.mChannelsPerFrame != original.mChannelsPerFrame || current.mBytesPerFrame != original.mBytesPerFrame {
                return "會議音訊格式已切換，本次錄音已停止並保留。請待會議裝置穩定後重新錄音。"
            }
        }
        if micDevice != 0 {var alive:UInt32 = 0;if (try? AudioHardwareInfo.read(micDevice,kAudioDevicePropertyDeviceIsAlive,into:&alive)) == nil || alive == 0 {return "Mac 麥克風已中斷，本次錄音已停止。"}}
        return nil
    }
    func finish(error:String?) -> String? {
        guard !closed else {return error}
        lock.lock();accepting = false;lock.unlock()
        if started {AudioDeviceStop(aggregate,io);started = false}
        var result = error
        queue.sync {
            do {
                if let tail = try inputMixer?.finish() {try writer?.append(MixedAudioWriter.mix(microphone:tail.microphone,system:tail.system,mode:mode))}
                try writer?.finish()
            } catch {result = result ?? error.localizedDescription;try? writer?.finish()}
        }
        lock.lock();result = result ?? failure;let heard = systemHeard;let frames = writer?.frames ?? 0;frameCount = frames;lock.unlock()
        if result == nil, !heard {result = "本次未偵測到系統聲音，可能沒有播放內容或尚未允許系統錄音。音檔已保留在待處理錄音，請檢查後再儲存。"}
        let audit:[String:Any] = ["mode":mode.rawValue,"input":inputName,"sampleRate":rate,"outputFrames":frames,"paddedTailFrames":inputMixer?.paddedTailFrames ?? 0,"systemSignalDetected":heard,"error":result ?? "","capturedAt":ISO8601DateFormatter().string(from:Date())]
        do {try JSONSerialization.data(withJSONObject:audit,options:[.prettyPrinted,.sortedKeys]).write(to:url.deletingLastPathComponent().appendingPathComponent("capture-audit.json"),options:.atomic)} catch {result = result ?? error.localizedDescription}
        writer = nil;cleanupHardware();closed = true
        return result
    }
    func abandon() {if !closed {_ = finish(error:"錄音程序已結束，原檔已保留。")}}
    private func cleanupHardware() {
        if started {AudioDeviceStop(aggregate,io);started = false}
        if let io {AudioDeviceDestroyIOProcID(aggregate,io);self.io = nil}
        if aggregate != 0 {AudioHardwareDestroyAggregateDevice(aggregate);aggregate = 0}
        if tap != 0 {AudioHardwareDestroyProcessTap(tap);tap = 0}
    }
}
