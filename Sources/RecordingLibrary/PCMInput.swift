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

/// Preserve PCM representation independently from the clock used to deliver its frames.
/// HAL can resample a drift-compensated 24 kHz tap onto a 48 kHz aggregate clock while
/// its stream metadata still reports 24 kHz. Resolve this from the actual IO frame counts.
/// Bounded FIFO reconciliation reports timing corrections without terminating a recording.
final class PCMInputMixer {
    let layouts:[PCMInputLayout]
    private var converters:[PCMStreamConverter]
    private var conversionLayouts:[PCMInputLayout]
    private let aggregateSampleRate:Double?
    private var clockResolved = false
    private(set) var effectiveSampleRates:[Double]
    private(set) var correctedClockStreams = 0
    private(set) var initialInputFrames:[Int] = []
    private(set) var synchronizationCorrections = 0
    private(set) var resampledFrames = 0
    private(set) var insertedSilenceFrames = 0
    private(set) var maximumSkewFrames = 0
    var bufferedFrames:Int {queues.indices.map {queues[$0][0].count-offsets[$0]}.max() ?? 0}
    private var queues:[[[Float]]]
    private var offsets:[Int]
    private let microphoneChannels:Int
    private let totalChannels:Int
    private(set) var paddedTailFrames = 0
    init(layouts:[PCMInputLayout], microphoneChannels:Int, totalChannels:Int, aggregateSampleRate:Double? = nil) throws {
        guard !layouts.isEmpty, totalChannels > microphoneChannels, microphoneChannels >= 0,
              layouts.reduce(0,{$0+$1.channels}) == totalChannels else {throw LibraryError("輸入串流聲道配置不符。")}
        var next = 0
        for layout in layouts {guard layout.firstChannel == next else {throw LibraryError("輸入串流聲道順序不符。")};next += layout.channels}
        self.layouts = layouts;self.microphoneChannels = microphoneChannels;self.totalChannels = totalChannels
        self.aggregateSampleRate = aggregateSampleRate
        conversionLayouts = layouts;effectiveSampleRates = layouts.map {$0.description.mSampleRate}
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
        try resolveClock(inputs)
        for index in converters.indices {
            let input:AVAudioPCMBuffer
            if effectiveSampleRates[index] != layouts[index].description.mSampleRate {
                // Only the clock rate changes; channel layout, sample type and bytes stay identical.
                let buffers = Array(UnsafeMutableAudioBufferListPointer(inputs[index].mutableAudioBufferList))
                input = try conversionLayouts[index].copy(buffers[...])
            } else {input = inputs[index]}
            try add(converters[index].convert(input),at:index)
        }
        reconcile()
        return try drain(final:false)
    }
    private func resolveClock(_ inputs:[AVAudioPCMBuffer]) throws {
        guard !clockResolved else {return}
        initialInputFrames = inputs.map {Int($0.frameLength)}
        guard let rate = aggregateSampleRate, rate.isFinite, rate > 0,
              let reference = layouts.indices.first(where:{abs(layouts[$0].description.mSampleRate-rate) < 1}),
              inputs[reference].frameLength > 0 else {clockResolved = true;return}
        let duration = Double(inputs[reference].frameLength)/rate
        var resolved = layouts
        for index in layouts.indices where abs(layouts[index].description.mSampleRate-rate) > 1 {
            let frames = Double(inputs[index].frameLength)
            let nativeError = abs(frames/layouts[index].description.mSampleRate-duration)
            let sharedError = abs(frames/rate-duration)
            // Require equal aggregate-clock frames and a clear distinction from native-rate IO.
            if sharedError <= 1/rate, nativeError > 2/rate {
                var format = layouts[index].description;format.mSampleRate = rate
                resolved[index] = try PCMInputLayout(format,firstChannel:layouts[index].firstChannel)
            }
        }
        let converted = try resolved.map {try PCMStreamConverter($0)}
        conversionLayouts = resolved;converters = converted
        effectiveSampleRates = resolved.map {$0.description.mSampleRate}
        correctedClockStreams = layouts.indices.filter {effectiveSampleRates[$0] != layouts[$0].description.mSampleRate}.count
        clockResolved = true
    }
    private func reconcile() {
        let counts = queues.indices.map {queues[$0][0].count-offsets[$0]}
        let maximum = counts.max() ?? 0, minimum = counts.min() ?? 0
        maximumSkewFrames = max(maximumSkewFrames,maximum-minimum)
        // Leave room for resampler priming and ordinary callback jitter. Never grow an
        // unbounded queue or stop merely because the two clocks disagree.
        guard maximum-minimum > 3200 else {return}
        synchronizationCorrections += 1
        // The first stream is the microphone/master timeline when present. A lagging
        // secondary source must not compress the good microphone audio to its short duration.
        let reference = counts[0] > 0 ? counts[0] : maximum
        for index in queues.indices {
            if counts[index] < reference-160 {
                let missing = reference-160-counts[index]
                for channel in queues[index].indices {queues[index][channel].append(contentsOf:repeatElement(Float(0),count:missing))}
                insertedSilenceFrames += missing
            } else if counts[index] > reference+160 {
                let target = reference+160
                for channel in queues[index].indices {
                    let source = Array(queues[index][channel].dropFirst(offsets[index]))
                    // Preserve the source interval through interpolation, rather than dropping
                    // a whole speech block. This recovery can affect pitch and is audited.
                    let scale = Double(source.count-1)/Double(target-1)
                    queues[index][channel] = (0..<target).map {frame in
                        let position = Double(frame)*scale
                        let lower = min(source.count-1,Int(position)), upper = min(source.count-1,lower+1)
                        return source[lower]+(source[upper]-source[lower])*Float(position-Double(lower))
                    }
                }
                resampledFrames += counts[index]-target;offsets[index] = 0
            }
        }
    }

    private func add(_ channels:[[Float]], at index:Int) throws {
        guard channels.count == queues[index].count else {throw LibraryError("轉換後聲道不符。")}
        for channel in channels.indices {queues[index][channel].append(contentsOf:channels[channel])}
    }
    func finish() throws -> CaptureInputBlock {
        for index in converters.indices {try add(converters[index].convert(nil),at:index)}
        return try drain(final:true)
    }
    private func drain(final:Bool) throws -> CaptureInputBlock {
        let counts = queues.indices.map {queues[$0][0].count-offsets[$0]}
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
