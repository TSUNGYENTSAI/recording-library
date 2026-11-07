import Foundation
import AVFoundation

@main struct PCMInputChecks {
    static func check(_ condition:@autoclosure () throws -> Bool,_ message:String) throws {if try !condition() {throw LibraryError(message)}}
    static func buffer(format:AVAudioFormat, offset:Int, frames:Int, signal:(Double)->Double) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames))!;result.frameLength = result.frameCapacity
        for plane in UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList) {
            let count = Int(plane.mNumberChannels)
            for frame in 0..<frames {
                let value = signal(Double(offset+frame)/format.sampleRate)
                for channel in 0..<count {
                    let index = frame*count+channel
                    switch format.commonFormat {
                    case .pcmFormatFloat32:plane.mData!.assumingMemoryBound(to:Float.self)[index] = Float(value)
                    case .pcmFormatFloat64:plane.mData!.assumingMemoryBound(to:Double.self)[index] = value
                    case .pcmFormatInt16:plane.mData!.assumingMemoryBound(to:Int16.self)[index] = Int16(value*32767)
                    case .pcmFormatInt32:plane.mData!.assumingMemoryBound(to:Int32.self)[index] = Int32(value*2147483647)
                    default:fatalError("Unsupported test fixture")
                    }
                }
            }
        }
        return result
    }
    static func copy(_ buffers:[AVAudioPCMBuffer], mixer:PCMInputMixer) throws -> [AVAudioPCMBuffer] {
        let source = buffers.flatMap {Array(UnsafeMutableAudioBufferListPointer($0.mutableAudioBufferList))}
        let size = MemoryLayout<AudioBufferList>.size+(source.count-1)*MemoryLayout<AudioBuffer>.stride
        let memory = UnsafeMutableRawPointer.allocate(byteCount:size,alignment:MemoryLayout<AudioBufferList>.alignment);defer {memory.deallocate()}
        let pointer = memory.assumingMemoryBound(to:AudioBufferList.self);pointer.pointee.mNumberBuffers = UInt32(source.count)
        let target = UnsafeMutableAudioBufferListPointer(pointer)
        for index in source.indices {target[index] = source[index]}
        return try withExtendedLifetime(buffers) {try mixer.copy(UnsafePointer(pointer))}
    }
    static func magnitude(_ samples:[Float],hz:Double) -> Double {
        var real = 0.0;var imaginary = 0.0
        for index in 400..<(samples.count-400) {let phase = 2 * Double.pi * hz * Double(index)/16000;real += Double(samples[index])*cos(phase);imaginary += Double(samples[index])*sin(phase)}
        return 2*hypot(real,imaginary)/Double(samples.count-800)
    }
    static func main() throws {
        let workspace = URL(fileURLWithPath:CommandLine.arguments[1]);var results:[[String:Any]] = []
        let cases:[(Double,Double,AVAudioCommonFormat,Bool)] = [(48000,24000,.pcmFormatFloat32,true),(48000,24000,.pcmFormatInt16,true),(44100,48000,.pcmFormatInt32,false),(48000,24000,.pcmFormatFloat64,false),(16000,48000,.pcmFormatFloat32,false)]
        for (micRate,sysRate,kind,interleaved) in cases {
            let micFormat = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:micRate,channels:1,interleaved:false)!
            let sysFormat = AVAudioFormat(commonFormat:kind,sampleRate:sysRate,channels:2,interleaved:interleaved)!
            let mixer = try PCMInputMixer(layouts:[PCMInputLayout(micFormat.streamDescription.pointee,firstChannel:0),PCMInputLayout(sysFormat.streamDescription.pointee,firstChannel:1)],microphoneChannels:1,totalChannels:3)
            var cursor = 0;var output:[Float] = []
            while cursor < 500 {
                let cycles = min([1,2,4,3][cursor%4],500-cursor)
                let mic = buffer(format:micFormat,offset:Int(Double(cursor)*micRate/100),frames:Int(Double(cycles)*micRate/100)) {0.6*sin(2 * Double.pi * 300 * $0)}
                let sys = buffer(format:sysFormat,offset:Int(Double(cursor)*sysRate/100),frames:Int(Double(cycles)*sysRate/100)) {0.6*sin(2 * Double.pi * 1100 * $0)}
                let owned = try copy([mic,sys],mixer:mixer)
                // Verify the IO callback copied data before hardware reuses its source memory.
                for source in [mic,sys] {for plane in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {memset(plane.mData!,0,Int(plane.mDataByteSize))}}
                let block = try mixer.append(owned)
                output += try MixedAudioWriter.mix(microphone:block.microphone,system:block.system,mode:.both)
                cursor += cycles
            }
            let tail = try mixer.finish();output += try MixedAudioWriter.mix(microphone:tail.microphone,system:tail.system,mode:.both)
            let micAmplitude = magnitude(output,hz:300);let sysAmplitude = magnitude(output,hz:1100)
            try check(abs(output.count-80000) <= 32,"不同來源取樣率造成時間偏移：\(output.count)")
            try check(abs(micAmplitude-0.3) < 0.015 && abs(sysAmplitude-0.3) < 0.015,"格式轉換遺失或錯誤縮放來源")
            try check(output.allSatisfy {$0.isFinite && abs($0) <= 1},"格式轉換產生無效資料")
            results.append(["microphoneSampleRate":micRate,"systemSampleRate":sysRate,"systemPCMType":kind.rawValue,"systemInterleaved":interleaved,"outputFrames":output.count,"micAmplitude":micAmplitude,"systemAmplitude":sysAmplitude,"paddedTailFrames":mixer.paddedTailFrames])
        }
        // Equal-time impulses remain aligned after different resampling filter histories.
        let micFormat = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let sysFormat = AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:24000,channels:1,interleaved:true)!
        let mixer = try PCMInputMixer(layouts:[PCMInputLayout(micFormat.streamDescription.pointee,firstChannel:0),PCMInputLayout(sysFormat.streamDescription.pointee,firstChannel:1)],microphoneChannels:1,totalChannels:2)
        var micOutput:[Float] = [];var sysOutput:[Float] = []
        for cycle in 0..<200 {
            let pulse:(Double)->Double = {0.8*exp(-pow(($0-1)/0.001,2))}
            let block = try mixer.append(copy([buffer(format:micFormat,offset:cycle*480,frames:480,signal:pulse),buffer(format:sysFormat,offset:cycle*240,frames:240,signal:pulse)],mixer:mixer))
            micOutput += block.microphone;sysOutput += block.system
        }
        let tail = try mixer.finish();micOutput += tail.microphone;sysOutput += tail.system
        let micPeak = micOutput.indices.max(by:{micOutput[$0] < micOutput[$1]})!
        let sysPeak = sysOutput.indices.max(by:{sysOutput[$0] < sysOutput[$1]})!
        try check(abs(micPeak-sysPeak) <= 2 && abs(micPeak-16000) <= 2,"不同格式來源的同時事件未對齊")
        // Sustained missing/overlong sources must fail rather than grow a queue or silently drop speech.
        let broken = try PCMInputMixer(layouts:[PCMInputLayout(micFormat.streamDescription.pointee,firstChannel:0),PCMInputLayout(sysFormat.streamDescription.pointee,firstChannel:1)],microphoneChannels:1,totalChannels:2)
        var rejected = false
        for _ in 0..<250 {
            do {_ = try broken.append(copy([buffer(format:micFormat,offset:0,frames:480) {_ in 0.1},buffer(format:sysFormat,offset:0,frames:480) {_ in 0.1}],mixer:broken))}
            catch {rejected = true;break}
        }
        try check(rejected,"不同步來源沒有觸發有界緩衝保護")
        let report:[String:Any] = ["passed":true,"version":"0.7.1","physicalCaptureStarted":false,"cases":results,"impulseAlignmentFrames":abs(micPeak-sysPeak),"checks":["48 kHz mic plus 24 kHz Bluetooth-call stream","per-stream Int16 Int32 Float32 Float64 conversion","interleaved and planar layouts","different per-source IO frame counts","bounded FIFO rejects persistent duration mismatch","hardware buffers copied before reuse","gain and both frequencies preserved","streaming duration preserved","equal-time impulses align within two 16 kHz frames"]]
        try FileManager.default.createDirectory(at:workspace.appendingPathComponent(".build/test-results"),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:workspace.appendingPathComponent(".build/test-results/pcm-input.json"),options:.atomic)
        print("PCM INPUT CHECKS PASSED")
    }
}
