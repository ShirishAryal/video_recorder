import AVFoundation
import Flutter

public class VideoRecorderPlugin: NSObject, FlutterPlugin, HevcConverterHostApi {
  private let flutterApi: HevcConverterFlutterApi
  /// Only touched on the main thread (Pigeon calls in on the main actor).
  private var jobs: [Int64: HevcConversion] = [:]

  init(binaryMessenger: FlutterBinaryMessenger) {
    flutterApi = HevcConverterFlutterApi(binaryMessenger: binaryMessenger)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = VideoRecorderPlugin(binaryMessenger: registrar.messenger())
    HevcConverterHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: plugin)
    registrar.publish(plugin)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    for job in jobs.values { job.cancel() }
    HevcConverterHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
  }

  func convert(request: ConversionRequest) async throws -> ConversionReply {
    let id = request.id
    let job = HevcConversion(
      input: URL(fileURLWithPath: request.inputPath),
      output: URL(fileURLWithPath: request.outputPath),
      bitrate: Int(request.bitrate))
    jobs[id] = job
    defer { jobs[id] = nil }

    job.onProgress = { [weak self] value in
      Task { @MainActor in
        // Ignore failures: the Dart side may be gone (e.g. hot restart).
        try? await self?.flutterApi.onProgress(id: id, progress: value)
      }
    }

    let outcome = await withCheckedContinuation { continuation in
      job.start { continuation.resume(returning: $0) }
    }
    switch outcome {
    case .converted:
      return ConversionReply(status: .converted)
    case .skipped(let reason):
      return ConversionReply(status: .alreadyHevc, reason: reason)
    case .unsupported(let reason):
      return ConversionReply(status: .unsupported, reason: reason)
    case .cancelled:
      return ConversionReply(status: .cancelled)
    case .failed(let message):
      throw HevcError(code: "conversion_failed", message: message, details: nil)
    }
  }

  func cancel(id: Int64) throws {
    jobs[id]?.cancel()
  }
}

/// Uses AVAssetReader/Writer rather than an export preset, because presets
/// can't set the bitrate.
final class HevcConversion {
  enum Outcome {
    case converted
    case skipped(String)
    case unsupported(String)
    case cancelled
    case failed(String)
  }

  private let input: URL
  private let output: URL
  private let bitrate: Int

  /// Called with values from 0.0 to 1.0, on a background queue.
  var onProgress: ((Double) -> Void)?

  private let lock = NSLock()
  private var _cancelled = false
  private var reader: AVAssetReader?

  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _cancelled
  }

  init(input: URL, output: URL, bitrate: Int) {
    self.input = input
    self.output = output
    self.bitrate = bitrate
  }

  func start(completion: @escaping (Outcome) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      self.run(completion: completion)
    }
  }

  func cancel() {
    lock.lock()
    _cancelled = true
    let reader = self.reader
    lock.unlock()
    // Makes copyNextSampleBuffer() return nil so both tracks finish.
    reader?.cancelReading()
  }

  private func run(completion: @escaping (Outcome) -> Void) {
    let asset = AVURLAsset(url: input)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      completion(.failed("The file has no video track."))
      return
    }
    if let format = videoTrack.formatDescriptions.first,
      CMFormatDescriptionGetMediaSubType(format as! CMFormatDescription) == kCMVideoCodecType_HEVC
    {
      completion(.skipped("The video is already HEVC."))
      return
    }
    let audioTrack = asset.tracks(withMediaType: .audio).first

    try? FileManager.default.removeItem(at: output)

    let reader: AVAssetReader
    let writer: AVAssetWriter
    do {
      reader = try AVAssetReader(asset: asset)
      writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
      // Puts the index (moov) first, so players can stream the file.
      writer.shouldOptimizeForNetworkUse = true
    } catch {
      completion(.failed(error.localizedDescription))
      return
    }

    let size = videoTrack.naturalSize
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
    ]
    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
      completion(.unsupported("This device can't encode HEVC."))
      return
    }

    let videoOutput = AVAssetReaderTrackOutput(
      track: videoTrack,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ])
    videoOutput.alwaysCopiesSampleData = false
    reader.add(videoOutput)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    // Keeps portrait videos portrait.
    videoInput.transform = videoTrack.preferredTransform
    writer.add(videoInput)

    var audio: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
    if let audioTrack {
      // nil settings = pass the compressed audio through untouched.
      let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
      let hint = audioTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
      let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
      audioInput.expectsMediaDataInRealTime = false
      if reader.canAdd(audioOutput) && writer.canAdd(audioInput) {
        reader.add(audioOutput)
        writer.add(audioInput)
        audio = (audioOutput, audioInput)
      }
    }

    lock.lock()
    self.reader = reader
    let cancelledEarly = _cancelled
    lock.unlock()
    if cancelledEarly {
      completion(.cancelled)
      return
    }

    guard reader.startReading() else {
      completion(.failed(reader.error?.localizedDescription ?? "Could not read the video."))
      return
    }
    guard writer.startWriting() else {
      reader.cancelReading()
      completion(.failed(writer.error?.localizedDescription ?? "Could not write the video."))
      return
    }
    writer.startSession(atSourceTime: .zero)

    let duration = asset.duration.seconds
    let group = DispatchGroup()
    copy(from: videoOutput, to: videoInput, label: "video", group: group) { [weak self] time in
      guard let self, duration > 0 else { return }
      self.onProgress?(min(max(time.seconds / duration, 0), 1))
    }
    if let (audioOutput, audioInput) = audio {
      copy(from: audioOutput, to: audioInput, label: "audio", group: group, onSample: nil)
    }

    group.notify(queue: .global(qos: .userInitiated)) {
      if self.isCancelled {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: self.output)
        completion(.cancelled)
        return
      }
      if reader.status == .failed || writer.status == .failed {
        let message =
          reader.error?.localizedDescription ?? writer.error?.localizedDescription
          ?? "Conversion failed."
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: self.output)
        completion(.failed(message))
        return
      }
      writer.finishWriting {
        if writer.status == .completed {
          completion(.converted)
        } else {
          try? FileManager.default.removeItem(at: self.output)
          completion(.failed(writer.error?.localizedDescription ?? "Conversion failed."))
        }
      }
    }
  }

  private func copy(
    from output: AVAssetReaderTrackOutput,
    to input: AVAssetWriterInput,
    label: String,
    group: DispatchGroup,
    onSample: ((CMTime) -> Void)?
  ) {
    group.enter()
    var finished = false
    let queue = DispatchQueue(label: "video_recorder.hevc.\(label)")
    var lastReported = -1.0
    input.requestMediaDataWhenReady(on: queue) {
      guard !finished else { return }
      while input.isReadyForMoreMediaData {
        guard !self.isCancelled, let sample = output.copyNextSampleBuffer() else {
          finished = true
          input.markAsFinished()
          group.leave()
          return
        }
        if let onSample {
          let time = CMSampleBufferGetPresentationTimeStamp(sample)
          if time.seconds - lastReported >= 0.25 {
            lastReported = time.seconds
            onSample(time)
          }
        }
        if !input.append(sample) {
          finished = true
          input.markAsFinished()
          group.leave()
          return
        }
      }
    }
  }
}
