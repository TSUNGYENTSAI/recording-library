import Foundation
import AVFoundation
import CoreAudio

/// The stream's ASBD describes its actual buffer format; an aggregate's nominal clock rate
/// does not require all member streams to expose that same virtual format.
struct PCMInputLayout {
    let description:AudioStreamBasicDescription
    let firstChannel:Int
    let format:AVAudioFormat
    let bufferChannels:[UInt32]
    var channels:Int {Int(description.mChannelsPerFrame)}
    init(_ description:AudioStreamBasicDescription, firstChannel:Int) throws {
        self.description = description;self.firstChannel = firstChannel
        guard description.mFormatID == kAudioFormatLinearPCM, description.mSampleRate.isFinite,
              (8000...192000).contains(description.mSampleRate), (1...32).contains(description.mChannelsPerFrame),
              description.mBytesPerFrame > 0, description.mFramesPerPacket == 1 else {throw LibraryError("無法轉換此輸入串流：\(Self.summary(description))")}
        var asbd = description
        let layout = AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_DiscreteInOrder | description.mChannelsPerFrame)!
        guard let format = AVAudioFormat(streamDescription:&asbd,channelLayout:layout) else {throw LibraryError("無法建立輸入轉換器：\(Self.summary(description))")}
        self.format = format
        bufferChannels = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Array(repeating:1,count:Int(description.mChannelsPerFrame)) : [description.mChannelsPerFrame]
    }
    static func summary(_ f:AudioStreamBasicDescription) -> String {"\(f.mSampleRate) Hz / \(f.mChannelsPerFrame)ch / \(f.mBitsPerChannel)bit / flags=\(f.mFormatFlags) / frameBytes=\(f.mBytesPerFrame)"}
    func copy(_ buffers:ArraySlice<AudioBuffer>) throws -> AVAudioPCMBuffer {
        guard buffers.map({$0.mNumberChannels}) == bufferChannels else {throw LibraryError("音訊聲道配置已變更，錄音已停止。")}
        var frames:Int?
        for buffer in buffers {
            let bytes = Int(buffer.mDataByteSize);let stride = Int(description.mBytesPerFrame)
            guard buffer.mData != nil, bytes > 0, bytes % stride == 0, bytes/stride <= 262144,
                  frames == nil || frames == bytes/stride else {throw LibraryError("音訊區塊長度不符，已停止錄音。")}
            frames = bytes/stride
        }
        guard let frames, let result = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames)) else {throw LibraryError("無法建立音訊輸入區塊。")}
        result.frameLength = AVAudioFrameCount(frames)
        let destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        guard destination.count == buffers.count else {throw LibraryError("音訊輸入配置不受支援。")}
        for (index,source) in buffers.enumerated() {
            guard destination[index].mDataByteSize >= source.mDataByteSize, let target = destination[index].mData else {throw LibraryError("音訊輸入緩衝區不足。")}
            target.copyMemory(from:source.mData!,byteCount:Int(source.mDataByteSize))
            destination[index].mDataByteSize = source.mDataByteSize
        }
        return result
    }
}

final class PCMStreamConverter {
    let layout:PCMInputLayout
    private let outputFormat:AVAudioFormat
    private let converter:AVAudioConverter
    init(_ layout:PCMInputLayout) throws {
        self.layout = layout
        let channelLayout = AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_DiscreteInOrder | UInt32(layout.channels))!
        let output = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,interleaved:false,channelLayout:channelLayout)
        guard let converter = AVAudioConverter(from:layout.format,to:output) else {throw LibraryError("無法轉換輸入串流：\(PCMInputLayout.summary(layout.description))")}
        outputFormat = output;self.converter = converter
    }
    func convert(_ input:AVAudioPCMBuffer?) throws -> [[Float]] {
        let capacity = input.map {AVAudioFrameCount(ceil(Double($0.frameLength)*16000/layout.description.mSampleRate)+512)} ?? 2048
        guard let output = AVAudioPCMBuffer(pcmFormat:outputFormat,frameCapacity:capacity) else {throw LibraryError("無法建立轉換輸出區塊。")}
        var supplied = false;var error:NSError?
        let status = converter.convert(to:output,error:&error) {_,result in
            if let input, !supplied {supplied = true;result.pointee = .haveData;return input}
            result.pointee = input == nil ? .endOfStream : .noDataNow;return nil
        }
        if let error {throw error}
        guard status != .error, let channels = output.floatChannelData else {throw LibraryError("音訊格式轉換失敗。")}
        return try (0..<layout.channels).map {channel in
            let samples = Array(UnsafeBufferPointer(start:channels[channel],count:Int(output.frameLength)))
            guard samples.allSatisfy({$0.isFinite}) else {throw LibraryError("音訊轉換產生無效樣本，已停止錄音。")}
            return samples
        }
    }
}

