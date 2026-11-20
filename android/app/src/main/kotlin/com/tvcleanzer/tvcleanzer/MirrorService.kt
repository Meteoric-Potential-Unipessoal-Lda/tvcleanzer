package com.tvcleanzer.tvcleanzer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Display
import android.view.Surface
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * «Повтор экрана»: the phone's screen (H.264) and sound (PCM, Android 10+) to the TV launcher's
 * MirrorActivity over plain TCP on the home network. Runs as a mediaProjection foreground
 * service; the stream format is described in the launcher's MirrorActivity.
 */
class MirrorService : Service() {
    companion object {
        const val ACTION_STOP = "com.tvcleanzer.mirror.STOP"
        private const val MAGIC = 0x5456434D
        private const val NOTE_ID = 7300
        private const val CHANNEL = "mirror"
        private const val BACKLOG = 1_500_000L // bytes waiting for Wi-Fi before we skip frames

        @Volatile var running = false
            private set

        /** Called on the main thread when mirroring ends: null = stopped by the user, else a reason code. */
        var onStopped: ((String?) -> Unit)? = null

        private var instance: MirrorService? = null
        fun stopNow() = instance?.finish(null)

        /** The phone's own port for the TV to dial (opened by MainActivity before the TV starts). */
        @Volatile var phoneServer: java.net.ServerSocket? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private val ctl = Executors.newSingleThreadExecutor()
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var enc: Encoder? = null
    private var sender: Sender? = null
    private var socket: Socket? = null
    private var audio: Thread? = null
    @Volatile private var done = false
    private var maxLong = 1920
    private var bitrate = 8_000_000
    private var appMode = false // the user shared one app: its size comes from the projection
    private var lastLandscape: Boolean? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || intent.action == ACTION_STOP) {
            finish(null)
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        running = true
        instance = this
        val title = intent.getStringExtra("title") ?: "TVCleanzer"
        val stopLabel = intent.getStringExtra("stop") ?: "Stop"
        val note = notification(title, stopLabel)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTE_ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTE_ID, note)
        }
        val code = intent.getIntExtra("code", 0)
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra("data", Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra("data")
        }
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = try {
            data?.let { mpm.getMediaProjection(code, it) }
        } catch (e: Exception) {
            null
        }
        if (p == null) {
            finish("denied")
            return START_NOT_STICKY
        }
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() = finish(null)
            override fun onCapturedContentResize(width: Int, height: Int) {
                appMode = true
                ctl.execute { resize(width, height) }
            }
        }, main)
        maxLong = intent.getIntExtra("maxSize", 1920)
        bitrate = intent.getIntExtra("bitrate", 8_000_000)
        val host = intent.getStringExtra("host") ?: ""
        val port = intent.getIntExtra("port", 7300)
        val token = intent.getStringExtra("token") ?: ""
        val withSound = intent.getBooleanExtra("audio", false)
        relayPort = intent.getIntExtra("relayPort", 0)
        ctl.execute { begin(host, port, token, withSound) }
        return START_NOT_STICKY
    }

    private fun begin(host: String, port: Int, token: String, withSound: Boolean) {
        val s = meet(host, port, token) ?: return
        try {
            s.soTimeout = 0
            val out = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 1 shl 16))
            socket = s
            sender = Sender(out) { finish("closed") }
            // the TV closing the screen shows up as the end of this stream
            Thread({
                try {
                    while (s.getInputStream().read() >= 0) { /* nothing is sent back */ }
                } catch (_: IOException) { }
                finish("closed")
            }, "mirror-watch").start()
        } catch (e: IOException) {
            return finish("connect|${e.message}")
        }
        val size = screen()
        lastLandscape = size.x > size.y
        val (w, h) = fit(size.x, size.y)
        val e = try {
            Encoder.create(w, h, bitrate)
        } catch (ex: Exception) {
            return finish("encoder")
        }
        enc = e
        display = try {
            projection?.createVirtualDisplay(
                "TVCleanzer", e.width, e.height, resources.displayMetrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, e.surface, null, null,
            )
        } catch (ex: Exception) {
            null
        }
        if (display == null) return finish("encoder")
        e.start(sender!!)
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).registerDisplayListener(turns, main)
        if (withSound && Build.VERSION.SDK_INT >= 29) startSound()
    }

    /**
     * Two roads to the TV, the first that answers wins: we dial the TV's port, and the TV
     * (launcher 0.45+) dials ours — for TVs and routers that let nothing in to an app's port.
     * The greeting is the same both ways: we send magic + token, the TV answers 1.
     */
    @Volatile private var lastError = "timeout"
    @Volatile private var tvSaidNo = false

    private var relayPort = 0

    private fun meet(host: String, port: Int, token: String): Socket? {
        val won = java.util.concurrent.atomic.AtomicReference<Socket?>(null)
        val lock = Object()
        lastError = "timeout"
        tvSaidNo = false
        val until = System.currentTimeMillis() + 25_000

        fun greet(s: Socket): Boolean {
            try {
                s.tcpNoDelay = true
                s.sendBufferSize = 1 shl 20
                s.soTimeout = 8000
                val out = DataOutputStream(s.getOutputStream())
                out.writeInt(MAGIC)
                out.writeInt(1)
                out.writeUTF(token)
                out.flush()
                val answer = s.getInputStream().read()
                if (answer == 1 && won.compareAndSet(null, s)) {
                    synchronized(lock) { lock.notifyAll() }
                    return true
                }
                if (answer == 0) tvSaidNo = true
            } catch (e: IOException) {
                lastError = e.message ?: e.javaClass.simpleName
            }
            runCatching { s.close() }
            return false
        }

        val server = phoneServer
        phoneServer = null
        if (server != null) {
            Thread({
                try {
                    server.soTimeout = 1000
                    while (!done && won.get() == null && System.currentTimeMillis() < until) {
                        val c = try { server.accept() } catch (_: java.net.SocketTimeoutException) { continue }
                        Thread({ greet(c) }, "mirror-greet").start()
                    }
                } catch (_: IOException) {
                } finally {
                    runCatching { server.close() }
                }
            }, "mirror-listen").start()
        }
        fun dial(h: String, p: Int, name: String) = Thread({
            while (!done && won.get() == null && System.currentTimeMillis() < until) {
                val s = Socket()
                try {
                    s.connect(InetSocketAddress(h, p), 3000)
                    if (greet(s)) return@Thread
                } catch (e: IOException) {
                    if (name == "mirror-dial") lastError = e.message ?: e.javaClass.simpleName
                    runCatching { s.close() }
                }
                Thread.sleep(500)
            }
        }, name).start()
        dial(host, port, "mirror-dial")
        // third road: the app carries the stream over its ADB connection (TV firewalls)
        if (relayPort > 0) dial("127.0.0.1", relayPort, "mirror-relay")

        synchronized(lock) {
            while (!done && won.get() == null && System.currentTimeMillis() < until) {
                lock.wait(250)
            }
        }
        val s = won.get()
        if (s == null) {
            runCatching { server?.close() }
            finish(if (tvSaidNo) "token" else "connect|$lastError")
        }
        return s
    }

    /** The phone turned: a new picture shape (not when only one app is shared). */
    private val turns = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != Display.DEFAULT_DISPLAY || appMode) return
            val s = screen()
            val land = s.x > s.y
            if (land == lastLandscape) return
            lastLandscape = land
            ctl.execute { resize(s.x, s.y) }
        }
    }

    private fun resize(sw: Int, sh: Int) {
        if (done || sw <= 0 || sh <= 0) return
        val vd = display ?: return
        val snd = sender ?: return
        val (w, h) = fit(sw, sh)
        val old = enc
        if (old != null && old.width == w && old.height == h) return
        val e = try {
            Encoder.create(w, h, bitrate)
        } catch (ex: Exception) {
            return
        }
        vd.surface = null
        old?.release() // its last frames must not follow the new size's config
        vd.resize(w, h, resources.displayMetrics.densityDpi)
        vd.surface = e.surface
        enc = e
        e.start(snd)
    }

    @Suppress("DEPRECATION")
    private fun screen(): Point {
        val p = Point()
        (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).getDisplay(Display.DEFAULT_DISPLAY).getRealSize(p)
        return p
    }

    /** Fits the screen into maxLong × (maxLong·9/16), even sizes the encoder accepts. */
    private fun fit(sw: Int, sh: Int): Pair<Int, Int> {
        val long = max(sw, sh).toDouble()
        val short = min(sw, sh).toDouble()
        val scale = minOf(1.0, maxLong / long, maxLong * 9.0 / 16.0 / short)
        var w = sw * scale
        var h = sh * scale
        repeat(6) {
            val ww = (w.toInt() / 16) * 16
            val hh = (h.toInt() / 16) * 16
            if (Encoder.supports(ww, hh)) return Pair(ww, hh)
            w *= 0.8
            h *= 0.8
        }
        return Pair((w.toInt() / 16) * 16, (h.toInt() / 16) * 16)
    }

    @android.annotation.TargetApi(29)
    private fun startSound() {
        if (Build.VERSION.SDK_INT < 29) return
        val p = projection ?: return
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val rate = 48000
        val cfg = AudioPlaybackCaptureConfiguration.Builder(p)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val rec = try {
            AudioRecord.Builder()
                .setAudioFormat(
                    AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_IN_STEREO).build(),
                )
                .setBufferSizeInBytes(max(AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT) * 2, rate * 4 / 5))
                .setAudioPlaybackCaptureConfig(cfg)
                .build()
        } catch (e: Exception) {
            return // no sound: the picture goes on
        }
        val snd = sender ?: return
        val cfgBytes = ByteBuffer.allocate(8).putInt(rate).putInt(2).array()
        snd.send(4, cfgBytes, 0)
        audio = Thread({
            val buf = ByteArray(rate * 4 / 50) // 20 ms
            try {
                rec.startRecording()
                while (!done) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n > 0) snd.sound(buf.copyOf(n), System.nanoTime() / 1000)
                    else if (n < 0) break
                }
            } catch (_: Exception) {
            } finally {
                runCatching { rec.stop() }
                rec.release()
            }
        }, "mirror-sound").apply { start() }
    }

    /** Ends mirroring once; [reason] null = the user stopped it. */
    fun finish(reason: String?) {
        if (done) return
        done = true
        main.post {
            runCatching { (getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(turns) }
            ctl.execute {
                runCatching { sender?.bye() }
                runCatching { socket?.close() }
                enc?.release()
                runCatching { display?.release() }
                runCatching { projection?.stop() }
            }
            ctl.shutdown()
            running = false
            instance = null
            stopNotice()
            stopSelf()
            onStopped?.invoke(reason)
        }
    }

    private fun stopNotice() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        finish(null)
        super.onDestroy()
    }

    private fun notification(title: String, stop: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val b = if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, title, NotificationManager.IMPORTANCE_LOW))
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val pi = PendingIntent.getService(
            this, 1, Intent(this, MirrorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0),
        )
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 2, it, if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0)
        }
        @Suppress("DEPRECATION")
        b.setContentTitle(title)
            .setSmallIcon(android.R.drawable.ic_menu_slideshow)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, stop, pi)
        if (open != null) b.setContentIntent(open)
        return b.build()
    }

    /** One H.264 encoder fed by the virtual display; its output goes to [Sender]. */
    private class Encoder(val codec: MediaCodec, val width: Int, val height: Int) {
        val surface: Surface = codec.createInputSurface()
        @Volatile private var stopped = false
        private var sentConfig = false
        private var thread: Thread? = null

        companion object {
            private const val MIME = "video/avc"

            fun supports(w: Int, h: Int): Boolean {
                if (w < 16 || h < 16) return false
                return try {
                    val c = MediaCodec.createEncoderByType(MIME)
                    val ok = c.codecInfo.getCapabilitiesForType(MIME).videoCapabilities.isSizeSupported(w, h)
                    c.release()
                    ok
                } catch (_: Exception) {
                    true
                }
            }

            fun create(w: Int, h: Int, bitrate: Int): Encoder {
                val f = MediaFormat.createVideoFormat(MIME, w, h)
                f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                f.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                f.setInteger(MediaFormat.KEY_FRAME_RATE, 60)
                f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                // a still screen still sends frames, so the TV never waits on an old picture
                f.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
                if (Build.VERSION.SDK_INT >= 23) f.setInteger(MediaFormat.KEY_PRIORITY, 0)
                if (Build.VERSION.SDK_INT >= 29) f.setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, 60f)
                val c = MediaCodec.createEncoderByType(MIME)
                try {
                    c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                } catch (e: Exception) {
                    c.release()
                    throw e
                }
                return Encoder(c, w, h)
            }
        }

        fun start(out: Sender) {
            codec.start()
            thread = Thread({ drain(out) }, "mirror-encode").apply { start() }
        }

        private fun drain(out: Sender) {
            val info = MediaCodec.BufferInfo()
            try {
                while (!stopped) {
                    val idx = codec.dequeueOutputBuffer(info, 20_000)
                    if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED && !sentConfig) {
                        // some encoders give SPS/PPS only here, not as a config buffer
                        val f = codec.outputFormat
                        val sps = f.getByteBuffer("csd-0")
                        val pps = f.getByteBuffer("csd-1")
                        if (sps != null) {
                            val n = sps.remaining() + (pps?.remaining() ?: 0)
                            val b = ByteArray(8 + n)
                            val bb = ByteBuffer.wrap(b).putInt(width).putInt(height)
                            bb.put(sps)
                            if (pps != null) bb.put(pps)
                            out.send(1, b, 0)
                            sentConfig = true
                        }
                    }
                    if (idx < 0) continue
                    val buf = codec.getOutputBuffer(idx)
                    if (buf != null && info.size > 0) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                        if (config && sentConfig) {
                            // already sent from the output format
                        } else if (config) {
                            sentConfig = true
                            val b = ByteArray(8 + info.size)
                            ByteBuffer.wrap(b).putInt(width).putInt(height)
                            buf.get(b, 8, info.size)
                            out.send(1, b, 0)
                        } else {
                            val b = ByteArray(info.size)
                            buf.get(b)
                            val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            out.frame(b, info.presentationTimeUs, key) { askKeyFrame() }
                        }
                    }
                    codec.releaseOutputBuffer(idx, false)
                }
            } catch (_: IllegalStateException) {
                // released
            }
        }

        fun askKeyFrame() {
            runCatching {
                codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
            }
        }

        fun release() {
            stopped = true
            runCatching { thread?.join(500) }
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { surface.release() }
        }
    }

    /**
     * Writes packets on its own thread. When Wi-Fi falls behind, frames are skipped up to the
     * next key frame (and sound dropped), so the TV shows now rather than seconds ago.
     */
    private class Sender(private val out: DataOutputStream, private val onFail: () -> Unit) {
        private class Pkt(val type: Int, val data: ByteArray, val pts: Long)

        private val q = LinkedBlockingQueue<Pkt>()
        private val queued = AtomicLong()
        @Volatile private var skipping = false
        @Volatile private var closed = false

        init {
            Thread({ loop() }, "mirror-send").start()
        }

        fun send(type: Int, data: ByteArray, pts: Long) {
            queued.addAndGet(data.size.toLong())
            q.offer(Pkt(type, data, pts))
        }

        fun frame(data: ByteArray, pts: Long, key: Boolean, askKey: () -> Unit) {
            if (queued.get() > BACKLOG && !skipping) {
                skipping = true
                askKey()
            }
            if (skipping) {
                if (!key || queued.get() > BACKLOG) return
                skipping = false
            }
            send(if (key) 3 else 2, data, pts)
        }

        fun sound(data: ByteArray, pts: Long) {
            if (queued.get() > BACKLOG / 2) return
            send(5, data, pts)
        }

        fun bye() {
            send(9, ByteArray(0), 0)
            Thread.sleep(150)
            closed = true
        }

        private fun loop() {
            try {
                while (!closed) {
                    val p = q.poll(500, java.util.concurrent.TimeUnit.MILLISECONDS) ?: continue
                    out.writeByte(p.type)
                    out.writeInt(p.data.size)
                    out.writeLong(p.pts)
                    out.write(p.data)
                    queued.addAndGet(-p.data.size.toLong())
                    if (q.isEmpty()) out.flush()
                }
            } catch (_: Exception) {
                if (!closed) onFail()
            }
        }
    }
}
