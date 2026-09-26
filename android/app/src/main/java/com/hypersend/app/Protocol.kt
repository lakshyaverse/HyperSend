package com.hypersend.app

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * HyperSend wire protocol (v1) — must match src/protocol.ts exactly:
 * control channel is length-prefixed JSON ([4-byte big-endian length][payload]),
 * the data plane is raw unframed bytes whose length is agreed via the control
 * channel (offer-response `offset` semantics included).
 */
object Protocol {
    const val VERSION = 2
    const val DEFAULT_PORT = 44010
    /**
     * Fixed data-plane port. Fixed (not ephemeral) on purpose: it lets the
     * USB cable act as its own path via `adb forward tcp:44012 tcp:44012`,
     * which needs no kernel driver at all.
     */
    const val DATA_PORT = 44012
    /** Chunked data plane: header is length(4) + flags(1) + offset(8). */
    const val CHUNK_HEADER_BYTES = 13
    const val CHUNK_SIZE = 2 * 1024 * 1024
    const val DISCOVERY_PORT = 44011
    const val MAX_CONTROL_BYTES = 1 shl 20
    private const val MAGIC = "hypersend-beacon-v1"

    fun writeMessage(out: DataOutputStream, obj: JSONObject) {
        val payload = obj.toString().toByteArray(Charsets.UTF_8)
        require(payload.size <= MAX_CONTROL_BYTES) { "control message too large" }
        out.writeInt(payload.size)
        out.write(payload)
        out.flush()
    }

    fun readMessage(input: DataInputStream): JSONObject? {
        val len = input.readInt()
        if (len <= 0 || len > MAX_CONTROL_BYTES) throw IllegalStateException("bad frame: $len")
        val buf = ByteArray(len)
        input.readFully(buf)
        return JSONObject(String(buf, Charsets.UTF_8))
    }

    fun encodeBeacon(controlPort: Int, name: String): ByteArray {
        val o = JSONObject()
        o.put("magic", MAGIC)
        o.put("port", controlPort)
        o.put("name", name)
        return o.toString().toByteArray(Charsets.UTF_8)
    }

    fun decodeBeacon(bytes: ByteArray): Pair<String, Int>? {
        return try {
            val o = JSONObject(String(bytes, Charsets.UTF_8))
            if (o.optString("magic") != MAGIC) return null
            val port = o.optInt("port", -1)
            val name = o.optString("name", "unknown")
            if (port in 1..65535) name to port else null
        } catch (e: Exception) {
            null
        }
    }

    /** Same safety rules as sanitizeRelativePath in src/protocol.ts. */
    fun sanitizePath(input: String): String {
        if (input.isEmpty() || input.length > 512) throw SecurityException("invalid path")
        val normalized = input.replace('\\', '/')
        val parts = normalized.split("/")
        for (part in parts) {
            if (part.isEmpty() || part == "." || part == ".." || part.contains('\u0000')) {
                throw SecurityException("unsafe path segment")
            }
        }
        return parts.joinToString("/")
    }

    fun newTransferId(): String = UUID.randomUUID().toString()

    fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { fis ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                val n = fis.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

/** One message of the control channel, typed for readability. */
class ControlMsg(val raw: JSONObject) {
    val type: String get() = raw.optString("type")
    val version: Int get() = raw.optInt("version", 0)
    val transferId: String get() = raw.optString("transferId")
    val path: String get() = raw.optString("path")
    val size: Long get() = raw.optLong("size", 0L)
    val sha256: String get() = raw.optString("sha256")
    val accept: Boolean get() = raw.optBoolean("accept", false)
    val offset: Long get() = raw.optLong("offset", 0L)
    val ok: Boolean get() = raw.optBoolean("ok", false)
    val message: String get() = raw.optString("message")
}

/**
 * UDP beacon broadcaster: mirrors startBeacon() in src/discovery.ts — the
 * receiver broadcasts "I'm here, connect at :port" every 500 ms so that any
 * sender on the LAN (whose discovery socket only listens) can find us.
 */
class BeaconResponder(
    private val controlPort: Int,
    private val name: String,
    private val running: AtomicBoolean,
) {
    private var socket: java.net.DatagramSocket? = null
    private var thread: Thread? = null

    fun start() {
        val s = java.net.DatagramSocket(null)
        s.reuseAddress = true
        s.bind(java.net.InetSocketAddress(Protocol.DISCOVERY_PORT))
        s.broadcast = true
        socket = s
        val payload = Protocol.encodeBeacon(controlPort, name)
        thread = Thread {
            var lastSend = 0L
            while (running.get()) {
                try {
                    val now = System.currentTimeMillis()
                    if (now - lastSend >= 500) {
                        lastSend = now
                        val out = java.net.DatagramPacket(
                            payload, payload.size,
                            java.net.InetAddress.getByName("255.255.255.255"), Protocol.DISCOVERY_PORT,
                        )
                        s.send(out)
                    }
                    Thread.sleep(50)
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    if (!running.get()) break
                    try {
                        Thread.sleep(200)
                    } catch (e2: InterruptedException) {
                        break
                    }
                }
            }
        }.apply { isDaemon = true; start() }
    }

    fun stop() {
        try {
            socket?.close()
        } catch (e: Exception) {
            // ignore
        }
    }
}

/** Finds a receiver by listening for its UDP beacon (matches src/discovery.ts). */
class BeaconListener(private val timeoutMs: Long = 5_000) {
    data class Peer(val host: String, val port: Int, val name: String)

    fun find(wantName: String? = null): Peer {
        val s = java.net.DatagramSocket(null)
        s.reuseAddress = true
        s.bind(java.net.InetSocketAddress(Protocol.DISCOVERY_PORT))
        s.broadcast = true
        val deadline = System.currentTimeMillis() + timeoutMs
        try {
            val buf = ByteArray(1024)
            val packet = java.net.DatagramPacket(buf, buf.size)
            while (System.currentTimeMillis() < deadline) {
                s.soTimeout = 250
                try {
                    s.receive(packet)
                } catch (e: java.net.SocketTimeoutException) {
                    continue
                }
                val decoded = Protocol.decodeBeacon(packet.data.copyOf(packet.length)) ?: continue
                if (wantName != null && decoded.first != wantName) continue
                return Peer(packet.address.hostAddress ?: continue, decoded.second, decoded.first)
            }
        } finally {
            s.close()
        }
        throw IllegalStateException("no peers found within ${timeoutMs}ms")
    }
}

/**
 * Receiver engine: accepts one control connection, handles hello/offer/file
 * streams, verifies SHA-256, supports resume. Mirrors src/engine.ts.
 */
class ReceiverEngine(
    private val destDir: File,
    private val port: Int,
    private val deviceName: String,
    private val running: AtomicBoolean,
    private val log: (String) -> Unit,
    private val onStateChange: () -> Unit,
) {
    @Volatile var lastFileName: String = ""
        private set
    @Volatile var lastFileBytes: Long = 0
        private set
    @Volatile var lastFileTotal: Long = 0
        private set
    @Volatile var bytesPerSec: Long = 0
        private set
    @Volatile var receivedCount: Int = 0
        private set

    private var controlServer: ServerSocket? = null
    private var beacon: BeaconResponder? = null
    private val receivedFiles = mutableListOf<File>()

    fun start() {
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(port))
        controlServer = ss
        beacon = BeaconResponder(port, deviceName, running).also { it.start() }
        log("listening on port $port as \"$deviceName\"")
        onStateChange()
        while (running.get()) {
            try {
                val sock = ss.accept()
                handleSession(sock)
            } catch (e: Exception) {
                if (running.get()) log("accept failed: ${e.message}")
            }
        }
    }

    private fun handleSession(sock: Socket) {
        val box = ActiveBox()
        var dataServer: ServerSocket? = null
        try {
            sock.tcpNoDelay = true
            sock.soTimeout = 30_000
            val input = DataInputStream(BufferedInputStream(sock.getInputStream(), 1 shl 16))
            val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1 shl 16))

            val hello = ControlMsg(Protocol.readMessage(input) ?: return)
            if (hello.type != "hello" || hello.version != Protocol.VERSION) {
                log("protocol mismatch with sender")
                return
            }

            // One data listener per SESSION, not per file. It stays bound for
            // the whole session so the sender can reuse its socket pool across
            // every file in a batch — and so a finished transfer never leaves a
            // half-torn-down listener (or a stale backlog) behind. This is what
            // used to make a second transfer hang until the app was restarted.
            val ds = ServerSocket()
            ds.reuseAddress = true
            bindWithRetry(ds, Protocol.DATA_PORT)
            dataServer = ds

            val ready = JSONObject()
            ready.put("type", "ready")
            ready.put("name", deviceName)
            ready.put("streams", 1)
            ready.put("dataPort", ds.localPort)
            ready.put("chunkSize", Protocol.CHUNK_SIZE)
            Protocol.writeMessage(out, ready)

            val acceptor = Thread { acceptData(ds, box) }
            acceptor.isDaemon = true
            acceptor.start()

            while (running.get()) {
                val msg = ControlMsg(Protocol.readMessage(input) ?: break)
                when (msg.type) {
                    "offer" -> handleOffer(out, msg, box)
                    "file-sent" -> handleFileSent(out, msg, box)
                    "batch-done" -> {
                        log("batch complete: ${msg.raw.optInt("files")} file(s), ${msg.raw.optLong("bytes") / (1024 * 1024)} MB")
                        return
                    }
                    "error" -> {
                        log("sender error: ${msg.message}")
                        return
                    }
                }
            }
        } catch (e: Exception) {
            if (running.get()) log("session ended: ${e.message ?: e.javaClass.simpleName}")
        } finally {
            // Order matters: stop the readers, let in-flight writes settle, then
            // close the file and release the port for the next session.
            for (s in box.closeAll()) {
                try {
                    s.close()
                } catch (e: Exception) {
                    // ignore
                }
            }
            try {
                Thread.sleep(50)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            box.set(null)
            try {
                dataServer?.close()
            } catch (e: Exception) {
                // ignore
            }
            try {
                sock.close()
            } catch (e: Exception) {
                // ignore
            }
            bytesPerSec = 0
            onStateChange()
        }
    }

