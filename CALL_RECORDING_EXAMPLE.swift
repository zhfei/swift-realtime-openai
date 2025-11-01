import SwiftUI
import RealtimeAPI

// MARK: - ???????????

struct CallRecordingExample: View {
    @State private var conversation = try! Conversation()
    @State private var isRecording = false
    @State private var recordingURL: URL?
    @State private var showShareSheet = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("AI ??????")
                .font(.title)
            
            // ????
            Text("??: \(conversation.status == .connected ? "???" : "???")")
            
            // ????
            if isRecording {
                Text("?? ????...")
                    .foregroundColor(.red)
            }
            
            // ????
            HStack(spacing: 20) {
                Button("????") {
                    startRecording()
                }
                .disabled(isRecording)
                
                Button("?????") {
                    stopAndSave()
                }
                .disabled(!isRecording)
            }
            
            // ????
            if let url = recordingURL {
                Button("????") {
                    showShareSheet = true
                }
            }
        }
        .task {
            // ?? API
            do {
                try await conversation.connect(
                    ephemeralKey: "YOUR_EPHEMERAL_KEY_HERE",
                    model: .gptRealtime
                )
                
                // ??????
                try conversation.startRecording()
                isRecording = true
            } catch {
                print("????: \(error)")
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = recordingURL {
                ShareSheet(items: [url])
            }
        }
    }
    
    func startRecording() {
        do {
            try conversation.startRecording()
            isRecording = true
        } catch {
            print("??????: \(error)")
        }
    }
    
    func stopAndSave() {
        conversation.stopRecording()
        isRecording = false
        
        // ???????
        let documentsPath = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        
        let outputURL = documentsPath.appendingPathComponent(
            "call_recording_\(Date().timeIntervalSince1970).m4a"
        )
        
        conversation.saveCallRecording(to: outputURL) { result in
            switch result {
            case .success(let url):
                recordingURL = url
                print("? ?????: \(url.path)")
                
            case .failure(let error):
                print("? ????: \(error)")
            }
        }
    }
}

// MARK: - ??????
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        return controller
    }
    
    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

// MARK: - ??????
class CallRecordingManager: ObservableObject {
    @Published var conversation: Conversation
    @Published var isRecording = false
    @Published var recordings: [URL] = []
    
    init() {
        self.conversation = try! Conversation()
    }
    
    // ???????
    func startCall(ephemeralKey: String) async throws {
        // ???????
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RecordingError.permissionDenied
        }
        
        // ??
        try await conversation.connect(
            ephemeralKey: ephemeralKey,
            model: .gptRealtime
        )
        
        // ????
        try conversation.startRecording()
        isRecording = true
    }
    
    // ???????
    func endCall(completion: @escaping (Result<URL, Error>) -> Void) {
        conversation.stopRecording()
        isRecording = false
        
        let outputURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "call_\(UUID().uuidString).m4a"
        )
        
        conversation.saveCallRecording(to: outputURL) { result in
            switch result {
            case .success(let url):
                self.recordings.append(url)
                completion(.success(url))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    // ??????
    func getAllRecordings() -> [URL] {
        return recordings
    }
}

enum RecordingError: Error {
    case permissionDenied
}