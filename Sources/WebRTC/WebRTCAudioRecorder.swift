import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC

@MainActor
public final class WebRTCAudioRecorder: NSObject, LKRTCAudioRenderer {
    
    private var remoteAudioFile: AVAudioFile?
    private var localAudioFile: AVAudioFile?
    private var isRecording = false
    private var remoteAudioURL: URL?
    private var localAudioURL: URL?
    
    /// 开始录制
    public func startRecording() throws -> (remote: URL, local: URL) {
        let tempDir = FileManager.default.temporaryDirectory
        let remoteFileName = "remote_\(UUID().uuidString).wav"
        let localFileName = "local_\(UUID().uuidString).wav"
        
        remoteAudioURL = tempDir.appendingPathComponent(remoteFileName)
        localAudioURL = tempDir.appendingPathComponent(localFileName)
        
        // 创建音频文件（PCM格式，便于后续处理）
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000.0,  // WebRTC通常使用24kHz
            AVNumberOfChannelsKey: 1,   // 单声道
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        remoteAudioFile = try AVAudioFile(forWriting: remoteAudioURL!, settings: settings)
        localAudioFile = try AVAudioFile(forWriting: localAudioURL!, settings: settings)
        
        isRecording = true
        print("🎙️ [WebRTCAudioRecorder] 开始录制音频到: \(remoteAudioURL!.lastPathComponent)")
        return (remoteAudioURL!, localAudioURL!)
    }
    
    /// LKRTCAudioRenderer协议方法 - 接收远程音频数据
    public func renderPCMData(_ audioData: UnsafePointer<Int16>, 
                              samples: Int, 
                              sampleRate: Double, 
                              channels: Int) {
        guard isRecording, let file = remoteAudioFile else { return }
        
        // 将PCM数据写入文件
        autoreleasepool {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: true
            )!
            
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples)
            ) else { return }
            
            buffer.frameLength = AVAudioFrameCount(samples)
            
            // 复制音频数据
            let channelData = buffer.int16ChannelData!
            for i in 0..<samples * channels {
                channelData.pointee[i] = audioData[i]
            }
            
            do {
                try file.write(from: buffer)
            } catch {
                print("❌ [WebRTCAudioRecorder] 写入远程音频失败: \(error)")
            }
        }
    }
    
    /// 写入本地音频数据（从麦克风）
    public func writeLocalAudio(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let file = localAudioFile else { return }
        
        do {
            try file.write(from: buffer)
        } catch {
            print("❌ [WebRTCAudioRecorder] 写入本地音频失败: \(error)")
        }
    }
    
    /// 停止录制并合并音频
    public func stopRecording() -> URL? {
        isRecording = false
        
        remoteAudioFile = nil
        localAudioFile = nil
        
        // 合并远程和本地音频
        guard let remoteURL = remoteAudioURL,
              let localURL = localAudioURL else {
            print("⚠️ [WebRTCAudioRecorder] 音频文件URL为空")
            return nil
        }
        
        let mergedURL = mergeAudioFiles(remote: remoteURL, local: localURL)
        print("🎙️ [WebRTCAudioRecorder] 停止录制音频: \(mergedURL?.lastPathComponent ?? "nil")")
        return mergedURL
    }
    
    /// 合并远程和本地音频文件
    private func mergeAudioFiles(remote: URL, local: URL) -> URL? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation_\(UUID().uuidString).m4a")
        
        do {
            // 使用AVAssetExportSession合并音频
            let remoteAsset = AVAsset(url: remote)
            let localAsset = AVAsset(url: local)
            
            let composition = AVMutableComposition()
            
            // 添加远程音频轨道（AI语音）
            guard let remoteTrack = remoteAsset.tracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                print("❌ [WebRTCAudioRecorder] 无法添加远程音频轨道")
                return nil
            }
            
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: remoteAsset.duration),
                of: remoteTrack,
                at: .zero
            )
            
            // 添加本地音频轨道（用户语音）
            guard let localTrack = localAsset.tracks(withMediaType: .audio).first,
                  let localCompositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                print("❌ [WebRTCAudioRecorder] 无法添加本地音频轨道")
                return nil
            }
            
            try localCompositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: localAsset.duration),
                of: localTrack,
                at: .zero
            )
            
            // 导出合并后的音频
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                print("❌ [WebRTCAudioRecorder] 无法创建导出会话")
                return nil
            }
            
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            
            let semaphore = DispatchSemaphore(value: 0)
            var exportError: Error?
            
            exportSession.exportAsynchronously {
                if exportSession.status == .failed {
                    exportError = exportSession.error
                }
                semaphore.signal()
            }
            
            semaphore.wait()
            
            if let error = exportError {
                print("❌ [WebRTCAudioRecorder] 音频合并失败: \(error)")
                return nil
            }
            
            print("✅ [WebRTCAudioRecorder] 音频合并成功: \(outputURL.lastPathComponent)")
            return outputURL
            
        } catch {
            print("❌ [WebRTCAudioRecorder] 音频合并异常: \(error)")
            return nil
        }
    }
    
    /// 获取录制状态
    public var isCurrentlyRecording: Bool {
        return isRecording
    }
    
    /// 获取远程音频文件URL
    public func getRemoteAudioURL() -> URL? {
        return remoteAudioURL
    }
    
    /// 获取本地音频文件URL
    public func getLocalAudioURL() -> URL? {
        return localAudioURL
    }
}

public enum WebRTCAudioRecorderError: Error {
    case fileCreationFailed
    case audioMergeFailed
    case invalidAudioFormat
}
