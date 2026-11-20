import AVFoundation
import ImageIO
import Network
import ReplayKit
import VideoToolbox

/// «Повтор экрана» from an iPhone: a ReplayKit broadcast upload extension. The app writes the
/// TV's address and a one-time token into the shared app group and starts the TV's receiver
/// (the launcher's MirrorActivity) over ADB; the owner starts the broadcast in the system sheet;
/// we stream H.264 + PCM in the same format as the Android sender (see MirrorActivity.java):
///   int "TVCM", int version, UTF token → the TV answers one byte (1 = accepted);
///   packets: byte type, int length, long pts µs, payload —
///   1 video config (int w, int h, SPS+PPS Annex B), 2 frame, 3 key frame,
///   4 sound config (int rate, int channels), 5 PCM 16-bit LE, 9 bye.
/// Extensions get ~50 MB: frames are scaled down before anything else.
final class SampleHandler: RPBroadcastSampleHandler {
  static let group = "group.com.tvcleanzer.app"
  private let magic: UInt32 = 0x5456_434D
  private let backlogLimit = 1_500_000

  private let q = DispatchQueue(label: "tvcleanzer.mirror")
  private let defaults = UserDefaults(suiteName: SampleHandler.group)
  private var conn: NWConnection?
  private var ready = false
  private var finished = false
  private var pending = 0
  private var skipping = false
  private var forceKey = false
  private var timer: DispatchSourceTimer?
  private var startedAt = Date().timeIntervalSince1970

  // video
  private var session: VTCompressionSession?
  private var encW = 0, encH = 0
  private var sentFormat: CMFormatDescription?
  private var lastPts = CMTime.invalid
  private var maxLong = 1280
  private var bitrate = 4_000_000
  private var transfer: AnyObject?   // VTPixelTransferSession (iOS 16+)
  private var rotation: AnyObject?   // VTPixelRotationSession (iOS 16+)
  private var scalePool: CVPixelBufferPool?
  private var rotatePool: CVPixelBufferPool?
  private var poolKey = ""

  // sound
  private var withSound = true
  private var soundRate = 0, soundChannels = 0

  // texts from the app, in the owner's language
  private func text(_ key: String, _ fallback: String) -> String {
    defaults?.string(forKey: key) ?? fallback
  }

