import AVFoundation

/// Decodes any audio file iOS can read (m4a/AAC, mp3, flac, ...) to a 16 kHz
/// mono 16-bit WAV, the format Sarvam's instant endpoint handles best.
enum AudioConverter {
  struct Failure: Error { let message: String }

  static func toWav16kMono(src: String, dest: String) throws {
    let input = try AVAudioFile(forReading: URL(fileURLWithPath: src))
    guard let outFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: input.processingFormat, to: outFormat)
    else { throw Failure(message: "Unsupported audio format") }

    try? FileManager.default.removeItem(atPath: dest)
    let output = try AVAudioFile(
      forWriting: URL(fileURLWithPath: dest), settings: outFormat.settings,
      commonFormat: .pcmFormatInt16, interleaved: true)

    let inFrames: AVAudioFrameCount = 8192
    guard
      let inBuf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: inFrames),
      let outBuf = AVAudioPCMBuffer(
        pcmFormat: outFormat,
        frameCapacity: AVAudioFrameCount(Double(inFrames) * 16000 / input.processingFormat.sampleRate) + 1024)
    else { throw Failure(message: "Could not allocate audio buffers") }

    while true {
      var error: NSError?
      let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
        do { try input.read(into: inBuf, frameCount: inFrames) } catch {
          inputStatus.pointee = .endOfStream
          return nil
        }
        if inBuf.frameLength == 0 {
          inputStatus.pointee = .endOfStream
          return nil
        }
        inputStatus.pointee = .haveData
        return inBuf
      }
      if status == .error { throw error ?? Failure(message: "Audio conversion failed") }
      if outBuf.frameLength > 0 { try output.write(from: outBuf) }
      if status == .endOfStream { break }
    }
  }
}