/// Per-stream streaming conversion followed by bounded FIFOs. A 48 kHz mic and a 24 kHz
/// Bluetooth call stream can supply different frame counts in the same hardware IO cycle.
final class PCMInputMixer {
    let layouts:[PCMInputLayout]
    private let converters:[PCMStreamConverter]
    private var queues:[[[Float]]]
    private var offsets:[Int]
    private let microphoneChannels:Int
    private let totalChannels:Int
    private(set) var paddedTailFrames = 0
    init(layouts:[PCMInputLayout], microphoneChannels:Int, totalChannels:Int) throws {
        guard !layouts.isEmpty, totalChannels > microphoneChannels, microphoneChannels >= 0,
              layouts.reduce(0,{$0+$1.channels}) == totalChannels else {throw LibraryError("輸入串流聲道配置不符。")}
        var next = 0
        for layout in layouts {guard layout.firstChannel == next else {throw LibraryError("輸入串流聲道順序不符。")};next += layout.channels}
        self.layouts = layouts;self.microphoneChannels = microphoneChannels;self.totalChannels = totalChannels
        converters = try layouts.map {try PCMStreamConverter($0)}
        queues = layouts.map {Array(repeating:[],count:$0.channels)};offsets = Array(repeating:0,count:layouts.count)
    }
    func copy(_ pointer:UnsafePointer<AudioBufferList>) throws -> [AVAudioPCMBuffer] {
        let buffers = Array(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:pointer)))
        guard buffers.count == layouts.reduce(0,{$0+$1.bufferChannels.count}) else {throw LibraryError("輸入串流數量已改變，已停止錄音。")}
        var cursor = 0
        return try layouts.map {layout in
            defer {cursor += layout.bufferChannels.count}
            return try layout.copy(buffers[cursor..<(cursor+layout.bufferChannels.count)])
        }
    }
    func append(_ inputs:[AVAudioPCMBuffer]) throws -> CaptureInputBlock {
        guard inputs.count == converters.count else {throw LibraryError("音訊來源不完整。")}
        for index in converters.indices {try add(converters[index].convert(inputs[index]),at:index)}
        return try drain(final:false)
    }
    private func add(_ channels:[[Float]], at index:Int) throws {
        guard channels.count == queues[index].count else {throw LibraryError("轉換後聲道不符。")}
        for channel in channels.indices {queues[index][channel].append(contentsOf:channels[channel])}
        guard queues[index][0].count-offsets[index] <= 32000 else {throw LibraryError("音訊來源時間長度不一致，已停止並保留錄音。")}
    }
    func finish() throws -> CaptureInputBlock {
        for index in converters.indices {try add(converters[index].convert(nil),at:index)}
        return try drain(final:true)
    }
    private func drain(final:Bool) throws -> CaptureInputBlock {
        let counts = queues.indices.map {queues[$0][0].count-offsets[$0]}
        if final, (counts.max() ?? 0)-(counts.min() ?? 0) > 320 {throw LibraryError("錄音來源尾端相差超過 20ms，請檢查錄音；已寫入部分保留。")}
        let count = final ? (counts.max() ?? 0) : (counts.min() ?? 0)
        var mic = microphoneChannels > 0 ? [Float](repeating:0,count:count) : []
        var system = [Float](repeating:0,count:count)
        for index in queues.indices {
            for channel in queues[index].indices {
                let globalChannel = layouts[index].firstChannel+channel
                for frame in 0..<min(count,counts[index]) {
                    let value = queues[index][channel][offsets[index]+frame]
                    if globalChannel < microphoneChannels {mic[frame] += value/Float(microphoneChannels)}
                    else {system[frame] += value/Float(totalChannels-microphoneChannels)}
                }
            }
            if final {paddedTailFrames = max(paddedTailFrames,count-counts[index])}
            offsets[index] += min(count,counts[index])
            if offsets[index] >= 4096 || final {
                for channel in queues[index].indices {queues[index][channel].removeFirst(offsets[index])}
                offsets[index] = 0
            }
        }
        return CaptureInputBlock(microphone:mic,system:system)
    }
}