  // MARK: - Broadcast lifecycle

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    startedAt = Date().timeIntervalSince1970
    guard let d = defaults, let host = d.string(forKey: "host"), let token = d.string(forKey: "token"),
          Date().timeIntervalSince1970 - d.double(forKey: "at") < 600 else {
      fail(text("errStart", "Start screen mirroring from the TVCleanzer app first."))
      return
    }
    let port = d.integer(forKey: "port") > 0 ? d.integer(forKey: "port") : 7300
    maxLong = d.bool(forKey: "hd") ? 1920 : 1280
    bitrate = d.bool(forKey: "hd") ? 8_000_000 : 4_000_000
    withSound = d.object(forKey: "audio") == nil ? true : d.bool(forKey: "audio")
    d.set(0.0, forKey: "stop")
    d.removeObject(forKey: "endReason")
    beat()
    connect(host: host, port: port, token: token, until: Date().addingTimeInterval(25))
  }

  override func broadcastFinished() {
    q.sync { shutdown(reason: nil) }
  }

  override func broadcastPaused() {}
  override func broadcastResumed() { q.async { self.forceKey = true } }

  /// Heartbeat for the app («running») and the app's «stop» request.
  private func beat() {
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now(), repeating: 1)
    t.setEventHandler { [weak self] in
      guard let self = self, let d = self.defaults else { return }
      d.set(Date().timeIntervalSince1970, forKey: "beat")
      if d.double(forKey: "stop") > self.startedAt {
        self.fail(self.text("msgStopped", "Screen mirroring stopped."), reason: nil)
      }
    }
    t.resume()
    timer = t
  }

  private func fail(_ message: String, reason: String? = "error") {
    if finished { return }
    if let r = reason { defaults?.set(r, forKey: "endReason") }
    shutdownLocked()
    finishBroadcastWithError(NSError(domain: "TVCleanzer", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: message]))
  }

  private func shutdown(reason: String?) {
    if let r = reason { defaults?.set(r, forKey: "endReason") }
    shutdownLocked()
  }

  private func shutdownLocked() {
    if finished { return }
    finished = true
    timer?.cancel()
    timer = nil
    defaults?.set(0.0, forKey: "beat")
    if ready { send(9, Data(), pts: 0) }
    ready = false
    let c = conn
    q.asyncAfter(deadline: .now() + 0.2) { c?.cancel() }
    if let s = session {
      VTCompressionSessionInvalidate(s)
      session = nil
    }
  }

  // MARK: - Connection

  private func connect(host: String, port: Int, token: String, until: Date) {
    q.async {
      if self.finished { return }
      guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
      let tcp = NWProtocolTCP.Options()
      tcp.noDelay = true
      tcp.connectionTimeout = 3
      let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters(tls: nil, tcp: tcp))
      var settled = false
      let retry = {
        if settled { return }
        settled = true
        c.cancel()
        if Date() < until && !self.finished {
          self.q.asyncAfter(deadline: .now() + 0.5) { self.connect(host: host, port: port, token: token, until: until) }
        } else {
          self.fail(self.text("errConnect", "The phone could not reach the TV. Check that they are on the same Wi-Fi."), reason: "connect")
        }
      }
      c.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if settled { return }
          settled = true
          self.greet(c, token: token, retry: {
            if Date() < until && !self.finished {
              self.q.asyncAfter(deadline: .now() + 0.5) { self.connect(host: host, port: port, token: token, until: until) }
            } else {
              self.fail(self.text("errConnect", "The phone could not reach the TV."), reason: "connect")
            }
          })
        case .failed, .waiting:
          retry()
        case .cancelled:
          if self.ready && self.conn === c && !self.finished {
            self.fail(self.text("msgClosed", "Screen mirroring ended."), reason: "closed")
          }
        default:
          break
        }
      }
      c.start(queue: self.q)
    }
  }

  private func greet(_ c: NWConnection, token: String, retry: @escaping () -> Void) {
    var hello = Data()
    hello.append(be32(magic))
    hello.append(be32(1))
    let t = Data(token.utf8)
    hello.append(UInt8(t.count >> 8))
    hello.append(UInt8(t.count & 0xFF))
    hello.append(t)
    c.send(content: hello, completion: .contentProcessed { err in
      if err != nil { c.cancel(); retry(); return }
      c.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, err in
        guard err == nil, let b = data?.first, b == 1 else {
          c.cancel()
          if data?.first == 0 {
            self.fail(self.text("errToken", "The TV did not accept the phone. Try again."), reason: "token")
          } else {
            retry()
          }
          return
        }
        self.conn = c
        self.ready = true
        self.forceKey = true
        self.watch(c)
      }
    })
  }

  /// The TV sends nothing back; the end of the stream means it closed the screen.
  private func watch(_ c: NWConnection) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, complete, err in
      if complete || err != nil || data == nil {
        if !self.finished { self.fail(self.text("msgClosed", "Screen mirroring ended."), reason: "closed") }
        return
      }
      self.watch(c)
    }
  }

  private func send(_ type: UInt8, _ payload: Data, pts: Int64) {
    guard let c = conn else { return }
    var d = Data(capacity: 13 + payload.count)
    d.append(type)
    d.append(be32(UInt32(payload.count)))
    d.append(be64(UInt64(bitPattern: pts)))
    d.append(payload)
    let n = d.count
    pending += n
    c.send(content: d, completion: .contentProcessed { [weak self] err in
      guard let self = self else { return }
      self.q.async { self.pending -= n }
      if err != nil && !self.finished {
        self.q.async { self.fail(self.text("msgClosed", "Screen mirroring ended."), reason: "closed") }
      }
    })
  }

  // MARK: - Samples

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    switch sampleBufferType {
    case .video:
      q.sync { self.video(sampleBuffer) }
    case .audioApp:
      if withSound { q.sync { self.audio(sampleBuffer) } }
    default:
      break
    }
  }

  // MARK: Video

  private func video(_ sb: CMSampleBuffer) {
    guard ready, !finished, let src = CMSampleBufferGetImageBuffer(sb) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    // 30 frames a second are plenty for a TV and keep the encoder and Wi-Fi light
    if lastPts.isValid && CMTimeGetSeconds(CMTimeSubtract(pts, lastPts)) < 1.0 / 32 { return }
    lastPts = pts

    var orientation = CGImagePropertyOrientation.up
    if let o = CMGetAttachment(sb, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
       let v = CGImagePropertyOrientation(rawValue: o.uint32Value) {
      orientation = v
    }
    let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
    let turn = orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored
    // the picture's shape on the TV
    let (ow, oh) = turn ? (sh, sw) : (sw, sh)
    let scale = min(1.0, Double(maxLong) / Double(max(ow, oh)), Double(maxLong) * 9.0 / 16.0 / Double(min(ow, oh)))
    let w = max(16, Int(Double(ow) * scale) / 16 * 16)
    let h = max(16, Int(Double(oh) * scale) / 16 * 16)

    var frame: CVPixelBuffer = src
    if #available(iOS 16.0, *) {
      if let upright = prepare(src, orientation: orientation, turn: turn, w: w, h: h) { frame = upright }
    }
    if session == nil || encW != w || encH != h {
      makeSession(w: w, h: h)
    }
    guard let s = session else { return }
    var props: CFDictionary?
    if forceKey {
      forceKey = false
      props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
    }
    VTCompressionSessionEncodeFrame(s, imageBuffer: frame, presentationTimeStamp: pts, duration: .invalid,
                                    frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, out in
      guard status == noErr, let out = out, let self = self else { return }
      self.q.async { self.encoded(out) }
    }
  }

  /// Scale down first (a full-screen frame is ~12 MB), then turn upright.
  @available(iOS 16.0, *)
  private func prepare(_ src: CVPixelBuffer, orientation: CGImagePropertyOrientation, turn: Bool, w: Int, h: Int) -> CVPixelBuffer? {
    let fmt = CVPixelBufferGetPixelFormatType(src)
    let (sw, sh) = turn ? (h, w) : (w, h) // scaled, not yet turned
    let key = "\(fmt)-\(sw)x\(sh)-\(orientation.rawValue)"
    if key != poolKey {
      poolKey = key
      scalePool = makePool(fmt, sw, sh)
      rotatePool = turn || orientation == .down ? makePool(fmt, w, h) : nil
      if transfer == nil {
        var t: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
        transfer = t
      }
      if rotation == nil {
        var r: VTPixelRotationSession?
        VTPixelRotationSessionCreate(allocator: nil, pixelRotationSessionOut: &r)
        rotation = r
      }
    }
    guard let tObj = transfer, let sp = scalePool else { return nil }
    let tSession = tObj as! VTPixelTransferSession
    var scaled: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, sp, &scaled)
    guard let small = scaled, VTPixelTransferSessionTransferImage(tSession, from: src, to: small) == noErr else { return nil }
    guard let rp = rotatePool, let rObj = rotation else { return small }
    let rSession = rObj as! VTPixelRotationSession
    let angle: CFString
    switch orientation {
    case .right, .rightMirrored: angle = kVTRotation_CW90
    case .left, .leftMirrored: angle = kVTRotation_CCW90
    case .down, .downMirrored: angle = kVTRotation_180
    default: return small
    }
    VTSessionSetProperty(rSession, key: kVTPixelRotationPropertyKey_Rotation, value: angle)
    var turned: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, rp, &turned)
    guard let out = turned, VTPixelRotationSessionRotateImage(rSession, from: small, to: out) == noErr else { return small }
    return out
  }

  private func makePool(_ fmt: OSType, _ w: Int, _ h: Int) -> CVPixelBufferPool? {
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: fmt,
      kCVPixelBufferWidthKey as String: w,
      kCVPixelBufferHeightKey as String: h,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary,
                            attrs as CFDictionary, &pool)
    return pool
  }

  private func makeSession(w: Int, h: Int) {
    if let old = session {
      VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(old)
      session = nil
    }
    var spec: [String: Any] = [:]
    if #available(iOS 14.5, *) {
      spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
    }
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
                                        codecType: kCMVideoCodecType_H264,
                                        encoderSpecification: spec.isEmpty ? nil : spec as CFDictionary,
                                        imageBufferAttributes: nil, compressedDataAllocator: nil,
                                        outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    guard st == noErr, let session = s else { return }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
    VTCompressionSessionPrepareToEncodeFrames(session)
    self.session = session
    encW = w
    encH = h
    sentFormat = nil
    forceKey = true
  }

  private func encoded(_ sb: CMSampleBuffer) {
    guard ready, !finished else { return }
    var key = true
    if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]],
       let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
      key = !notSync
    }
    if key, let fmt = CMSampleBufferGetFormatDescription(sb), sentFormat == nil || !CMFormatDescriptionEqual(fmt, otherFormatDescription: sentFormat) {
      if let cfg = parameterSets(fmt) {
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        var p = Data()
        p.append(be32(UInt32(dims.width)))
        p.append(be32(UInt32(dims.height)))
        p.append(cfg)
        send(1, p, pts: 0)
        sentFormat = fmt
        skipping = false
      }
    }
    guard sentFormat != nil else { return }
    // Wi-Fi falls behind: skip up to the next key frame, so the TV shows now, not seconds ago
    if pending > backlogLimit && !skipping {
      skipping = true
      forceKey = true
    }
    if skipping {
      if !key || pending > backlogLimit { return }
      skipping = false
    }
    guard let annexB = annexB(sb) else { return }
    let t = CMSampleBufferGetPresentationTimeStamp(sb)
    let us = t.isValid ? Int64(CMTimeGetSeconds(t) * 1_000_000) : 0
    send(key ? 3 : 2, annexB, pts: us)
  }

  private func parameterSets(_ fmt: CMFormatDescription) -> Data? {
    var count = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                             parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                             nalUnitHeaderLengthOut: nil) == noErr else { return nil }
    var out = Data()
    for i in 0..<count {
      var ptr: UnsafePointer<UInt8>?
      var size = 0
      if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                            parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                            nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
        out.append(contentsOf: [0, 0, 0, 1])
        out.append(p, count: size)
      }
    }
    return out.isEmpty ? nil : out
  }

  /// AVCC (4-byte lengths) → Annex B (start codes), what Android's decoder takes.
  private func annexB(_ sb: CMSampleBuffer) -> Data? {
    guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
    var total = 0
    var ptr: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total,
                                      dataPointerOut: &ptr) == kCMBlockBufferNoErr, let base = ptr else { return nil }
    var out = Data(capacity: total + 16)
    var off = 0
    base.withMemoryRebound(to: UInt8.self, capacity: total) { b in
      while off + 4 <= total {
        let n = Int(b[off]) << 24 | Int(b[off + 1]) << 16 | Int(b[off + 2]) << 8 | Int(b[off + 3])
        off += 4
        if n <= 0 || off + n > total { break }
        out.append(contentsOf: [0, 0, 0, 1])
        out.append(b + off, count: n)
        off += n
      }
    }
    return out.isEmpty ? nil : out
  }

  // MARK: Sound

  private func audio(_ sb: CMSampleBuffer) {
    guard ready, !finished, pending < backlogLimit / 2,
          let fmt = CMSampleBufferGetFormatDescription(sb),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return }
    let asbd = asbdPtr.pointee
    let rate = Int(asbd.mSampleRate)
    let channels = Int(asbd.mChannelsPerFrame)
    guard rate > 0, channels > 0 else { return }
    let outChannels = min(channels, 2)

    var abl = AudioBufferList()
    var block: CMBlockBuffer?
    let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
    // more than one buffer (planar): too rare in ReplayKit's app audio to be worth a bigger list
    guard st == noErr, abl.mNumberBuffers >= 1, let raw = abl.mBuffers.mData else { return }
    let bytes = Int(abl.mBuffers.mDataByteSize)
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
    let bits = Int(asbd.mBitsPerChannel)
    let frames = CMSampleBufferGetNumSamples(sb)
    guard frames > 0 else { return }

    var pcm = Data(count: frames * outChannels * 2)
    pcm.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
      let o = dst.bindMemory(to: Int16.self)
      for f in 0..<frames {
        for ch in 0..<outChannels {
          let idx = f * channels + ch
          var v: Int16 = 0
          if isFloat && bits == 32 {
            guard (idx + 1) * 4 <= bytes else { continue }
            var u = raw.load(fromByteOffset: idx * 4, as: UInt32.self)
            if bigEndian { u = u.byteSwapped }
            let x = max(-1, min(1, Float(bitPattern: u)))
            v = Int16(x * 32767)
          } else if bits == 16 {
            guard (idx + 1) * 2 <= bytes else { continue }
            var u = raw.load(fromByteOffset: idx * 2, as: UInt16.self)
            if bigEndian { u = u.byteSwapped }
            v = Int16(bitPattern: u)
          } else if bits == 32 {
            guard (idx + 1) * 4 <= bytes else { continue }
            var u = raw.load(fromByteOffset: idx * 4, as: UInt32.self)
            if bigEndian { u = u.byteSwapped }
            v = Int16(truncatingIfNeeded: Int32(bitPattern: u) >> 16)
          }
          o[f * outChannels + ch] = v.littleEndian
        }
      }
    }
    if rate != soundRate || outChannels != soundChannels {
      soundRate = rate
      soundChannels = outChannels
      var p = Data()
      p.append(be32(UInt32(rate)))
      p.append(be32(UInt32(outChannels)))
      send(4, p, pts: 0)
    }
    let t = CMSampleBufferGetPresentationTimeStamp(sb)
    send(5, pcm, pts: t.isValid ? Int64(CMTimeGetSeconds(t) * 1_000_000) : 0)
  }

  // MARK: - Bytes

  private func be32(_ v: UInt32) -> Data {
    var b = v.bigEndian
    return Data(bytes: &b, count: 4)
  }

  private func be64(_ v: UInt64) -> Data {
    var b = v.bigEndian
    return Data(bytes: &b, count: 8)
  }
}
