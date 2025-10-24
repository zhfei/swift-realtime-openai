import Core
import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	public enum WebRTCError: Error {
		case invalidEphemeralKey
		case missingAudioPermission
		case failedToCreateDataChannel
		case failedToCreatePeerConnection
		case badServerResponse(URLResponse)
		case failedToCreateSDPOffer(Swift.Error)
		case failedToSetLocalDescription(Swift.Error)
		case failedToSetRemoteDescription(Swift.Error)
	}

	public let events: AsyncThrowingStream<ServerEvent, Error>
	@MainActor public private(set) var status = RealtimeAPI.Status.disconnected

	public var isMuted: Bool {
		!audioTrack.isEnabled
	}

	package let audioTrack: LKRTCAudioTrack
	private let dataChannel: LKRTCDataChannel
	private let connection: LKRTCPeerConnection

	// 添加音频录制器
	private var audioRecorder: WebRTCAudioRecorder?
	public var isRecordingEnabled: Bool = false

	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		return LKRTCPeerConnectionFactory()
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return decoder
	}()

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		(events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self
	}

	deinit {
		disconnect()
	}

	package func connect(using request: URLRequest) async throws {
		guard connection.connectionState == .new else { return }

		guard AVAudioApplication.shared.recordPermission == .granted else {
			throw WebRTCError.missingAudioPermission
		}

		try await performHandshake(using: request)
		Self.configureAudioSession()
	}

	public func send(event: ClientEvent) throws {
		try dataChannel.sendData(LKRTCDataBuffer(data: encoder.encode(event), isBinary: false))
	}

	public func disconnect() {
		connection.close()
		stream.finish()
	}

	public func toggleMute() {
		audioTrack.isEnabled.toggle()
	}

	// 添加录制控制方法
	public func startRecording() throws -> URL {
		let recorder = WebRTCAudioRecorder()
		let (remoteURL, localURL) = try recorder.startRecording()
		audioRecorder = recorder
		
		// 如果已经有远程音频流，立即添加渲染器
		// 注意：需要等待peerConnection(_:didAdd:)回调
		
		print("🎙️ [WebRTCConnector] 开始录制音频")
		return remoteURL
	}

	public func stopRecording() -> URL? {
		let url = audioRecorder?.stopRecording()
		audioRecorder = nil
		print("🎙️ [WebRTCConnector] 停止录制音频")
		return url
	}
}

extension WebRTCConnector {
	public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
		let connector = try create()
		try await connector.connect(using: request)
		return connector
	}

	package static func create() throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(connection: connection, audioTrack: audioTrack, dataChannel: dataChannel)
	}
}

private extension WebRTCConnector {
	static func setupLocalAudio(for connection: LKRTCPeerConnection) -> LKRTCAudioTrack {
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
			mandatoryConstraints: [
				"googNoiseSuppression": "true", "googHighpassFilter": "true",
				"googEchoCancellation": "true", "googAutoGainControl": "true",
			],
			optionalConstraints: nil
		))

		return tap(factory.audioTrack(with: audioSource, trackId: "local_audio")) { audioTrack in
			connection.add(audioTrack, streamIds: ["local_stream"])
		}
	}

	static func configureAudioSession() {
		#if !os(macOS)
		do {
			let audioSession = AVAudioSession.sharedInstance()
			#if os(tvOS)
			try audioSession.setCategory(.playAndRecord, options: [])
			#else
			try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
			#endif
			try audioSession.setMode(.videoChat)
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
		} catch {
			print("Failed to configure AVAudioSession: \(error)")
		}
		#endif
	}

	func performHandshake(using request: URLRequest) async throws {
		let sdp = try await Result { try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil)) }
			.mapError(WebRTCError.failedToCreateSDPOffer)
			.get()

		do { try await connection.setLocalDescription(sdp) }
		catch { throw WebRTCError.failedToSetLocalDescription(error) }

		let remoteSdp = try await fetchRemoteSDP(using: request, localSdp: connection.localDescription!.sdp)

		do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: remoteSdp)) }
		catch { throw WebRTCError.failedToSetRemoteDescription(error) }
	}

	private func fetchRemoteSDP(using request: URLRequest, localSdp: String) async throws -> String {
		var request = request
		request.httpBody = localSdp.data(using: .utf8)
		request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let response = response as? HTTPURLResponse, response.statusCode == 201, let remoteSdp = String(data: data, encoding: .utf8) else {
			if (response as? HTTPURLResponse)?.statusCode == 401 { throw WebRTCError.invalidEphemeralKey }
			throw WebRTCError.badServerResponse(response)
		}

		return remoteSdp
	}
}

extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
	public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
		print("🎧 [WebRTCConnector] 收到远程音频流")
		
		// 遍历音频轨道
		for audioTrack in stream.audioTracks {
			print("🎧 [WebRTCConnector] 添加远程音频轨道: \(audioTrack.trackId)")
			
			// 如果启用了录制，添加音频渲染器
			if isRecordingEnabled, let recorder = audioRecorder {
				audioTrack.add(recorder)
				print("✅ [WebRTCConnector] 已添加音频渲染器")
			}
		}
	}
	public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
	public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

	public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
		print("ICE Connection State changed to: \(newState)")
	}
}

extension WebRTCConnector: LKRTCDataChannelDelegate {
	public func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
		do { try stream.yield(decoder.decode(ServerEvent.self, from: buffer.data)) }
		catch {
			print("Failed to decode server event: \(String(data: buffer.data, encoding: .utf8) ?? "<invalid utf8>")")
			stream.finish(throwing: error)
		}
	}

	public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
		Task { @MainActor [state = dataChannel.readyState] in
			switch state {
				case .open: status = .connected
				case .closing, .closed: status = .disconnected
				default: break
			}
		}
	}
}
