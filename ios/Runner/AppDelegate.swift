import Flutter
import Network
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let tls = TlsBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TvcleanzerTls") {
      let channel = FlutterMethodChannel(name: "tvcleanzer/tls", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        self?.tls.handle(call, result)
      }
    }
  }
}

/// "tvcleanzer/tls": TLS 1.3 byte stream with our client certificate and the
/// TLS exporter (EKM) that adb pairing needs — dart:io has no exporter.
/// The pairing protocol itself is in Dart (lib/services/pairing/).
final class TlsBridge {
  private var conns: [Int: TlsConn] = [:]   // touched on the main thread only
  private var nextId = 1
  private let queue = DispatchQueue(label: "tvcleanzer.tls")

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    let done: (Any?) -> Void = { v in DispatchQueue.main.async { result(v) } }
    let fail: (String, String) -> Void = { code, msg in
      DispatchQueue.main.async { result(FlutterError(code: code, message: msg, details: nil)) }
    }
    func conn() -> TlsConn? {
      guard let id = a["id"] as? Int else { return nil }
      return conns[id]
    }

    switch call.method {
    case "open":
      guard let host = a["host"] as? String, let port = a["port"] as? Int,
            let cert = (a["cert"] as? FlutterStandardTypedData)?.data,
            let pkcs1 = (a["pkcs1"] as? FlutterStandardTypedData)?.data,
            let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
        return fail("args", "bad arguments")
      }
      let identity: SecIdentity
      do {
        identity = try TlsBridge.identity(certDer: cert, keyPkcs1: pkcs1)
      } catch {
        return fail("unsupported", "Не удалось подготовить ключ для подключения: \(error)")
      }
      let c = TlsConn(host: host, port: nwPort, identity: identity, queue: queue)
      c.start { err in
        DispatchQueue.main.async {
          if let err = err { result(FlutterError(code: "io", message: err, details: nil)); return }
          let id = self.nextId
          self.nextId += 1
          self.conns[id] = c
          result(id)
        }
      }

    case "ekm":
      guard let c = conn(), let label = (a["label"] as? FlutterStandardTypedData)?.data,
            let len = a["length"] as? Int else { return fail("io", "connection closed") }
      if let d = c.exportKeyingMaterial(label: label, length: len) {
        done(FlutterStandardTypedData(bytes: d))
      } else {
        fail("io", "TLS exporter failed")
      }

    case "write":
      guard let c = conn(), let data = (a["data"] as? FlutterStandardTypedData)?.data else {
        return fail("io", "connection closed")
      }
      c.write(data) { err in err == nil ? done(nil) : fail("io", err!) }

    case "read":
      guard let c = conn(), let len = a["length"] as? Int else { return fail("io", "connection closed") }
      c.read(len) { data, err in
        if let d = data { done(FlutterStandardTypedData(bytes: d)) } else { fail("io", err ?? "read failed") }
      }

    case "close":
      if let id = a["id"] as? Int, let c = conns.removeValue(forKey: id) { c.cancel() }
      done(nil)

    default:
      DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
    }
  }

  // Our RSA key + certificate as a keychain identity (iOS needs one for TLS client auth).
  private static let keyTag = "com.tvcleanzer.adb.key".data(using: .utf8)!
  private static let certLabel = "TVCleanzer ADB"

  static func identity(certDer: Data, keyPkcs1: Data) throws -> SecIdentity {
    if let id = findIdentity(certDer) { return id }
    SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag] as CFDictionary)
    SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: certLabel] as CFDictionary)

    var cfErr: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(keyPkcs1 as CFData, [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ] as CFDictionary, &cfErr) else {
      throw cfErr?.takeRetainedValue() as Error? ?? NSError(domain: "tls", code: 1)
    }
    var st = SecItemAdd([
      kSecClass as String: kSecClassKey,
      kSecValueRef as String: key,
      kSecAttrApplicationTag as String: keyTag,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ] as CFDictionary, nil)
    guard st == errSecSuccess || st == errSecDuplicateItem else { throw NSError(domain: "tls", code: Int(st)) }

    guard let cert = SecCertificateCreateWithData(nil, certDer as CFData) else {
      throw NSError(domain: "tls", code: 2)
    }
    st = SecItemAdd([
      kSecClass as String: kSecClassCertificate,
      kSecValueRef as String: cert,
      kSecAttrLabel as String: certLabel,
    ] as CFDictionary, nil)
    guard st == errSecSuccess || st == errSecDuplicateItem else { throw NSError(domain: "tls", code: Int(st)) }

    if let id = findIdentity(certDer) { return id }
    throw NSError(domain: "tls", code: 3, userInfo: [NSLocalizedDescriptionKey: "identity not found"])
  }

  private static func findIdentity(_ certDer: Data) -> SecIdentity? {
    var out: CFTypeRef?
    let st = SecItemCopyMatching([
      kSecClass as String: kSecClassIdentity,
      kSecReturnRef as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ] as CFDictionary, &out)
    guard st == errSecSuccess, let list = out as? [SecIdentity] else { return nil }
    for id in list {
      var c: SecCertificate?
      if SecIdentityCopyCertificate(id, &c) == errSecSuccess, let c = c,
         (SecCertificateCopyData(c) as Data) == certDer {
        return id
      }
    }
    return nil
  }
}

final class TlsConn {
  private let conn: NWConnection
  private let queue: DispatchQueue

  init(host: String, port: NWEndpoint.Port, identity: SecIdentity, queue: DispatchQueue) {
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
    if let sid = sec_identity_create(identity) {
      sec_protocol_options_set_local_identity(sec, sid)
    }
    // The TV's certificate is self-signed; trust comes from the pairing code.
    sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, queue)
    conn = NWConnection(host: NWEndpoint.Host(host), port: port,
                        using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    self.queue = queue
  }

  func start(_ cb: @escaping (String?) -> Void) {
    var fired = false
    conn.stateUpdateHandler = { [weak self] state in
      guard !fired else { return }
      switch state {
      case .ready:
        fired = true
        cb(nil)
      case .failed(let e):
        fired = true
        cb("\(e)")
      case .waiting(let e):
        fired = true
        self?.conn.cancel()
        cb("\(e)")
      default:
        break
      }
    }
    conn.start(queue: queue)
  }

  func exportKeyingMaterial(label: Data, length: Int) -> Data? {
    guard let meta = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
      return nil
    }
    let bytes = [CChar](label.map { CChar(bitPattern: $0) })
    guard let secret = sec_protocol_metadata_create_secret(
      meta.securityProtocolMetadata, bytes.count, bytes, length) else { return nil }
    return Data(secret as DispatchData)
  }

  func write(_ data: Data, _ cb: @escaping (String?) -> Void) {
    conn.send(content: data, completion: .contentProcessed { e in cb(e.map { "\($0)" }) })
  }

  func read(_ n: Int, _ cb: @escaping (Data?, String?) -> Void) {
    conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
      if let e = error { cb(nil, "\(e)"); return }
      guard let d = data, !d.isEmpty else { cb(nil, isComplete ? "closed" : "no data"); return }
      if d.count >= n {
        cb(d, nil)
      } else {
        self.read(n - d.count) { rest, err in
          if let r = rest { cb(d + r, nil) } else { cb(nil, err) }
        }
      }
    }
  }

  func cancel() { conn.cancel() }
}
