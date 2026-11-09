package com.tvcleanzer.tvcleanzer

import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyFactory
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

import java.security.Principal
import java.security.PrivateKey
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * "tvcleanzer/tls": a TLS 1.3 byte stream with our client certificate and
 * the TLS exporter (EKM) that adb pairing needs (dart:io has no exporter).
 * The pairing protocol itself is in Dart (lib/services/pairing/).
 */
class MainActivity : FlutterActivity() {
    private class Unsupported(msg: String) : Exception(msg)

    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val sockets = ConcurrentHashMap<Int, SSLSocket>()
    private val nextId = AtomicInteger(1)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tvcleanzer/tls")
            .setMethodCallHandler { call, result ->
                io.execute {
                    try {
                        val r: Any? = when (call.method) {
                            "open" -> open(
                                call.argument<String>("host")!!,
                                call.argument<Int>("port")!!,
                                call.argument<ByteArray>("cert")!!,
                                call.argument<ByteArray>("pkcs8")!!,
                            )
                            "ekm" -> ekm(sock(call), call.argument<ByteArray>("label")!!, call.argument<Int>("length")!!)
                            "write" -> {
                                val out = sock(call).outputStream
                                out.write(call.argument<ByteArray>("data")!!)
                                out.flush()
                                null
                            }
                            "read" -> {
                                val b = ByteArray(call.argument<Int>("length")!!)
                                DataInputStream(sock(call).inputStream).readFully(b)
                                b
                            }
                            "close" -> {
                                sockets.remove(call.argument<Int>("id")!!)?.close()
                                null
                            }
                            else -> throw UnsupportedOperationException(call.method)
                        }
                        main.post { result.success(r) }
                    } catch (e: Unsupported) {
                        main.post { result.error("unsupported", e.message, null) }
                    } catch (e: Exception) {
                        main.post { result.error("io", e.toString(), null) }
                    }
                }
            }
    }

    override fun onDestroy() {
        sockets.values.forEach { runCatching { it.close() } }
        sockets.clear()
        super.onDestroy()
    }

    private fun sock(call: MethodCall): SSLSocket =
        sockets[call.argument<Int>("id")!!] ?: throw IllegalStateException("connection closed")

    private fun open(host: String, port: Int, certDer: ByteArray, pkcs8: ByteArray): Int {
        if (Build.VERSION.SDK_INT < 29) {
            throw Unsupported("Подключение по коду работает на телефонах с Android 10 и новее.")
        }
        val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(pkcs8))
        val cert = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(certDer)) as X509Certificate
        // Always present our certificate: adbd may advertise a CA list our
        // self-signed cert does not match, and the default manager would skip it.
        val km = object : X509ExtendedKeyManager() {
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = "adb"
            override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = "adb"
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? = null
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf("adb")
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? = null
            override fun getCertificateChain(alias: String?) = arrayOf(cert)
            override fun getPrivateKey(alias: String?): PrivateKey = key
        }
        // The TV's certificate is self-signed; trust comes from the pairing code.
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val ctx = SSLContext.getInstance("TLSv1.3").apply { init(arrayOf(km), arrayOf(trustAll), SecureRandom()) }
        val plain = Socket().apply { connect(InetSocketAddress(host, port), 10_000) }
        val ssl = ctx.socketFactory.createSocket(plain, host, port, true) as SSLSocket
        ssl.enabledProtocols = arrayOf("TLSv1.3")
        ssl.useClientMode = true
        ssl.soTimeout = 30_000
        ssl.startHandshake()
        val id = nextId.getAndIncrement()
        sockets[id] = ssl
        return id
    }

    /** RFC 8446 exporter: public API on Android 12+, Conscrypt before that. */
    private fun ekm(s: SSLSocket, labelBytes: ByteArray, length: Int): ByteArray {
        val label = String(labelBytes, Charsets.ISO_8859_1) // keeps the trailing NUL
        if (Build.VERSION.SDK_INT >= 31) {
            return android.net.ssl.SSLSockets.exportKeyingMaterial(s, label, null, length)
                ?: throw IllegalStateException("no keying material")
        }
        try {
            val c = Class.forName("com.android.org.conscrypt.Conscrypt")
            val m = c.getMethod(
                "exportKeyingMaterial", SSLSocket::class.java, String::class.java,
                ByteArray::class.java, Int::class.javaPrimitiveType,
            )
            return m.invoke(null, s, label, null, length) as ByteArray
        } catch (e: Exception) {
            throw Unsupported("Подключение по коду на этом телефоне работает с Android 12. Обновите телефон или используйте ТВ с «Отладкой по сети».")
        }
    }
}
