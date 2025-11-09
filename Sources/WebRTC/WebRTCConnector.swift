import Core
import AVFAudio
import AVFoundation
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
		case failedToStartRecording(Swift.Error)
		case failedToStopRecording(Swift.Error)
		case failedToCreateAssetWriter(Swift.Error)
	}

	public let events: AsyncThrowingStream<ServerEvent, Error>
	@MainActor public private(set) var status = RealtimeAPI.Status.disconnected

	public var isMuted: Bool {
		!audioTrack.isEnabled
	}

	package let audioTrack: LKRTCAudioTrack
	private let dataChannel: LKRTCDataChannel
	private let connection: LKRTCPeerConnection

	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation
	
	// 录音相关属性
    nonisolated(unsafe) private var remoteAudioTrack: LKRTCAudioTrack?
    nonisolated(unsafe) private var audioEngine: AVAudioEngine?
    nonisolated(unsafe) private var remotePlayerNode: AVAudioPlayerNode?
    nonisolated(unsafe) private var fileHandle: FileHandle?
    nonisolated(unsafe) private var recordingURL: URL?
    nonisolated(unsafe) private var isRecording: Bool = false
    nonisolated(unsafe) private var wavDataSize: UInt32 = 0
    nonisolated(unsafe) private let recordingQueue = DispatchQueue(label: "com.realtime.recording", qos: .userInitiated)
	// 时间戳管理（统一管理，确保两路音频时间戳连续）
	nonisolated(unsafe) private var recordingStartTime: CMTime = .zero
	nonisolated(unsafe) private var lastPresentationTime: CMTime = .zero
	nonisolated(unsafe) private var totalFramesWritten: Int64 = 0
	// 时间戳锁，确保线程安全
	private let timestampLock = NSLock()
	// 统计信息：跳过的帧数（因为未准备好）
	nonisolated(unsafe) private var skippedFramesCount: Int64 = 0
	nonisolated(unsafe) private var skippedFramesCountLocal: Int64 = 0
	nonisolated(unsafe) private var skippedFramesCountRemote: Int64 = 0
	// 音频写入队列：用于串行化本地和远程音频的写入操作
	nonisolated(unsafe) private var audioWriteQueue: DispatchQueue?
	// 音频缓冲区队列：存储待写入的音频样本（改为存储 AVAudioPCMBuffer）
	nonisolated(unsafe) private var audioBufferQueue: [(pcmBuffer: AVAudioPCMBuffer, source: String)] = []
	// 缓冲区队列锁
	private let bufferQueueLock = NSLock()
	// 是否正在处理写入队列
	nonisolated(unsafe) private var isProcessingWriteQueue: Bool = false
	// 诊断统计：回调次数
	nonisolated(unsafe) private var localAudioCallbackCount: Int64 = 0
	nonisolated(unsafe) private var remoteAudioCallbackCount: Int64 = 0
	// 诊断统计：入队次数（按来源）
	nonisolated(unsafe) private var enqueueCountLocal: Int64 = 0
	nonisolated(unsafe) private var enqueueCountRemote: Int64 = 0
	// 诊断统计：队列处理次数
	nonisolated(unsafe) private var processQueueCount: Int64 = 0
    // 诊断日志：检查时间戳连续性（每100次打印一次）
    nonisolated(unsafe) var timestampCallCount: Int64 = 0
    nonisolated(unsafe) let timestampCallFlag: Int64 = 5000
	// 诊断统计：createSampleBuffer 调用次数（按来源）
	nonisolated(unsafe) private var createSampleBufferCountLocal: Int64 = 0
	nonisolated(unsafe) private var createSampleBufferCountRemote: Int64 = 0
	// 诊断统计：上次回调时间（用于检测回调间隔）
	nonisolated(unsafe) private var lastLocalCallbackTime: Date?
	nonisolated(unsafe) private var lastRemoteCallbackTime: Date?
	// 诊断定时器
	nonisolated(unsafe) private var diagnosticTimer: DispatchSourceTimer?
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

		connection.delegate = self as LKRTCPeerConnectionDelegate
		dataChannel.delegate = self as LKRTCDataChannelDelegate
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
		stopRecording()
		connection.close()
		stream.finish()
	}

	public func toggleMute() {
		audioTrack.isEnabled.toggle()
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
	
	// MARK: - 录音功能
	
	/// 开始录制电话对话
	func startRecording() async throws {
		guard !isRecording else { return }
		
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			recordingQueue.async { [weak self] in
				guard let self = self else {
					continuation.resume(throwing: WebRTCError.failedToStartRecording(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self is nil"])))
					return
				}
				
				do {
					print("========================================")
					print("[WebRTCConnector] 🎙️ 开始录制流程")
					print("========================================")
					
					// 创建录制文件URL
					let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
					let fileName = "recording_\(Date().timeIntervalSince1970).wav"
					let fileURL = documentsPath.appendingPathComponent(fileName)
					print("[WebRTCConnector] 📁 文件路径: \(fileURL.path)")
					
					// 如果文件已存在，删除它
					if FileManager.default.fileExists(atPath: fileURL.path) {
						try? FileManager.default.removeItem(at: fileURL)
						print("[WebRTCConnector] ⚠️ 已删除已存在的文件")
					}
					
					self.recordingURL = fileURL
					
					// 创建 WAV 文件并写入文件头
					try self.writeWAVHeader(to: fileURL, sampleRate: 24000, channels: 1, bitsPerSample: 16, dataSize: 0)
					
					// 打开文件句柄用于追加写入 PCM 数据
					guard let fileHandle = try? FileHandle(forWritingTo: fileURL) else {
						throw WebRTCError.failedToStartRecording(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法打开文件句柄"]))
					}
					
					// 移动到文件末尾（文件头之后）
					fileHandle.seekToEndOfFile()
					self.fileHandle = fileHandle
					
					print("[WebRTCConnector] 🎵 WAV 音频设置:")
					print("  - 格式: WAV (PCM)")
					print("  - 采样率: 24000 Hz")
					print("  - 声道数: 1 (单声道)")
					print("  - 位深度: 16 位")
					print("  - PCM格式: Int16, 小端序")
				
				self.wavDataSize = 0
				// 初始化时间戳
				self.recordingStartTime = .zero
				self.lastPresentationTime = .zero
				self.totalFramesWritten = 0
				// 初始化统计计数器
				self.skippedFramesCount = 0
				self.skippedFramesCountLocal = 0
				self.skippedFramesCountRemote = 0
				// 创建音频写入队列（串行队列，确保按顺序写入）
				self.audioWriteQueue = DispatchQueue(label: "com.realtime.audioWrite", qos: .userInitiated)
				self.audioBufferQueue = []
				self.isProcessingWriteQueue = false
				print("[WebRTCConnector] ✅ 时间戳管理器和统计计数器已初始化")
				print("[WebRTCConnector] ✅ 音频写入队列已创建")
				print("[WebRTCConnector] ✅ WAV 文件已创建，文件句柄已打开")
				
				// 配置 AVAudioSession 支持同时播放和录制
				let audioSession = AVAudioSession.sharedInstance()
				do {
					try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
					try audioSession.setActive(true)
					print("[WebRTCConnector] ✅ AVAudioSession 已配置为 playAndRecord 模式")
				} catch {
					print("[WebRTCConnector] ⚠️ AVAudioSession 配置失败: \(error.localizedDescription)")
				}
				
				// 创建 AVAudioEngine 用于混合音频
				let engine = AVAudioEngine()
				print("[WebRTCConnector] ✅ AVAudioEngine 创建成功")
				
				// 获取 inputNode 的硬件格式（必须使用硬件采样率，否则会崩溃）
				let inputFormat = engine.inputNode.inputFormat(forBus: 0)
				print("[WebRTCConnector] 📊 输入节点硬件格式:")
				print("  - 采样率: \(inputFormat.sampleRate) Hz")
				print("  - 声道数: \(inputFormat.channelCount)")
				print("  - 格式: \(inputFormat.commonFormat.rawValue)")
				print("  - 是否交错: \(inputFormat.isInterleaved)")
				
				guard inputFormat.sampleRate > 0 else {
					print("[WebRTCConnector] ❌ 输入节点采样率无效: \(inputFormat.sampleRate)")
					throw WebRTCError.failedToStartRecording(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取输入节点格式"]))
				}
				
				// 创建格式转换器，将硬件格式转换为目标格式（24000 Hz）
				guard let converterFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false) else {
					print("[WebRTCConnector] ❌ 无法创建转换格式")
					throw WebRTCError.failedToStartRecording(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建转换格式"]))
				}
				print("[WebRTCConnector] ✅ 转换目标格式创建成功:")
				print("  - 采样率: \(converterFormat.sampleRate) Hz")
				print("  - 声道数: \(converterFormat.channelCount)")
				
				// 创建格式转换器（在闭包内创建，避免捕获问题）
				guard let converter = AVAudioConverter(from: inputFormat, to: converterFormat) else {
					print("[WebRTCConnector] ❌ 无法创建音频转换器")
					print("  - 源格式: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
					print("  - 目标格式: \(converterFormat.sampleRate)Hz, \(converterFormat.channelCount)ch")
					throw WebRTCError.failedToStartRecording(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建音频转换器"]))
				}
				print("[WebRTCConnector] ✅ 本地音频转换器创建成功")
				
				// 创建远程音频播放节点（用于接收远程音频）
				let remotePlayerNode = AVAudioPlayerNode()
				engine.attach(remotePlayerNode)
				self.remotePlayerNode = remotePlayerNode
				print("[WebRTCConnector] ✅ 远程音频播放节点已创建并附加到引擎")
				
				// 创建最终混合器节点，用于混合本地和远程音频
				let finalMixerNode = AVAudioMixerNode()
				engine.attach(finalMixerNode)
				
				// 连接本地音频（inputNode）到最终混合器 - 使用硬件格式
				engine.connect(engine.inputNode, to: finalMixerNode, format: inputFormat)
				print("[WebRTCConnector] ✅ 本地音频已连接到最终混合器")
				
				// 获取远程音频格式（使用与本地音频相同的格式，稍后会在 connectRemoteAudioToEngine 中调整）
				// 先使用一个默认格式，实际格式将在连接远程音频时确定
				let remoteFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false) ?? inputFormat
				
				// 连接远程音频播放节点到最终混合器
				engine.connect(remotePlayerNode, to: finalMixerNode, format: remoteFormat)
				print("[WebRTCConnector] ✅ 远程音频播放节点已连接到最终混合器")
				
				// 获取 mainMixerNode 的输出格式（用于最终输出）
				let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
				print("[WebRTCConnector] 📊 输出节点格式:")
				print("  - 采样率: \(outputFormat.sampleRate) Hz")
				print("  - 声道数: \(outputFormat.channelCount)")
				
				// 将最终混合器连接到输出节点（用于播放）
				engine.connect(finalMixerNode, to: engine.outputNode, format: outputFormat)
				print("[WebRTCConnector] ✅ 最终混合器已连接到输出节点")
				
				// 注意：WebRTC 的远程音频轨道通过系统音频输出自动播放
				// 由于 LiveKitWebRTC 可能不直接提供音频数据流 API，远程音频可能不会进入我们的 AVAudioEngine
				// 我们已经在 finalMixerNode 上安装了 tap 来捕获混合后的音频
				// 如果远程音频没有进入引擎，混合音频将只包含本地音频
				// 这需要在 connectRemoteAudioToEngine() 中进一步处理
				
				// 创建混合音频转换器（从 outputFormat 转换到目标格式）
				guard let mixedConverter = AVAudioConverter(from: outputFormat, to: converterFormat) else {
					print("[WebRTCConnector] ❌ 无法创建混合音频转换器")
					print("  - 源格式: \(outputFormat.sampleRate)Hz, \(outputFormat.channelCount)ch")
					print("  - 目标格式: \(converterFormat.sampleRate)Hz, \(converterFormat.channelCount)ch")
					throw WebRTCError.failedToStartRecording(NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建混合音频转换器"]))
				}
				print("[WebRTCConnector] ✅ 混合音频转换器创建成功")
				
				// 从最终混合器节点安装 tap，捕获混合后的音频
				// 使用硬件格式捕获，然后在回调中转换为目标格式
				// 重置统计计数器
				self.localAudioCallbackCount = 0
				self.lastLocalCallbackTime = Date()
				finalMixerNode.installTap(onBus: 0, bufferSize: 4096, format: outputFormat) { [weak self, mixedConverter, converterFormat] buffer, time in
					guard let self = self, self.isRecording else {
						return
					}
					
					// 这是混合后的音频（包含本地和远程）
					self.localAudioCallbackCount += 1
					let now = Date()
					let timeSinceLastCallback: TimeInterval
					if let lastTime = self.lastLocalCallbackTime {
						timeSinceLastCallback = now.timeIntervalSince(lastTime)
					} else {
						timeSinceLastCallback = 0
					}
					self.lastLocalCallbackTime = now
					
					// 诊断日志：记录回调触发（前100次每次都记录，之后每100次打印一次）
					if self.localAudioCallbackCount <= 100 || self.localAudioCallbackCount % 100 == 0 {
						print("[WebRTCConnector] 🔍 [混合音频] Tap 回调触发 #\(self.localAudioCallbackCount) - 帧数: \(buffer.frameLength), 采样率: \(buffer.format.sampleRate)Hz, 距上次回调: \(String(format: "%.3f", timeSinceLastCallback))秒")
					}
					
					// 如果回调间隔过长（超过0.5秒），打印警告
					if timeSinceLastCallback > 0.5 && self.localAudioCallbackCount > 1 {
						print("[WebRTCConnector] ⚠️ [混合音频] Tap 回调间隔过长: \(String(format: "%.3f", timeSinceLastCallback))秒 (回调#\(self.localAudioCallbackCount))")
					}
					
					// 记录原始 buffer 信息
					let originalFrames = buffer.frameLength
					let originalSampleRate = buffer.format.sampleRate
					
					// 转换音频格式到目标格式（24000 Hz）
					guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converterFormat, frameCapacity: buffer.frameLength) else {
						print("[WebRTCConnector] ❌ 混合音频: 无法创建转换 buffer (容量: \(buffer.frameLength))")
						return
					}
					
					var error: NSError?
					let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
						outStatus.pointee = .haveData
						return buffer
					}
					
					mixedConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
					
					if error == nil {
						// 确保 frameLength 正确设置
						if convertedBuffer.frameLength == 0 {
							convertedBuffer.frameLength = convertedBuffer.frameCapacity
							print("[WebRTCConnector] ⚠️ 混合音频: frameLength 为 0，已设置为 frameCapacity (\(convertedBuffer.frameCapacity))")
						}
						
						// 分析音频数据（前10次或每100次）
						let shouldAnalyze = self.localAudioCallbackCount <= 10 || self.localAudioCallbackCount % 100 == 0
						if shouldAnalyze {
							let (maxVal, minVal, rms, isSilent) = self.analyzeAudioBuffer(convertedBuffer)
							print("[WebRTCConnector] 📊 [混合音频] 音频数据分析 #\(self.localAudioCallbackCount):")
							print("  - 最大值: \(String(format: "%.6f", maxVal))")
							print("  - 最小值: \(String(format: "%.6f", minVal))")
							print("  - RMS值: \(String(format: "%.6f", rms))")
							print("  - 是否静音: \(isSilent ? "是 ⚠️" : "否 ✅")")
							if isSilent {
								print("[WebRTCConnector] ⚠️ [混合音频] 检测到静音数据 - 回调#\(self.localAudioCallbackCount)")
							}
						}
						
						// 诊断日志：记录准备入队（前10次详细记录）
						if self.localAudioCallbackCount <= 10 {
							print("[WebRTCConnector] 🔍 [混合音频] 准备入队 - 转换后帧数: \(convertedBuffer.frameLength), 采样率: \(convertedBuffer.format.sampleRate)Hz")
						}
						
						// 将转换后的混合音频 buffer 入队（source 标记为"混合"）
						self.enqueueAudioPCMBuffer(convertedBuffer, source: "混合")
						
						// 诊断日志：记录入队成功（前10次详细记录）
						if self.localAudioCallbackCount <= 10 {
							print("[WebRTCConnector] ✅ [混合音频] 已入队 - 回调#\(self.localAudioCallbackCount)")
						}
					} else {
						print("[WebRTCConnector] ❌ 混合音频格式转换失败:")
						print("  - 错误: \(error?.localizedDescription ?? "未知错误")")
						print("  - 原始帧数: \(originalFrames), 采样率: \(originalSampleRate)Hz")
					}
				}
				print("[WebRTCConnector] ✅ 混合音频 tap 已安装 (bufferSize: 4096)")
					
				// 启动音频引擎
				try engine.start()
				self.audioEngine = engine
				self.isRecording = true
				
				print("[WebRTCConnector] ✅ 音频引擎已启动")
				print("[WebRTCConnector] ✅ 录制已开始，文件保存至: \(fileURL.path)")
				
				// 诊断：检查远程音频轨道状态
				if let remoteTrack = self.remoteAudioTrack {
					print("[WebRTCConnector] 🔍 [录制开始] 远程音频轨道状态:")
					print("  - 轨道ID: \(remoteTrack.trackId)")
					print("  - 是否启用: \(remoteTrack.isEnabled)")
					print("  - 状态: \(remoteTrack.readyState.rawValue)")
					print("  - 注意：远程音频应通过 mainMixerNode 的 tap 捕获")
					
					// 连接远程音频轨道到音频引擎
					self.connectRemoteAudioToEngine()
				} else {
					print("[WebRTCConnector] ⚠️ [录制开始] 远程音频轨道尚未获取")
				}
				
				// 诊断：检查音频引擎节点连接状态
				print("[WebRTCConnector] 🔍 [录制开始] 音频引擎节点状态:")
				print("  - 输入节点已连接: \(engine.inputNode.outputFormat(forBus: 0).sampleRate > 0)")
				print("  - mainMixerNode 已连接: \(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate > 0)")
				print("  - 输出节点已连接: \(engine.outputNode.inputFormat(forBus: 0).sampleRate > 0)")
				print("  - 已附加节点数: \(engine.attachedNodes.count)")
				
				// 诊断：检查 finalMixerNode 的输入连接
				if let finalMixerNode = engine.attachedNodes.first(where: { $0 is AVAudioMixerNode && $0 !== engine.mainMixerNode }) as? AVAudioMixerNode {
					let inputFormat = finalMixerNode.inputFormat(forBus: 0)
					print("[WebRTCConnector] 🔍 [录制开始] finalMixerNode 输入连接状态:")
					print("  - Bus 0 (本地音频) 采样率: \(inputFormat.sampleRate) Hz")
					if finalMixerNode.numberOfInputs > 1 {
						let remoteInputFormat = finalMixerNode.inputFormat(forBus: 1)
						print("  - Bus 1 (远程音频) 采样率: \(remoteInputFormat.sampleRate) Hz")
					} else {
						print("  - Bus 1 (远程音频): 未连接")
					}
				}
				
				// 启动定期诊断检查（每5秒打印一次统计信息）
				let timer = DispatchSource.makeTimerSource(queue: self.recordingQueue)
				timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
				timer.setEventHandler { [weak self] in
					guard let self = self, self.isRecording else {
						timer.cancel()
						return
					}
					
					let now = Date()
					let timeSinceLastLocal: TimeInterval
					let timeSinceLastRemote: TimeInterval
					
					if let lastLocal = self.lastLocalCallbackTime {
						timeSinceLastLocal = now.timeIntervalSince(lastLocal)
					} else {
						timeSinceLastLocal = -1
					}
					
					if let lastRemote = self.lastRemoteCallbackTime {
						timeSinceLastRemote = now.timeIntervalSince(lastRemote)
					} else {
						timeSinceLastRemote = -1
					}
					
					print("[WebRTCConnector] 📊 [定期诊断] Tap 回调统计:")
					print("  - 本地音频回调次数: \(self.localAudioCallbackCount), 距上次回调: \(timeSinceLastLocal >= 0 ? String(format: "%.3f", timeSinceLastLocal) : "从未")秒")
					print("  - 远程音频回调次数: \(self.remoteAudioCallbackCount), 距上次回调: \(timeSinceLastRemote >= 0 ? String(format: "%.3f", timeSinceLastRemote) : "从未")秒")
					print("  - 本地 createSampleBuffer 次数: \(self.createSampleBufferCountLocal)")
					print("  - 远程 createSampleBuffer 次数: \(self.createSampleBufferCountRemote)")
					print("  - 本地入队次数: \(self.enqueueCountLocal), 远程入队次数: \(self.enqueueCountRemote)")
					
					// 如果回调停止（超过2秒没有回调），打印警告
					if timeSinceLastLocal > 2.0 && self.localAudioCallbackCount > 0 {
						print("[WebRTCConnector] ⚠️ [定期诊断] 本地音频 tap 回调可能已停止（超过2秒无回调）")
					}
					if timeSinceLastRemote > 2.0 && self.remoteAudioCallbackCount > 0 {
						print("[WebRTCConnector] ⚠️ [定期诊断] 远程音频 tap 回调可能已停止（超过2秒无回调）")
					}
				}
				timer.resume()
				self.diagnosticTimer = timer
				
				print("========================================")
					
					continuation.resume()
					
				} catch {
					print("[WebRTCConnector] 开始录制失败: \(error)")
					continuation.resume(throwing: WebRTCError.failedToStartRecording(error))
				}
			}
		}
	}
	
	/// 停止录制
	func stopRecording() {
		guard isRecording else { return }
		
		recordingQueue.async { [weak self] in
			guard let self = self else { return }
			
			// 取消诊断定时器
			if let timer = self.diagnosticTimer {
				timer.cancel()
				self.diagnosticTimer = nil
			}
			
			// 停止音频引擎
			if let engine = self.audioEngine {
				engine.stop()
				// 移除所有 tap
				engine.mainMixerNode.removeTap(onBus: 0)
				if let mixerNode = engine.attachedNodes.first(where: { $0 is AVAudioMixerNode }) as? AVAudioMixerNode {
					mixerNode.removeTap(onBus: 0)
				}
			}
			self.audioEngine = nil
			
			// 清空音频缓冲区队列
			self.bufferQueueLock.lock()
			let remainingSamples = self.audioBufferQueue.count
			self.audioBufferQueue.removeAll()
			self.bufferQueueLock.unlock()
			
			if remainingSamples > 0 {
				print("[WebRTCConnector] ⚠️ 停止录制时，队列中还有 \(remainingSamples) 个样本未写入")
			}
			
			// 等待队列处理完成（最多等待2秒）
			if let writeQueue = self.audioWriteQueue {
				let semaphore = DispatchSemaphore(value: 0)
				writeQueue.async {
					// 处理剩余的队列项
					self.processAudioWriteQueue()
					semaphore.signal()
				}
				_ = semaphore.wait(timeout: .now() + 2.0)
			}
			
			// 关闭文件句柄
			if let fileHandle = self.fileHandle {
				fileHandle.synchronizeFile()
				fileHandle.closeFile()
				self.fileHandle = nil
			}
			
			// 更新 WAV 文件头
			if let fileURL = self.recordingURL {
				let finalDataSize = self.wavDataSize
				do {
					try self.updateWAVHeader(fileURL: fileURL, dataSize: finalDataSize)
				} catch {
					print("[WebRTCConnector] ⚠️ 更新 WAV 文件头失败: \(error.localizedDescription)")
				}
				
				// 获取文件信息
				let filePath = fileURL.path
				let fileName = fileURL.lastPathComponent
				
				// 获取文件大小
				var fileSize: Int64 = 0
				if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
				   let size = attributes[.size] as? Int64 {
					fileSize = size
				}
				
				// 格式化文件大小
				let fileSizeMB = Double(fileSize) / (1024 * 1024)
				let fileSizeKB = Double(fileSize) / 1024
				let fileSizeString = fileSizeMB >= 1.0 
					? String(format: "%.2f MB", fileSizeMB)
					: String(format: "%.2f KB", fileSizeKB)
				
				// 获取文件创建时间
				let creationDate = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.creationDate] as? Date
				let dateFormatter = DateFormatter()
				dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
				let dateString = creationDate != nil ? dateFormatter.string(from: creationDate!) : "未知"
				
				// 打印详细的文件信息
				print("========================================")
				print("[WebRTCConnector] 录制完成")
				print("========================================")
				print("文件名: \(fileName)")
				print("文件路径: \(filePath)")
				print("文件大小: \(fileSizeString) (\(fileSize) 字节)")
				print("创建时间: \(dateString)")
				print("========================================")
			} else {
				print("[WebRTCConnector] 录制完成，但文件URL为空")
			}
			
			self.audioWriteQueue = nil
			self.isRecording = false
			
			// 重置时间戳和统计信息
			self.timestampLock.lock()
			let finalFrames = self.totalFramesWritten
			let finalDataSize = self.wavDataSize
			let skippedFrames = self.skippedFramesCount
			let skippedLocal = self.skippedFramesCountLocal
			let skippedRemote = self.skippedFramesCountRemote
			self.recordingStartTime = .zero
			self.lastPresentationTime = .zero
			self.totalFramesWritten = 0
			self.wavDataSize = 0
			self.skippedFramesCount = 0
			self.skippedFramesCountLocal = 0
			self.skippedFramesCountRemote = 0
			self.timestampLock.unlock()
			
			// 打印录制统计信息
			if finalFrames > 0 {
				let durationSeconds = Double(finalFrames) / 24000.0 // 24000 Hz 采样率
				print("[WebRTCConnector] 📊 录制统计:")
				print("  - 总写入帧数: \(finalFrames)")
				print("  - 总数据大小: \(finalDataSize) 字节")
				print("  - 总时长: \(String(format: "%.2f", durationSeconds)) 秒")
				if skippedFrames > 0 {
					print("  - 跳过的帧数: \(skippedFrames) (本地: \(skippedLocal), 远程: \(skippedRemote))")
					let skipPercentage = Double(skippedFrames) / Double(finalFrames + skippedFrames) * 100.0
					print("  - 跳过比例: \(String(format: "%.2f", skipPercentage))%")
				} else {
					print("  - 跳过的帧数: 0 (所有帧都已成功写入)")
				}
			}
		}
	}
	
	/// 连接远程音频轨道到音频引擎
	private func connectRemoteAudioToEngine() {
		// 诊断日志：记录连接尝试
		print("[WebRTCConnector] 🔍 [远程音频连接] 尝试连接远程音频轨道到引擎")
		
		guard let remoteTrack = remoteAudioTrack else {
			print("[WebRTCConnector] ⚠️ [远程音频连接] 远程音频轨道不存在")
			return
		}
		
		print("[WebRTCConnector] 🔍 [远程音频连接] 远程音频轨道信息:")
		print("  - 轨道ID: \(remoteTrack.trackId)")
		print("  - 是否启用: \(remoteTrack.isEnabled)")
		print("  - 状态: \(remoteTrack.readyState.rawValue)")
		
		guard let engine = audioEngine, let playerNode = remotePlayerNode else {
			print("[WebRTCConnector] ⚠️ [远程音频连接] 音频引擎或远程播放节点不存在")
			return
		}
		
		print("[WebRTCConnector] 🔍 [远程音频连接] 音频引擎状态:")
		print("  - 是否运行: \(engine.isRunning)")
		print("  - 已附加节点数: \(engine.attachedNodes.count)")
		
		// 检查远程音频轨道是否启用
		if !remoteTrack.isEnabled {
			print("[WebRTCConnector] ⚠️ [远程音频连接] 远程音频轨道未启用，尝试启用")
			remoteTrack.isEnabled = true
		}
		
		// 注意：WebRTC 的远程音频轨道通过系统音频输出自动播放
		// 由于 LiveKitWebRTC 可能不直接提供音频数据流 API，我们需要：
		// 1. 确保远程音频轨道已启用
		// 2. 远程音频会通过系统音频输出播放
		// 3. 我们的 finalMixerNode 已经连接了本地音频和远程播放节点
		// 4. 如果远程音频通过系统播放，我们需要通过其他方式捕获（如 AVAudioSession 路由）
		
		// 目前，远程音频播放节点已连接到 finalMixerNode
		// 但我们需要找到方法将远程音频数据输入到 playerNode
		// 由于 WebRTC 音频轨道可能不直接提供数据流，我们可能需要：
		// - 使用 AVAudioSession 的路由来捕获系统音频输出
		// - 或者等待 WebRTC 提供音频数据回调
		
		print("[WebRTCConnector] ⚠️ [远程音频连接] 注意：WebRTC 远程音频轨道可能不直接提供音频数据流")
		print("[WebRTCConnector] 🔍 [远程音频连接] 远程音频播放节点已连接到 finalMixerNode")
		print("[WebRTCConnector] 🔍 [远程音频连接] 需要找到方法将远程音频数据输入到 playerNode")
		
		// 启动远程音频播放节点（即使没有数据，也要启动以保持连接）
		if !playerNode.isPlaying {
			playerNode.play()
			print("[WebRTCConnector] ✅ [远程音频连接] 远程音频播放节点已启动")
		}
		
		// 诊断：检查 finalMixerNode 的输入连接状态
		if let finalMixerNode = engine.attachedNodes.first(where: { $0 is AVAudioMixerNode && $0 !== engine.mainMixerNode }) as? AVAudioMixerNode {
			print("[WebRTCConnector] 🔍 [远程音频连接] finalMixerNode 输入连接:")
			print("  - 输入数量: \(finalMixerNode.numberOfInputs)")
			for bus in 0..<finalMixerNode.numberOfInputs {
				let inputFormat = finalMixerNode.inputFormat(forBus: bus)
				print("  - Bus \(bus) 采样率: \(inputFormat.sampleRate) Hz, 声道数: \(inputFormat.channelCount)")
			}
		}
		
		// 重要提示：由于 WebRTC 的远程音频轨道通过系统音频输出自动播放，
		// 可能不直接进入我们的 AVAudioEngine。如果远程音频没有进入引擎，
		// 混合音频将只包含本地音频。这需要进一步调查 WebRTC 音频路由机制。
		print("[WebRTCConnector] ⚠️ [远程音频连接] 重要提示：")
		print("  - WebRTC 远程音频可能通过系统音频输出播放，不经过我们的 AVAudioEngine")
		print("  - 如果远程音频没有进入引擎，混合音频将只包含本地音频")
		print("  - 需要进一步调查 WebRTC 音频路由机制或使用其他捕获方法")
		
		print("[WebRTCConnector] ✅ [远程音频连接] 远程音频轨道连接检查完成")
	}
	
	/// 写入 WAV 文件头（44 字节）
	/// - Parameters:
	///   - fileURL: 文件 URL
	///   - sampleRate: 采样率（默认 24000）
	///   - channels: 声道数（默认 1）
	///   - bitsPerSample: 位深度（默认 16）
	///   - dataSize: 数据大小（初始为 0，停止录制时更新）
	private func writeWAVHeader(to fileURL: URL, sampleRate: UInt32 = 24000, channels: UInt16 = 1, bitsPerSample: UInt16 = 16, dataSize: UInt32 = 0) throws {
		var header = Data(capacity: 44)
		
		// RIFF chunk descriptor (12 bytes)
		header.append("RIFF".data(using: .ascii)!)
		let fileSize = UInt32(36 + dataSize) // 36 = 44 - 8 (chunk size + format + data chunk header)
		header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
		header.append("WAVE".data(using: .ascii)!)
		
		// fmt sub-chunk (24 bytes)
		header.append("fmt ".data(using: .ascii)!)
		let fmtSize: UInt32 = 16 // PCM format
		header.append(contentsOf: withUnsafeBytes(of: fmtSize.littleEndian) { Data($0) })
		let audioFormat: UInt16 = 1 // PCM
		header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
		header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Data($0) })
		header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
		let byteRate = UInt32(sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8)
		header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
		let blockAlign = UInt16(channels * bitsPerSample / 8)
		header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
		header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
		
		// data sub-chunk header (8 bytes)
		header.append("data".data(using: .ascii)!)
		header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
		
		// 写入文件头
		try header.write(to: fileURL)
		print("[WebRTCConnector] ✅ WAV 文件头已写入 (44 字节)")
		print("  - 采样率: \(sampleRate) Hz")
		print("  - 声道数: \(channels)")
		print("  - 位深度: \(bitsPerSample) 位")
		print("  - 数据大小: \(dataSize) 字节")
	}
	
	/// 更新 WAV 文件头中的数据大小字段
	/// - Parameters:
	///   - fileURL: 文件 URL
	///   - dataSize: 实际写入的 PCM 数据大小
	private func updateWAVHeader(fileURL: URL, dataSize: UInt32) throws {
		guard let fileHandle = try? FileHandle(forUpdating: fileURL) else {
			throw NSError(domain: "WebRTC", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法打开文件以更新文件头"])
		}
		defer { fileHandle.closeFile() }
		
		// 更新 RIFF chunk size (偏移 4)
		fileHandle.seek(toFileOffset: 4)
		let fileSize = UInt32(36 + dataSize)
		var fileSizeBytes = withUnsafeBytes(of: fileSize.littleEndian) { Data($0) }
		fileHandle.write(fileSizeBytes)
		
		// 更新 data chunk size (偏移 40)
		fileHandle.seek(toFileOffset: 40)
		var dataSizeBytes = withUnsafeBytes(of: dataSize.littleEndian) { Data($0) }
		fileHandle.write(dataSizeBytes)
		
		print("[WebRTCConnector] ✅ WAV 文件头已更新")
		print("  - 文件大小: \(fileSize + 8) 字节")
		print("  - 数据大小: \(dataSize) 字节")
	}
	
	/// 分析音频数据的统计信息
	/// - Parameter buffer: AVAudioPCMBuffer
	/// - Returns: (最大值, 最小值, RMS值, 是否静音)
	private func analyzeAudioBuffer(_ buffer: AVAudioPCMBuffer) -> (max: Float, min: Float, rms: Float, isSilent: Bool) {
		guard let floatChannelData = buffer.floatChannelData else {
			return (0, 0, 0, true)
		}
		
		let frameLength = Int(buffer.frameLength)
		let channelCount = Int(buffer.format.channelCount)
		
		var maxValue: Float = -Float.greatestFiniteMagnitude
		var minValue: Float = Float.greatestFiniteMagnitude
		var sumSquares: Float = 0.0
		var totalSamples = 0
		
		for channel in 0..<channelCount {
			let channelData = floatChannelData[channel]
			for frame in 0..<frameLength {
				let value = channelData[frame]
				maxValue = max(maxValue, value)
				minValue = min(minValue, value)
				sumSquares += value * value
				totalSamples += 1
			}
		}
		
		let rms = totalSamples > 0 ? sqrt(sumSquares / Float(totalSamples)) : 0.0
		// 如果 RMS 值小于 0.001，认为是静音
		let isSilent = rms < 0.001
		
		return (maxValue, minValue, rms, isSilent)
	}
	
	/// 将 Float32 PCM 转换为 Int16 PCM
	/// - Parameter floatBuffer: Float32 PCM 缓冲区
	/// - Returns: Int16 PCM 数据
	private func convertFloat32ToInt16(floatBuffer: AVAudioPCMBuffer) -> Data? {
		guard let floatChannelData = floatBuffer.floatChannelData else {
			return nil
		}
		
		let frameLength = Int(floatBuffer.frameLength)
		let channelCount = Int(floatBuffer.format.channelCount)
		// 对于单声道，只需要 frameLength * 2 字节；对于多声道，需要 frameLength * channelCount * 2 字节
		var int16Data = Data(capacity: frameLength * channelCount * 2) // 2 bytes per Int16
		
		// 处理每个通道的数据
		for channel in 0..<channelCount {
			let channelData = floatChannelData[channel]
			for frame in 0..<frameLength {
				let floatValue = channelData[frame]
				// 限制范围并转换为 Int16（-1.0 到 1.0 映射到 -32768 到 32767）
				let clampedValue = max(-1.0, min(1.0, floatValue))
				let int16Value = Int16(clampedValue * 32767.0)
				var int16Bytes = withUnsafeBytes(of: int16Value.littleEndian) { Data($0) }
				int16Data.append(int16Bytes)
			}
		}
		
		return int16Data
	}

	/// 获取下一个时间戳（线程安全，统一管理）
	private func getNextPresentationTimeStamp(duration: CMTime) -> CMTime {
		timestampLock.lock()
		defer { timestampLock.unlock() }
		
		let previousLastTime = lastPresentationTime
		let durationSeconds = CMTimeGetSeconds(duration)
		
		let presentationTimeStamp: CMTime
		if lastPresentationTime == .zero {
			// 第一个样本，从零开始
			presentationTimeStamp = .zero
			// 更新最后的时间戳为当前时间戳加上持续时间
			lastPresentationTime = presentationTimeStamp + duration
			print("[WebRTCConnector] ⏱️ 时间戳管理器: 第一个样本，PTS=0, 时长=\(String(format: "%.4f", durationSeconds))秒")
		} else {
			// 基于上一个时间戳（已经是上一个样本的结束时间）
			presentationTimeStamp = lastPresentationTime
			let previousTimeSeconds = CMTimeGetSeconds(previousLastTime)
			// 更新最后的时间戳为当前时间戳加上持续时间
			lastPresentationTime = presentationTimeStamp + duration
			let newTimeSeconds = CMTimeGetSeconds(lastPresentationTime)
			

			timestampCallCount += 1
			if timestampCallCount % 100 == 0 {
				let timeGap = newTimeSeconds - previousTimeSeconds
				print("[WebRTCConnector] 🔍 [时间戳] 获取时间戳 #\(timestampCallCount) - PTS: \(String(format: "%.4f", previousTimeSeconds))秒 -> \(String(format: "%.4f", newTimeSeconds))秒, 增量: \(String(format: "%.4f", timeGap))秒, 样本时长: \(String(format: "%.4f", durationSeconds))秒")
				
				// 检查时间戳是否有间隙（增量应该等于样本时长）
				let gapDifference = abs(timeGap - durationSeconds)
				if gapDifference > 0.001 { // 允许1ms的误差
					print("[WebRTCConnector] ⚠️ [时间戳] 时间戳间隙异常 - 期望增量: \(String(format: "%.4f", durationSeconds))秒, 实际增量: \(String(format: "%.4f", timeGap))秒, 差异: \(String(format: "%.4f", gapDifference))秒")
				}
			}
		}
		
		totalFramesWritten += Int64(duration.value)
		
		// 每100个样本打印一次统计信息（避免日志过多）
		if totalFramesWritten % 100 == 0 {
			let currentTime = CMTimeGetSeconds(lastPresentationTime)
			print("[WebRTCConnector] 📊 时间戳统计: 总帧数=\(totalFramesWritten), 当前时间=\(String(format: "%.2f", currentTime))秒")
		}
		
		return presentationTimeStamp
	}
	
	/// 将 AVAudioPCMBuffer 转换为 CMSampleBuffer
	private func createSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, time: AVAudioTime, source: String = "未知") -> CMSampleBuffer? {
		// 更新调用计数
		if source == "本地" {
			createSampleBufferCountLocal += 1
		} else if source == "远程" {
			createSampleBufferCountRemote += 1
		}
		
		let callCount = source == "本地" ? createSampleBufferCountLocal : createSampleBufferCountRemote
		
		// 诊断日志：记录方法调用（前100次每次都记录，之后每100次记录一次）
		if callCount <= 100 || callCount % 100 == 0 {
			print("[WebRTCConnector] 🔍 [createSampleBuffer] [\(source)] 调用 #\(callCount) - 开始创建 sampleBuffer")
		}
		
		var sampleBuffer: CMSampleBuffer?
		var formatDescription: CMFormatDescription?
		
		let sampleRate = pcmBuffer.format.sampleRate
		let timescale = Int32(sampleRate)
		let frameLength = pcmBuffer.frameLength
		let channelCount = pcmBuffer.format.channelCount
		
		// 诊断日志：记录输入参数（前10次详细记录）
		if callCount <= 10 {
			print("[WebRTCConnector] 🔍 [createSampleBuffer] [\(source)] 输入参数 - 采样率: \(sampleRate)Hz, 帧数: \(frameLength), 声道数: \(channelCount)")
		}
		
		// 验证 buffer 参数
		if frameLength == 0 {
			print("[WebRTCConnector] ❌ [\(source)] createSampleBuffer: frameLength 为 0")
			return nil
		}
		
		if sampleRate <= 0 {
			print("[WebRTCConnector] ❌ [\(source)] createSampleBuffer: 采样率无效: \(sampleRate)")
			return nil
		}
		
		// 创建格式描述
		var asbd = pcmBuffer.format.streamDescription.pointee
		
		// 只在第一次或出错时打印详细信息（避免日志过多）
        var firstCallMap: [String: Bool] = [:]
		if firstCallMap[source] != true {
			print("[WebRTCConnector] 📊 [\(source)] 创建格式描述:")
			print("  - 采样率: \(sampleRate) Hz")
			print("  - 帧数: \(frameLength)")
			print("  - 声道数: \(channelCount)")
			print("  - 格式ID: \(asbd.mFormatID)")
			print("  - 每帧字节数: \(asbd.mBytesPerFrame)")
			print("  - 每包帧数: \(asbd.mFramesPerPacket)")
			firstCallMap[source] = true
		}
		
		let status = CMAudioFormatDescriptionCreate(
			allocator: kCFAllocatorDefault,
			asbd: &asbd,
			layoutSize: 0,
			layout: nil,
			magicCookieSize: 0,
			magicCookie: nil,
			extensions: nil,
			formatDescriptionOut: &formatDescription
		)
		
		guard status == noErr, let formatDesc = formatDescription else {
			print("[WebRTCConnector] ❌ [\(source)] 创建格式描述失败: status=\(status), 采样率=\(sampleRate)Hz, 帧数=\(frameLength)")
			return nil
		}
		
		// 计算持续时间
		let duration = CMTime(value: Int64(frameLength), timescale: timescale)
		
		// 使用统一的时间戳管理器获取时间戳（线程安全）
		let presentationTimeStamp = getNextPresentationTimeStamp(duration: duration)
		
		var timingInfo = CMSampleTimingInfo(
			duration: duration,
			presentationTimeStamp: presentationTimeStamp,
			decodeTimeStamp: .invalid
		)
		
		let data = pcmBuffer.audioBufferList.pointee.mBuffers.mData
		let dataSize = pcmBuffer.audioBufferList.pointee.mBuffers.mDataByteSize
		
		guard let dataPointer = data else {
			print("[WebRTCConnector] ❌ [\(source)] 数据指针为 nil, 数据大小=\(dataSize)字节")
			return nil
		}
		
		var dataBlock: CMBlockBuffer?
		// 使用 CMBlockBufferCreateWithMemoryBlock 的完整版本
		let blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault,
			memoryBlock: nil,
			blockLength: Int(dataSize),
			blockAllocator: nil,
			customBlockSource: nil,
			offsetToData: 0,
			dataLength: Int(dataSize),
			flags: 0,
			blockBufferOut: &dataBlock
		)
		
		guard blockBufferStatus == noErr, let blockBuffer = dataBlock else {
			print("[WebRTCConnector] ❌ [\(source)] 创建 CMBlockBuffer 失败: status=\(blockBufferStatus), 数据大小=\(dataSize)字节")
			return nil
		}
		
		// 复制数据到 block buffer
		let replaceStatus = CMBlockBufferReplaceDataBytes(
			with: dataPointer,
			blockBuffer: blockBuffer,
			offsetIntoDestination: 0,
			dataLength: Int(dataSize)
		)
		
		guard replaceStatus == noErr else {
			print("[WebRTCConnector] ❌ [\(source)] 复制数据到 CMBlockBuffer 失败: status=\(replaceStatus), 数据大小=\(dataSize)字节")
			return nil
		}
		
		let sampleBufferStatus = CMSampleBufferCreate(
			allocator: kCFAllocatorDefault,
			dataBuffer: blockBuffer,
			dataReady: true,
			makeDataReadyCallback: nil,
            refcon: nil,
			formatDescription: formatDesc,
            sampleCount: CMItemCount(frameLength),
			sampleTimingEntryCount: 1,
			sampleTimingArray: &timingInfo,
			sampleSizeEntryCount: 0,
			sampleSizeArray: nil,
			sampleBufferOut: &sampleBuffer
		)
		
		guard sampleBufferStatus == noErr else {
			print("[WebRTCConnector] ❌ [\(source)] 创建 CMSampleBuffer 失败: status=\(sampleBufferStatus), 帧数=\(frameLength), 采样率=\(sampleRate)Hz")
			return nil
		}
		
		// 诊断日志：记录成功创建（前100次每次都记录，之后每100次记录一次）
		if callCount <= 100 || callCount % 100 == 0 {
			let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer!)
			let duration = CMSampleBufferGetDuration(sampleBuffer!)
			print("[WebRTCConnector] ✅ [createSampleBuffer] [\(source)] 成功创建 #\(callCount) - PTS: \(CMTimeGetSeconds(pts))秒, 时长: \(CMTimeGetSeconds(duration))秒, 帧数: \(frameLength)")
		}
		
		return sampleBuffer
	}
	
	/// 将音频 PCM 缓冲区放入写入队列
	private func enqueueAudioPCMBuffer(_ pcmBuffer: AVAudioPCMBuffer, source: String) {
		bufferQueueLock.lock()
		defer { bufferQueueLock.unlock() }
		
		let queueSizeBefore = audioBufferQueue.count
		// 创建 buffer 的副本以避免内存问题
		guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: pcmBuffer.format, frameCapacity: pcmBuffer.frameCapacity) else {
			print("[WebRTCConnector] ❌ [\(source)] 无法创建 buffer 副本")
			return
		}
		bufferCopy.frameLength = pcmBuffer.frameLength
		if let srcChannelData = pcmBuffer.floatChannelData, let dstChannelData = bufferCopy.floatChannelData {
			for channel in 0..<Int(pcmBuffer.format.channelCount) {
				memcpy(dstChannelData[channel], srcChannelData[channel], Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size)
			}
		}
		
		audioBufferQueue.append((pcmBuffer: bufferCopy, source: source))
		let queueSizeAfter = audioBufferQueue.count
		
		// 更新入队计数
		if source == "本地" {
			enqueueCountLocal += 1
		} else if source == "远程" {
			enqueueCountRemote += 1
		}
		
		let currentCount = source == "本地" ? enqueueCountLocal : enqueueCountRemote
		
		// 诊断日志：记录入队操作（前10次强制记录，之后每50次记录一次）
		let shouldLog = currentCount <= 10 || currentCount % 50 == 0
		if shouldLog {
			let frameCount = Int(pcmBuffer.frameLength)
			let sampleRate = pcmBuffer.format.sampleRate
			let duration = Double(frameCount) / sampleRate
			print("[WebRTCConnector] 🔍 [队列入队] [\(source)] 样本 #\(currentCount) - 队列大小: \(queueSizeBefore) -> \(queueSizeAfter), 帧数: \(frameCount), 时长: \(String(format: "%.4f", duration))秒")
		}
		
		// 如果队列过大，打印警告（超过100个样本，约4秒的音频）
		if queueSizeAfter > 100 {
			print("[WebRTCConnector] ⚠️ 音频队列积压: \(queueSizeAfter) 个样本待写入 (来源: \(source))")
		}
		
		// 触发队列处理（如果队列处理未在进行中）
		if !isProcessingWriteQueue, let writeQueue = audioWriteQueue {
			isProcessingWriteQueue = true
			writeQueue.async { [weak self] in
				self?.processAudioWriteQueue()
				self?.isProcessingWriteQueue = false
			}
		}
	}
	
	/// 处理音频写入队列（将 Float32 PCM 转换为 Int16 并写入文件）
	private func processAudioWriteQueue() {
		guard let fileHandle = fileHandle, isRecording else {
			return
		}
		
		// 诊断日志：记录处理开始时的状态
		bufferQueueLock.lock()
		let initialQueueSize = audioBufferQueue.count
		bufferQueueLock.unlock()
		
		// 每处理50次打印一次状态（避免日志过多）
		processQueueCount += 1
		// 前10次或每5000次记录一次
		if processQueueCount <= 10 || processQueueCount % timestampCallFlag == 0 {
			print("[WebRTCConnector] 🔍 [队列处理] 开始处理 #\(processQueueCount) - 队列大小: \(initialQueueSize)")
		}
		
		var processedInThisCall = 0
		// 持续处理队列直到为空
		while true {
			// 从队列中取出一个样本
			bufferQueueLock.lock()
			guard !audioBufferQueue.isEmpty else {
				bufferQueueLock.unlock()
				// 诊断日志：记录队列为空（前10次或每5000次记录一次）
				if processQueueCount <= 10 || processQueueCount % timestampCallFlag == 0 {
					print("[WebRTCConnector] 🔍 [队列处理] 队列为空，退出处理循环 - 处理#\(processQueueCount), 本次已处理: \(processedInThisCall) 个样本")
				}
				break
			}
			
			let queueSizeBeforeDequeue = audioBufferQueue.count
			let item = audioBufferQueue.removeFirst()
			let queueSizeAfterDequeue = audioBufferQueue.count
			bufferQueueLock.unlock()
			
			processedInThisCall += 1
			
			// 获取 buffer 信息用于日志
			let frameCount = Int(item.pcmBuffer.frameLength)
			let sampleRate = item.pcmBuffer.format.sampleRate
			let duration = Double(frameCount) / sampleRate
			
			// 诊断日志：记录出队操作（前10次强制记录，之后每50次记录一次）
			let shouldLogDequeue = processedInThisCall <= 10 || processedInThisCall % 50 == 0 || processQueueCount <= 10
			if shouldLogDequeue {
				print("[WebRTCConnector] 🔍 [队列出队] [\(item.source)] 样本 #\(processedInThisCall) (处理#\(processQueueCount)) - 队列大小: \(queueSizeBeforeDequeue) -> \(queueSizeAfterDequeue), 帧数: \(frameCount), 时长: \(String(format: "%.4f", duration))秒")
			}
			
			// 将 Float32 PCM 转换为 Int16 PCM
			guard let int16Data = convertFloat32ToInt16(floatBuffer: item.pcmBuffer) else {
				print("[WebRTCConnector] ❌ [\(item.source)] 转换 Float32 到 Int16 失败")
				continue
			}
			
			// 写入文件
			fileHandle.write(int16Data)
			
			// 更新数据大小计数器（需要线程安全，因为可能在多个线程中调用）
			let dataSize = UInt32(int16Data.count)
			// 使用原子操作或锁来更新 wavDataSize
			// 由于 processAudioWriteQueue 在 audioWriteQueue 串行队列中执行，这里不需要额外的锁
			wavDataSize += dataSize
			
			// 更新总帧数（用于统计）
			totalFramesWritten += Int64(frameCount)
			
			// 诊断日志：记录写入成功（前10次强制记录，之后每50次记录一次）
			let shouldLogAppend = processedInThisCall <= 10 || processedInThisCall % 50 == 0 || processQueueCount <= 10
			if shouldLogAppend {
				print("[WebRTCConnector] ✅ [写入成功] [\(item.source)] 样本已写入 - 处理#\(processQueueCount), 本次处理#\(processedInThisCall), 帧数: \(frameCount), 数据大小: \(dataSize) 字节")
			}
		}
		
		// 诊断日志：记录本次处理完成（前10次或每5000次记录一次）
		if processQueueCount <= 10 || processQueueCount % timestampCallFlag == 0 {
			bufferQueueLock.lock()
			let finalQueueSize = audioBufferQueue.count
			bufferQueueLock.unlock()
			print("[WebRTCConnector] 🔍 [队列处理] 完成处理 #\(processQueueCount) - 本次处理: \(processedInThisCall) 个样本, 剩余队列: \(finalQueueSize)")
		}
	}
}

extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
    
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams mediaStreams: [LKRTCMediaStream]) {
		// 诊断日志：记录远程音频轨道获取尝试
		print("[WebRTCConnector] 🔍 [远程音频轨道] 开始获取远程音频轨道")
		print("  - RTP Receiver track 类型: \(type(of: rtpReceiver.track))")
		print("  - 媒体流数量: \(mediaStreams.count)")
		
		// 新版本 API：从 RTP Receiver 直接获取音频轨道（推荐方式）
		if let audioTrack = rtpReceiver.track as? LKRTCAudioTrack {
			remoteAudioTrack = audioTrack
			print("[WebRTCConnector] ✅ [远程音频轨道] 从 RTP Receiver 获取远程音频轨道成功")
			print("  - 轨道ID: \(audioTrack.trackId)")
			print("  - 是否启用: \(audioTrack.isEnabled)")
			print("  - 状态: \(audioTrack.readyState.rawValue)")
			print("  - 是否正在录制: \(isRecording)")
			
			// 如果正在录制，连接远程音频轨道
			if isRecording {
				print("[WebRTCConnector] 🔍 [远程音频轨道] 正在录制，尝试连接远程音频轨道")
				connectRemoteAudioToEngine()
			} else {
				print("[WebRTCConnector] 🔍 [远程音频轨道] 未在录制，暂不连接")
			}
			return
		}
		
		// 诊断日志：如果未找到远程音频轨道
		if remoteAudioTrack == nil {
			print("[WebRTCConnector] ⚠️ [远程音频轨道] 未找到远程音频轨道")
		}
	}
	
	// 保留旧版本 API 作为兼容（如果新版本 API 未被调用时使用）
	public func peerConnection(_: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
		// 提取远程音频轨道（AI回复）
        print("[WebRTCConnector] 从旧版本 API 获取远程音频轨道")
//		let audioTracks = stream.audioTracks
//		if !audioTracks.isEmpty {
//			remoteAudioTrack = audioTracks.first
//			print("[WebRTCConnector] 从旧版本 API 获取远程音频轨道")
//			// 如果正在录制，连接远程音频轨道
//			if isRecording {
//				connectRemoteAudioToEngine()
//			}
//		}
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
				case .open: 
					status = .connected
					// 连接成功后自动开始录制
					Task {
						try? await startRecording()
					}
				case .closing, .closed: 
					status = .disconnected
				default: break
			}
		}
	}
}