    /** Binds a fixed port, retrying while the previous session's socket drains. */
    private fun bindWithRetry(server: ServerSocket, port: Int, attempts: Int = 6) {
        var delay = 50L
        var last: Exception? = null
        repeat(attempts) {
            try {
                server.bind(InetSocketAddress(port))
                return
            } catch (e: Exception) {
                last = e
                try {
                    Thread.sleep(delay)
                } catch (ie: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                delay *= 2
            }
        }
        throw last ?: IllegalStateException("could not bind port $port")
    }

    private fun handleOffer(out: DataOutputStream, offer: ControlMsg, box: ActiveBox) {
        val safePath = try {
            Protocol.sanitizePath(offer.path)
        } catch (e: SecurityException) {
            log("rejected unsafe path: ${offer.path}")
            val err = JSONObject()
            err.put("type", "offer-response")
            err.put("transferId", offer.transferId)
            err.put("accept", false)
            err.put("reason", "unsafe path")
            Protocol.writeMessage(out, err)
            return
        }

        val target = File(destDir, safePath)
        target.parentFile?.mkdirs()

        // Resume: reuse any prefix already on disk (mirrors src/engine.ts).
        var offset = 0L
        if (target.exists() && target.length() > 0 && target.length() <= offer.size) {
            if (target.length() == offer.size) {
                if (Protocol.sha256(target) == offer.sha256) {
                    recordReceived(target, offer.size)
                    val resp = JSONObject()
                    resp.put("type", "offer-response")
                    resp.put("transferId", offer.transferId)
                    resp.put("accept", true)
                    resp.put("offset", offer.size)
                    Protocol.writeMessage(out, resp)
                    val done = JSONObject()
                    done.put("type", "file-done")
                    done.put("transferId", offer.transferId)
                    done.put("ok", true)
                    Protocol.writeMessage(out, done)
                    log("already have ${target.name} — skipped")
                    return
                }
                offset = 0
            } else {
                offset = target.length()
            }
        }

        val active = ActiveFile(target, offer.size, offset, offer.sha256)
        // Install the target BEFORE answering: the sender starts streaming the
        // moment it sees offer-response and its sockets are already open.
        box.set(active)

        val resp = JSONObject()
        resp.put("type", "offer-response")
        resp.put("transferId", offer.transferId)
        resp.put("accept", true)
        resp.put("offset", offset)
        Protocol.writeMessage(out, resp)

        lastFileName = target.name
        lastFileTotal = offer.size
        lastFileBytes = offset
        onStateChange()
        if (offset < offer.size) log("receiving ${target.name} · ${humanBytes(offer.size)}")
    }

    /** Verifies and closes out the file the sender just finished streaming. */
    private fun handleFileSent(out: DataOutputStream, msg: ControlMsg, box: ActiveBox) {
        val transferId = msg.transferId
        val active = box.get()
        if (active == null) {
            replyDone(out, transferId, ok = false, error = "no active file")
            return
        }
        val arrived = waitForComplete(active, box, 900_000)
        // Freeze the file before hashing it, so a late duplicate chunk can never
        // land mid-digest.
        box.set(null)
        val hash = if (arrived) Protocol.sha256(active.file) else ""
        if (arrived && hash == active.sha256) {
            recordReceived(active.file, active.total)
            replyDone(out, transferId, ok = true, error = null)
            log("verified ${active.file.name} (${humanBytes(active.total)})")
        } else {
            active.file.delete()
            replyDone(
                out,
                transferId,
                ok = false,
                error = if (arrived) "sha256 mismatch" else "data streams ended early",
            )
            log("✗ ${active.file.name} failed — discarded")
        }
    }

    private fun replyDone(out: DataOutputStream, transferId: String, ok: Boolean, error: String?) {
        val done = JSONObject()
        done.put("type", "file-done")
        done.put("transferId", transferId)
        done.put("ok", ok)
        if (error != null) done.put("error", error)
        Protocol.writeMessage(out, done)
    }

    /**
     * Accepts data connections for the whole session and gives each one its own
     * reader thread. Sockets are deliberately NOT closed per file: the sender
     * opens its pool once and reuses it for every file in a batch, so readers
     * must outlive a single file and simply follow whichever file is active.
     */
    private fun acceptData(server: ServerSocket, box: ActiveBox) {
        server.soTimeout = 300
        while (running.get()) {
            val s = try {
                server.accept()
            } catch (e: java.net.SocketTimeoutException) {
                continue
            } catch (e: Exception) {
                return
            }
            box.add(s)
            val t = Thread {
                try {
                    readChunks(s, box)
                } finally {
                    box.remove(s)
                    try {
                        s.close()
                    } catch (e: Exception) {
                        // ignore
                    }
                }
            }
            t.isDaemon = true
            t.start()
        }
    }

    /**
     * v2 multipath ingest (the hot path).
     *
     * Any number of data connections may arrive; each carries independent
     * chunks: [4-byte BE length][1-byte flags][8-byte BE offset][payload].
     * Every payload is written at its absolute file offset, so chunks may
     * arrive out of order and interleaved across sockets. Completion is
     * chunk-index driven, which makes the transfer agnostic to how many paths
     * or sockets the sender used.
     */
    private fun readChunks(s: Socket, box: ActiveBox) {
        s.tcpNoDelay = true
        val din = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 16))
        var lastTick = System.currentTimeMillis()
        var lastBytes = 0L
        try {
            while (running.get()) {
                val frameLen = din.readInt() // EOF ends this stream
                din.readByte() // flags: reserved (0x01 today)
                val off = din.readLong()
                val payloadLen = frameLen - (Protocol.CHUNK_HEADER_BYTES - 4)
                if (payloadLen <= 0 || payloadLen > 32 * 1024 * 1024) {
                    throw java.io.IOException("bad chunk length: $payloadLen")
                }
                val buf = ByteArray(payloadLen)
                din.readFully(buf)
                val active = box.get() ?: throw java.io.IOException("chunk arrived with no active file")
                val bb = java.nio.ByteBuffer.wrap(buf)
                var pos = off
                while (bb.hasRemaining()) {
                    pos += active.channel.write(bb, pos)
                }
                active.ingest(off, payloadLen)

                val now = System.currentTimeMillis()
                if (now - lastTick >= 500) {
                    val total = active.receivedBytes
                    bytesPerSec = if (now > lastTick) (total - lastBytes) * 1000 / (now - lastTick) else 0
                    lastTick = now
                    lastBytes = total
                    lastFileBytes = total
                    lastFileTotal = active.total
                    lastFileName = active.file.name
                    onStateChange()
                }
            }
        } catch (e: Exception) {
            // clean EOF or socket error — this writer is done
        }
    }

    private fun waitForComplete(active: ActiveFile, box: ActiveBox, timeoutMs: Long): Boolean {
        val start = System.currentTimeMillis()
        while (!active.isComplete) {
            if (System.currentTimeMillis() - start > timeoutMs) return false
            // A session sitting with zero data sockets for more than a moment is
            // dead: never hang forever on a sender that walked away.
            if (box.socketCount == 0 && System.currentTimeMillis() - start > 1500) return false
            try {
                Thread.sleep(20)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return true
    }

    /** One file written by N sockets at once, at absolute offsets. */
    private class ActiveFile(
        val file: File,
        val total: Long,
        val startOffset: Long,
        val sha256: String,
    ) {
        private val raf = java.io.RandomAccessFile(file, "rw")
        val channel = raf.channel
        private val chunkSize = Protocol.CHUNK_SIZE.toLong()
        private val chunkCount = (total - startOffset + chunkSize - 1) / chunkSize
        private val lock = Object()
        private val indices = HashSet<Int>()
        private var written = startOffset
        private var closed = false

        init {
            // Resume keeps the prefix; a fresh file starts at zero, which also
            // truncates a stale same-name file from an earlier run.
            raf.setLength(startOffset)
        }

        val receivedBytes: Long get() = synchronized(lock) { written }
        val isComplete: Boolean get() = synchronized(lock) { indices.size.toLong() >= chunkCount }

        /** Records one chunk. Safe to call from many threads at once. */
        fun ingest(offset: Long, length: Int) {
            val index = (offset / chunkSize).toInt()
            synchronized(lock) {
                if (indices.add(index)) written += length
            }
        }

        fun close() {
            synchronized(lock) {
                if (closed) return
                closed = true
            }
            try {
                raf.fd.sync()
            } catch (e: Exception) {
                // ignore
            }
            try {
                raf.close()
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    /** Holds the file currently in play plus every live data socket. */
    private class ActiveBox {
        private val lock = Object()
        private var file: ActiveFile? = null
        private val sockets = ArrayList<Socket>()

        fun get(): ActiveFile? = synchronized(lock) { file }

        fun set(value: ActiveFile?) {
            val previous: ActiveFile?
            synchronized(lock) {
                previous = file
                file = value
            }
            if (previous !== value) previous?.close()
        }

        fun add(s: Socket) {
            synchronized(lock) { sockets.add(s) }
        }

        fun remove(s: Socket) {
            synchronized(lock) { sockets.remove(s) }
        }

        val socketCount: Int get() = synchronized(lock) { sockets.size }

        fun closeAll(): List<Socket> = synchronized(lock) {
            val copy = ArrayList(sockets)
            sockets.clear()
            copy
        }
    }

    private fun recordReceived(f: File, size: Long) {
        synchronized(receivedFiles) {
            receivedFiles.add(f)
            receivedCount = receivedFiles.size
        }
        onStateChange()
    }

    private fun humanBytes(n: Long): String = when {
        n >= 1L shl 30 -> "%.2f GB".format(n.toDouble() / (1L shl 30))
        n >= 1L shl 20 -> "%.2f MB".format(n.toDouble() / (1L shl 20))
        n >= 1L shl 10 -> "%.1f KB".format(n.toDouble() / (1L shl 10))
        else -> "$n B"
    }

    fun stop() {
        try {
            controlServer?.close()
        } catch (e: Exception) {
            // ignore
        }
        beacon?.stop()
    }
}

fun localIpAddress(): String? {
    return try {
        val eni = NetworkInterface.getNetworkInterfaces()
        while (eni.hasMoreElements()) {
            val nif = eni.nextElement()
            if (!nif.isUp || nif.isLoopback) continue
            val addrs = nif.inetAddresses
            while (addrs.hasMoreElements()) {
                val addr = addrs.nextElement()
                if (addr is java.net.Inet4Address && !addr.isLoopbackAddress) {
                    return addr.hostAddress
                }
            }
        }
        null
    } catch (e: Exception) {
        null
    }
}

/** Convenience for a sender-side test from the phone (not used by the UI yet). */
fun sendFilesTo(paths: List<File>, host: String, port: Int, name: String, log: (String) -> Unit) {
    val sock = Socket()
    sock.tcpNoDelay = true
    sock.connect(InetSocketAddress(host, port), 5_000)
    val input = DataInputStream(BufferedInputStream(sock.getInputStream(), 1 shl 16))
    val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1 shl 16))

    val hello = JSONObject()
    hello.put("type", "hello")
    hello.put("version", Protocol.VERSION)
    hello.put("name", name)
    hello.put("streams", 1)
    Protocol.writeMessage(out, hello)
    val ready = ControlMsg(Protocol.readMessage(input)!!)
    if (ready.type != "ready") throw IllegalStateException("expected ready")

    for (file in paths) {
        val transferId = Protocol.newTransferId()
        val offer = JSONObject()
        offer.put("type", "offer")
        offer.put("transferId", transferId)
        offer.put("path", file.name)
        offer.put("size", file.length())
        offer.put("sha256", Protocol.sha256(file))
        Protocol.writeMessage(out, offer)

        val resp = ControlMsg(Protocol.readMessage(input)!!)
        if (!resp.accept) {
            log("receiver declined ${file.name}")
            continue
        }
        val offset = resp.offset
        if (offset < file.length()) {
            FileInputStream(file).use { fis ->
                fis.channel.position(offset)
                val buf = ByteArray(1 shl 18)
                var written = offset
                while (written < file.length()) {
                    val want = minOf(buf.size.toLong(), file.length() - written).toInt()
                    val n = fis.read(buf, 0, want)
                    if (n < 0) break
                    sock.getOutputStream().write(buf, 0, n)
                    written += n
                }
                sock.getOutputStream().flush()
            }
        }
        val done = ControlMsg(Protocol.readMessage(input)!!)
        if (!done.ok) throw IllegalStateException("verify failed for ${file.name}: ${done.message}")
        log("sent ${file.name}")
    }
    sock.close()
}
