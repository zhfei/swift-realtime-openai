import AVFoundation
import Foundation

/// ?????????????????????
public enum AudioMerger {
    /// ????????
    /// - Parameters:
    ///   - audioURLs: ???????? URL ?????????
    ///   - outputURL: ???? URL
    ///   - completion: ????
    public static func merge(
        audioURLs: [URL],
        to outputURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !audioURLs.isEmpty else {
            completion(.failure(MergeError.noAudioFiles))
            return
        }
        
        // ????????
        let directory = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            // ????????
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
        } catch {
            completion(.failure(error))
            return
        }
        
        // ????????
        let composition = AVMutableComposition()
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        
        var currentTime = CMTime.zero
        
        Task {
            for audioURL in audioURLs {
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    continue
                }
                
                let asset = AVAsset(url: audioURL)
                
                do {
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard let assetTrack = tracks.first else {
                        continue
                    }
                    
                    let duration = try await asset.load(.duration)
                    
                    try audioTrack?.insertTimeRange(
                        CMTimeRange(start: .zero, duration: duration),
                        of: assetTrack,
                        at: currentTime
                    )
                    
                    currentTime = CMTimeAdd(currentTime, duration)
                } catch {
                    print("Error merging audio segment: \(error)")
                    continue
                }
            }
            
            // ????????
            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                completion(.failure(MergeError.failedToCreateExportSession))
                return
            }
            
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    completion(.success(outputURL))
                case .failed:
                    completion(.failure(exportSession.error ?? MergeError.exportFailed))
                case .cancelled:
                    completion(.failure(MergeError.exportCancelled))
                default:
                    completion(.failure(MergeError.unknownError))
                }
            }
        }
    }
    
    /// ????????????
    /// - Parameters:
    ///   - audioDataSegments: ???????????????
    ///   - outputURL: ???? URL
    ///   - format: ????
    ///   - completion: ????
    public static func merge(
        audioDataSegments: [Data],
        to outputURL: URL,
        format: AVAudioFormat,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !audioDataSegments.isEmpty else {
            completion(.failure(MergeError.noAudioFiles))
            return
        }
        
        // ????????
        let directory = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            // ????????
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
        } catch {
            completion(.failure(error))
            return
        }
        
        // ????????
        let mergedData = audioDataSegments.reduce(Data(), +)
        
        // ??????
        do {
            guard let audioFile = try? AVAudioFile(forWriting: outputURL, settings: format.settings) else {
                completion(.failure(MergeError.failedToCreateFile))
                return
            }
            
            // ?????? PCM ???
            guard let buffer = AVAudioPCMBuffer.fromData(mergedData, format: format) else {
                completion(.failure(MergeError.failedToCreateBuffer))
                return
            }
            
            try audioFile.write(from: buffer)
            completion(.success(outputURL))
        } catch {
            completion(.failure(error))
        }
    }
}

extension AudioMerger {
    public enum MergeError: Error {
        case noAudioFiles
        case failedToCreateFile
        case failedToCreateBuffer
        case failedToCreateExportSession
        case exportFailed
        case exportCancelled
        case unknownError
    }
}