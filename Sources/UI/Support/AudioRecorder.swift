import AVFoundation
import Foundation

/// ????????????????????
@MainActor
public final class AudioRecorder: ObservableObject {
    /// ????
    public enum RecordingState {
        case idle
        case recording
        case paused
        case stopped
    }
    
    @Published public private(set) var state: RecordingState = .idle
    @Published public private(set) var duration: TimeInterval = 0
    
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private var recordingURL: URL?
    
    /// ??????
    private var startTime: Date?
    
    /// ??????????????
    private var pausedTime: TimeInterval = 0
    
    /// ????????
    /// - Parameter format: ???????? PCM 16-bit, 24kHz, ???
    public init(format: AVAudioFormat? = nil) {
        // ?????PCM 16-bit, 24kHz, ????OpenAI Realtime API ?????
        self.audioFormat = format ?? AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )
    }
    
    /// ????
    /// - Parameter url: ??????? URL
    public func startRecording(to url: URL) throws {
        guard state == .idle || state == .stopped else {
            throw RecordingError.alreadyRecording
        }
        
        // ??????
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // ????????
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        
        recordingURL = url
        startTime = Date()
        pausedTime = 0
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        
        // ????????????????
        let recordingFormat = self.audioFormat ?? format
        
        // ??????
        guard let audioFile = try? AVAudioFile(forWriting: url, settings: recordingFormat.settings) else {
            throw RecordingError.failedToCreateFile
        }
        
        self.audioFile = audioFile
        self.audioEngine = engine
        
        // ?? tap ???????
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
            guard let self = self, let file = self.audioFile else { return }
            
            do {
                try file.write(from: buffer)
            } catch {
                print("Error writing audio buffer: \(error)")
            }
        }
        
        // ??????
        try engine.start()
        
        state = .recording
    }
    
    /// ????
    public func pause() {
        guard state == .recording else { return }
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        
        if let startTime = startTime {
            pausedTime += Date().timeIntervalSince(startTime)
        }
        
        state = .paused
    }
    
    /// ????
    public func resume() throws {
        guard state == .paused, let url = recordingURL else {
            throw RecordingError.notPaused
        }
        
        startTime = Date()
        
        let engine = audioEngine ?? AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        let recordingFormat = self.audioFormat ?? format
        
        // ????????????????
        guard let audioFile = try? AVAudioFile(forWriting: url, settings: recordingFormat.settings) else {
            throw RecordingError.failedToCreateFile
        }
        
        self.audioFile = audioFile
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
            guard let self = self, let file = self.audioFile else { return }
            
            do {
                try file.write(from: buffer)
            } catch {
                print("Error writing audio buffer: \(error)")
            }
        }
        
        try engine.start()
        
        state = .recording
    }
    
    /// ????
    public func stop() {
        guard state == .recording || state == .paused else { return }
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        
        if let startTime = startTime, state == .recording {
            pausedTime += Date().timeIntervalSince(startTime)
        }
        
        duration = pausedTime
        audioFile = nil
        audioEngine = nil
        state = .stopped
    }
    
    /// ????????? URL
    public func getRecordingURL() -> URL? {
        return recordingURL
    }
    
    deinit {
        stop()
    }
}

extension AudioRecorder {
    public enum RecordingError: Error {
        case alreadyRecording
        case notPaused
        case failedToCreateFile
        case noActiveRecording
    }
}