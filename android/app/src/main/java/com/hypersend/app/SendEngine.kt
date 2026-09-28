package com.hypersend.app

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Multipath sender — the Kotlin twin of mac/Sources/Engine/Sender.swift.
 *
 * A file is a list of fixed-size chunks. One shared offset cursor, one worker
 * per data socket. Fast lanes simply pull more chunks — there is no scheduler
 * to tune and no bandwidth estimate to get wrong — and the receiver reassembles
 * by file offset, so chunk order and provenance never matter.
 *
 * Wire contract (must stay byte-identical with Swift and Node):
 *   control :44010           [4-byte BE len][JSON]
 *   data    :<ready.dataPort>[4-byte BE len][1B flags=0x01][8-byte BE offset][payload]
 *   hello → ready · offer → offer-response · chunk pump · file-sent → file-done · batch-done
 *
 * Lanes are deliberately address-agnostic: each lane carries a LIST of hosts
 * (the Mac's global IPv6 + its IPv4, say), and [Net.connect] walks them
 * best-first with per-family fallback. The USB cable is just another lane
 * whose host is 127.0.0.1 through the adb reverse tunnel — which is why
 * cable + Wi-Fi bond with zero scheduling.
 */
class SendEngine(
    private val running: AtomicBoolean,
    private val log: (String) -> Unit,
    private val onStateChange: () -> Unit,
) {

    /** One transport path into the same receiver. */
    data class Lane(
        val label: String,
        /** Every address that might reach this lane; tried best-first. */
        val hosts: List<String>,
        /** null = use the data port the receiver advertises (normal Wi-Fi). */
        val port: Int? = null,
    )

    class LaneReport {
        @Volatile var bytes: Long = 0
        @Volatile var chunks: Long = 0
    }

    class Progress(
        val fileName: String,
        val fileIndex: Int,
        val fileCount: Int,
        val bytesDone: Long,
        val bytesTotal: Long,
        val laneBytes: Map<String, Long>,
        val seconds: Double,
    ) {
        val bytesPerSec: Double get() = if (seconds > 0) bytesDone / seconds else 0.0
        val fraction: Double get() = if (bytesTotal > 0) minOf(1.0, bytesDone.toDouble() / bytesTotal) else 0.0
    }

    class Summary(
        val files: Int,
        /** Offers the receiver said no to; a decision, not a failure. */
        val declined: Int = 0,
        val bytes: Long,
        val seconds: Double,
        val lanes: Map<String, LaneReport>,
    ) {
        val bytesPerSec: Double get() = if (seconds > 0) bytes.toDouble() / seconds else 0.0
    }

    // All mutable engine state behind one lock; chunk workers hammer this.
    private val lock = Object()
    private val laneStats = LinkedHashMap<String, LaneReport>()
    private var transmitted = 0L
    private var cancelled = false
    private var lastEmit = 0L

    @Volatile var activeFileName: String = ""
        private set
    @Volatile var activeFraction = 0.0
        private set
    @Volatile var lastSummary: Summary? = null
        private set

    fun cancel() {
        synchronized(lock) { cancelled = true }
    }

    val isCancelled: Boolean
        get() = synchronized(lock) { cancelled }

    private fun addBytes(bytes: Int) {
        synchronized(lock) { transmitted += bytes }
    }

    private fun laneSnapshot(): Map<String, Long> = synchronized(lock) {
        val out = LinkedHashMap<String, Long>(laneStats.size)
        for ((k, v) in laneStats) out[k] = v.bytes
        out
    }

    /**
     * Sends `files` to one receiver over `lanes`. Blocking — call it off the
     * main thread. `destPaths` optionally overrides each file's destination
     * path (how a folder send preserves its structure); when given it must be
     * the same length as `files`.
     */
    fun send(
        files: List<File>,
        destPaths: List<String>? = null,
        lanes: List<Lane>,
        controlPort: Int = Protocol.DEFAULT_PORT,
        socketsPerLane: Int = 2,
        progress: ((Progress) -> Unit)? = null,
    ): Summary {
        require(destPaths == null || destPaths.size == files.size) {
            "destPaths (${destPaths?.size}) and files (${files.size}) disagree"
        }
        require(lanes.isNotEmpty()) { "no lanes given" }

        synchronized(lock) {
            cancelled = false
            laneStats.clear()
            transmitted = 0
            lastEmit = 0
            lastSummary = null
        }
        activeFileName = ""
        activeFraction = 0.0
        val started = System.currentTimeMillis()

        val sizes = files.map { it.length() }
        val totalBytes = sizes.sum()

        val control: Socket = Net.connect(lanes.first().hosts, controlPort, 6_000)
        val dataSockets = ArrayList<Socket>()
        try {
            control.tcpNoDelay = true
            val input = DataInputStream(BufferedInputStream(control.getInputStream(), 1 shl 16))
            val out = DataOutputStream(BufferedOutputStream(control.getOutputStream(), 1 shl 16))

            // ── hello → ready ───────────────────────────────────────────────
            val hello = JSONObject()
            hello.put("type", "hello")
            hello.put("version", Protocol.VERSION)
            hello.put("name", deviceName())
            hello.put("chunkSize", Protocol.CHUNK_SIZE)
            Protocol.writeMessage(out, hello)

            val dataPort = awaitReady(control, input)
            log("receiver ready · data plane :$dataPort")

            // ── data sockets, one pool reused for every file in the batch ──
            val workers: List<Pair<String, Socket>> = buildList {
                for (lane in lanes) {
                    val port = lane.port ?: dataPort
                    var opened = 0
                    repeat(maxOf(1, socketsPerLane)) {
                        // A lane that will not open must not kill the transfer:
                        // losing the cable should just mean a slower send.
                        try {
                            add(lane.label to Net.connect(lane.hosts, port, 3_000))
                            opened += 1
                        } catch (e: Exception) {
                            log("lane ${lane.label} on :$port unavailable — ${e.message ?: "refused"}")
                        }
                    }
                }
            }
            check(workers.isNotEmpty()) { "no data lanes could be opened" }
            dataSockets.addAll(workers.map { it.second })
            log("data lanes: " + workers.map { it.first }.distinct().joinToString(" + ") + " ×${socketsPerLane}")

            // ── per-file transfer ───────────────────────────────────────────
            var filesDone = 0
            var declinedFiles = 0
            for ((index, file) in files.withIndex()) {
                if (isCancelled) break
                val size = sizes[index]
                val displayName = destPaths?.get(index) ?: file.name
                // The receiver hashes the WHOLE file (resume prefix included),
                // so the offer digest must cover all of it — same as the Mac.
                val digest = Protocol.sha256(file)
                val transferId = UUID.randomUUID().toString()

                val offer = JSONObject()
                offer.put("type", "offer")
                offer.put("transferId", transferId)
                offer.put("path", displayName)
                offer.put("size", size)
                offer.put("sha256", digest)
                Protocol.writeMessage(out, offer)

                // null = declined: skip the file and keep the batch alive —
                // the same semantic the Node engine honours and the Mac sender
                // now matches. One decline used to abort the whole batch.
                val offset = awaitOfferResponse(control, input, transferId, size)
                if (offset == null) {
                    log("declined $displayName — skipping")
                    declinedFiles++
                    continue
                }
                if (offset > 0) log("resuming $displayName at ${Protocol.humanBytes(offset)}")

                if (size > offset && !isCancelled) {
                    pumpChunks(
                        file = file,
                        displayName = displayName,
                        from = offset,
                        size = size,
                        workers = workers,
                        fileIndex = index + 1,
                        fileCount = files.count(),
                        bytesTotal = totalBytes,
                        startedMs = started,
                        progress = progress,
                    )
                }

                val sent = JSONObject()
                sent.put("type", "file-sent")
                sent.put("transferId", transferId)
                Protocol.writeMessage(out, sent)
                awaitFileDone(control, input, transferId)

                filesDone += 1
                log("verified $displayName · sha256 ok")
                emit(displayName, index + 1, files.count(), totalBytes, started, progress, force = true)
            }

            val seconds = (System.currentTimeMillis() - started) / 1000.0
            val batch = JSONObject()
            batch.put("type", "batch-done")
            batch.put("files", filesDone)
            batch.put("bytes", synchronized(lock) { transmitted })
            batch.put("elapsedMs", (seconds * 1000).toLong())
            Protocol.writeMessage(out, batch)

            val lanesOut = synchronized(lock) { LinkedHashMap(laneStats) }
            val summary = Summary(filesDone, declinedFiles, synchronized(lock) { transmitted }, seconds, lanesOut)
            lastSummary = summary
            return summary
        } finally {
            for (s in dataSockets) {
                try { s.close() } catch (ignored: Exception) {}
            }
            try { control.close() } catch (ignored: Exception) {}
            activeFileName = ""
            onStateChange()
        }
    }

    private fun deviceName(): String =
        android.os.Build.MODEL.take(24).ifEmpty { "android" }

    // ── Control handshakes ──────────────────────────────────────────────

    /**
     * Reads one control frame with a 1 s poll so cancel stays responsive.
     * The short soTimeout is invisible to the peer — TCP buffering means a
     * frame that arrives mid-poll is simply read on the next pass.
     */
    private fun readMsg(socket: Socket, input: DataInputStream, deadlineMs: Long): ControlMsg {
        while (true) {
            if (isCancelled) throw IOException("cancelled")
            val remaining = deadlineMs - System.currentTimeMillis()
            if (remaining <= 0) throw IOException("timed out waiting for receiver")
            socket.soTimeout = minOf(1_000L, remaining).toInt()
            try {
                return ControlMsg(
                    Protocol.readMessage(input)
                        ?: throw IOException("receiver closed the control channel"),
                )
            } catch (e: SocketTimeoutException) {
                // poll again — deadline and cancel checked above
            }
        }
    }

    private fun awaitReady(socket: Socket, input: DataInputStream): Int {
        val deadline = System.currentTimeMillis() + 15_000
        while (true) {
            val msg = readMsg(socket, input, deadline)
            when (msg.type) {
                "ready" -> {
                    val port = msg.raw.optInt("dataPort", -1)
                    if (port !in 1..65535) throw IOException("receiver advertised a bad data port")
                    return port
                }
                "error" -> throw IOException("receiver: ${msg.message}")
            }
        }
    }

    /** null = the receiver declined; the caller decides skip vs abort. */
    private fun awaitOfferResponse(socket: Socket, input: DataInputStream, transferId: String, size: Long): Long? {
        // Generous on purpose: the Mac receiver may put this offer in front of
        // a person when auto-accept is off, and the answer takes as long as a
        // person takes.
        val deadline = System.currentTimeMillis() + 120_000
        while (true) {
            val msg = readMsg(socket, input, deadline)
            if (msg.transferId != transferId) continue
            when (msg.type) {
                "offer-response" -> {
                    if (!msg.accept) return null
                    return minOf(size, maxOf(0L, msg.offset))
                }
                "error" -> throw IOException("receiver: ${msg.message}")
            }
        }
    }

    private fun awaitFileDone(socket: Socket, input: DataInputStream, transferId: String) {
        // The receiver hashes the whole file on disk before answering, so this
        // window is generous.
        val deadline = System.currentTimeMillis() + 900_000
        while (true) {
            val msg = readMsg(socket, input, deadline)
            if (msg.transferId != transferId) continue
            when (msg.type) {
                "file-done" -> {
                    if (!msg.ok) {
                        val why = msg.raw.optString("error").ifEmpty { msg.message }
                        throw IOException("verification failed: $why")
                    }
                    return
                }
                "error" -> throw IOException("receiver: ${msg.message}")
            }
        }
    }

    // ── Chunk pump ──────────────────────────────────────────────────────

    /**
     * Streams [from, size) of the file through every socket. One shared offset
     * cursor under a lock; whoever finishes a chunk first takes the next. Each
     * worker owns its own RandomAccessFile — seek+read is not thread-safe on a
     * shared handle — and writes 13-byte-header + payload straight through.
     */
    private fun pumpChunks(
        file: File,
        displayName: String,
        from: Long,
        size: Long,
        workers: List<Pair<String, Socket>>,
        fileIndex: Int,
        fileCount: Int,
        bytesTotal: Long,
        startedMs: Long,
        progress: ((Progress) -> Unit)?,
    ) {
        val queueLock = Object()
        var nextOffset = from
        var firstError: Throwable? = null
        val chunkSize = Protocol.CHUNK_SIZE

        val threads = workers.map { (label, socket) ->
            Thread {
                val buf = ByteArray(chunkSize)
                var raf: RandomAccessFile? = null
                try {
                    raf = RandomAccessFile(file, "r")
                    val out = socket.getOutputStream()
                    val frame = ByteArray(13)
                    while (true) {
                        if (isCancelled) return@Thread
                        val start: Long
                        synchronized(queueLock) {
                            if (firstError != null || nextOffset >= size) return@Thread
                            start = nextOffset
                            nextOffset += chunkSize
                        }
                        val length = minOf(chunkSize.toLong(), size - start).toInt()
                        try {
                            raf.seek(start)
                            raf.readFully(buf, 0, length)
                        } catch (e: Throwable) {
                            synchronized(queueLock) { if (firstError == null) firstError = e }
                            return@Thread
                        }
                        // Length field covers flags + offset + payload = 9 + n.
                        putInt(frame, 0, 9 + length)
                        frame[4] = 0x01
                        putLong(frame, 5, start)
                        try {
                            out.write(frame)
                            out.write(buf, 0, length)
                            out.flush()
                        } catch (e: Throwable) {
                            synchronized(queueLock) { if (firstError == null) firstError = e }
                            return@Thread
                        }
                        record(label, length)
                        addBytes(length)
                        emit(displayName, fileIndex, fileCount, bytesTotal, startedMs, progress, force = false)
                    }
                } catch (e: Throwable) {
                    synchronized(queueLock) { if (firstError == null) firstError = e }
                } finally {
                    try { raf?.close() } catch (ignored: Exception) {}
                }
            }.apply {
                isDaemon = true
                name = "hypersend.tx.$label"
                start()
            }
        }

        threads.forEach { it.join() }
        synchronized(queueLock) { firstError?.let { throw it } }
        if (isCancelled) throw IOException("cancelled")
    }

    // ── Stats & reporting ───────────────────────────────────────────────

    private fun record(lane: String, bytes: Int) {
        synchronized(lock) {
            val stat = laneStats.getOrPut(lane) { LaneReport() }
            stat.bytes += bytes
            stat.chunks += 1
        }
    }

    /// Throttled to ~8 Hz unless `force` (end of a file). Mirrors the Mac.
    private fun emit(
        fileName: String,
        fileIndex: Int,
        fileCount: Int,
        bytesTotal: Long,
        startedMs: Long,
        progress: ((Progress) -> Unit)?,
        force: Boolean,
    ) {
        if (progress == null) return
        val now = System.currentTimeMillis()
        synchronized(lock) {
            if (!force && now - lastEmit < 125) return
            lastEmit = now
        }
        val done = synchronized(lock) { transmitted }
        activeFileName = fileName
        activeFraction = if (bytesTotal > 0) minOf(1.0, done.toDouble() / bytesTotal) else 0.0
        progress(Progress(
            fileName = fileName,
            fileIndex = fileIndex,
            fileCount = fileCount,
            bytesDone = done,
            bytesTotal = bytesTotal,
            laneBytes = laneSnapshot(),
            seconds = (now - startedMs) / 1000.0,
        ))
        onStateChange()
    }

    private fun putInt(b: ByteArray, off: Int, v: Int) {
        b[off] = (v ushr 24).toByte()
        b[off + 1] = (v ushr 16).toByte()
        b[off + 2] = (v ushr 8).toByte()
        b[off + 3] = v.toByte()
    }

    private fun putLong(b: ByteArray, off: Int, v: Long) {
        for (i in 0 until 8) b[off + i] = (v ushr ((7 - i) * 8)).toByte()
    }
}
