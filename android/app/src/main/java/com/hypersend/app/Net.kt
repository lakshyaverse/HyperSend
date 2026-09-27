package com.hypersend.app

import android.content.Context
import android.net.wifi.WifiManager
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Dual-stack networking (IPv4 + IPv6), with best-first addressing.
 *
 * The rule the whole app follows: have BOTH families everywhere, and use the
 * best one that actually works. Concretely:
 *
 *  - every address list is ranked (global v6 > IPv4 > v6 ULA > v6 link-local
 *    > loopback) and connects walk that order with a short per-attempt
 *    budget, so a router advertising broken AAAA records costs 750 ms, not
 *    the transfer;
 *  - beacons go out as IPv4 broadcast AND IPv6 link-local multicast, and the
 *    watcher listens on both families;
 *  - nothing here touches the proven receive path (ReceiverEngine still owns
 *    its own sockets) — this file only serves NEW code.
 *
 * Zero dependencies, like the rest of the app.
 */
object Net {

    // ── Address ranking ──────────────────────────────────────────────────

    /** Candidate quality. Lower sorts first; ties keep resolver order. */
    fun rank(addr: InetAddress): Int {
        if (addr is Inet4Address) {
            return if (addr.isLoopbackAddress) 5 else 1
        }
        if (addr is Inet6Address) {
            return when {
                addr.isLoopbackAddress -> 5
                isUniqueLocal(addr) -> 2          // fc00::/7
                addr.isLinkLocalAddress -> 3      // fe80::/10 (needs a scope)
                else -> 0                          // global v6 — the best there is
            }
        }
        return 4
    }

    private fun isUniqueLocal(a: Inet6Address): Boolean {
        val b = a.address
        return b.isNotEmpty() && (b[0].toInt() and 0xFE) == 0xFC
    }

    /** All addresses for a host, ranked best-first, loopback last. */
    fun candidates(host: String): List<InetAddress> {
        return try {
            val found = InetAddress.getAllByName(host) ?: return emptyList()
            found
                .filter { !it.isMulticastAddress }
                .distinctBy { it.hostAddress }
                .sortedBy { rank(it) }
        } catch (e: Exception) {
            emptyList()
        }
    }

    // ── TCP connect ──────────────────────────────────────────────────────

    /**
     * Connects to the first address that answers, walking every family of
     * every host best-first. Each attempt gets its own slice of `timeoutMs`
     * (capped at 750 ms) so a dead candidate cannot eat the whole budget.
     */
    fun connect(hosts: List<String>, port: Int, timeoutMs: Int = 5_000): Socket {
        val addrs = hosts.flatMap { candidates(it) }.distinctBy { it.hostAddress }
        if (addrs.isEmpty()) throw IOException("no addresses for $hosts")

        val perAttempt = minOf(750, (timeoutMs / addrs.size).coerceAtLeast(300))
        val started = System.currentTimeMillis()
        val failures = StringBuilder()

        for (addr in addrs) {
            val remaining = timeoutMs - (System.currentTimeMillis() - started)
            if (remaining <= 0) break
            val s = Socket()
            try {
                s.tcpNoDelay = true
                s.connect(InetSocketAddress(addr, port), minOf(perAttempt, remaining.toInt()))
                return s
            } catch (e: Exception) {
                failures.append("${addr.hostAddress}: ${e.message ?: "refused"}; ")
                try { s.close() } catch (ignored: Exception) {}
            }
        }
        throw IOException("connect $hosts:$port failed — $failures")
    }

    /** Cheap liveness probe (is this lane's port even open?). */
    fun probe(host: String, port: Int, timeoutMs: Int = 700): Boolean {
        val s = Socket()
        return try {
            s.tcpNoDelay = true
            s.connect(InetSocketAddress(host, port), timeoutMs)
            s.close()
            true
        } catch (e: Exception) {
            try { s.close() } catch (ignored: Exception) {}
            false
        }
    }

    // ── Local addresses ──────────────────────────────────────────────────

    data class LocalAddress(val iface: String, val address: String, val inet: InetAddress) {
        val isV6: Boolean get() = inet is Inet6Address
    }

    /** Every IPv4 + IPv6 address this device holds, with interface names. */
    fun localAddresses(): List<LocalAddress> {
        val out = ArrayList<LocalAddress>()
        try {
            val eni = NetworkInterface.getNetworkInterfaces() ?: return out
            while (eni.hasMoreElements()) {
                val nif = eni.nextElement()
                if (!nif.isUp || nif.isLoopback) continue
                for (addr in nif.inetAddresses) {
                    if (addr.isLoopbackAddress) continue
                    if (addr is Inet4Address || addr is Inet6Address) {
                        out.add(LocalAddress(nif.name, addr.hostAddress ?: continue, addr))
                    }
                }
            }
        } catch (e: Exception) {
            // best effort — the UI degrades to "address unknown"
        }
        return out.sortedWith(compareBy({ it.iface }, { rank(it.inet) }))
    }

    // ── Beacon TX: IPv6 multicast (the v4 broadcast lives in Protocol.kt) ─

    /** Fires one beacon copy to ff02::1 (all nodes) on every multicast v6 iface. */
    fun sendV6Multicast(payload: ByteArray) {
        try {
            val target = InetSocketAddress(InetAddress.getByName("ff02::1"), Protocol.DISCOVERY_PORT)
            val eni = NetworkInterface.getNetworkInterfaces() ?: return
            while (eni.hasMoreElements()) {
                val nif = eni.nextElement()
                if (!nif.isUp || nif.isLoopback || !nif.supportsMulticast()) continue
                if (nif.inetAddresses.toList().none { it is Inet6Address }) continue
                val s = DatagramSocket(null)
                try {
                    s.reuseAddress = true
                    val idx = nif.index
                    if (idx != 0) {
                        // Scope the all-nodes address to this interface.
                        val scoped = InetSocketAddress(
                            Inet6Address.getByAddress("ff02::1", target.address.address, idx),
                            Protocol.DISCOVERY_PORT,
                        )
                        s.send(DatagramPacket(payload, payload.size, scoped))
                    } else {
                        s.send(DatagramPacket(payload, payload.size, target))
                    }
                } catch (e: Exception) {
                    // an iface without v6 connectivity just doesn't send — fine
                } finally {
                    try { s.close() } catch (ignored: Exception) {}
                }
            }
        } catch (e: Exception) {
            // no v6 on this device at all — the v4 broadcast still goes out
        }
    }

    // ── Beacon RX: dual-family discovery watcher ─────────────────────────

    data class PeerRec(
        val name: String,
        val host: String,
        val port: Int,
        @Volatile var lastSeen: Long,
    )

    /**
     * Listens for HyperSend beacons on BOTH families (:44011 v4 broadcast +
     * v6 multicast) and keeps a fresh peer table. Own beacons are dropped by
     * source address, the same self-filter the Mac applies.
     */
    class BeaconWatcher(
        private val ownHosts: () -> Set<String>,
        private val onPeers: () -> Unit,
    ) {
        private val running = AtomicBoolean(false)
        private var v4: DatagramSocket? = null
        private var v6: DatagramSocket? = null
        private var thread: Thread? = null
        private val lock = Object()
        private val peers = LinkedHashMap<String, PeerRec>()

        fun start() {
            if (running.getAndSet(true)) return
            v4 = bindUdp("0.0.0.0", Protocol.DISCOVERY_PORT)
            v6 = bindUdp("::", Protocol.DISCOVERY_PORT)   // null when no v6 — fine
            val buf = ByteArray(2048)
            thread = Thread {
                val sockets = listOfNotNull(v4, v6)
                while (running.get()) {
                    var got = false
                    for (s in sockets) {
                        try {
                            s.soTimeout = 200
                            val p = DatagramPacket(buf, buf.size)
                            s.receive(p)
                            if (handle(p)) got = true
                        } catch (e: SocketTimeoutException) {
                            // next socket
                        } catch (e: Exception) {
                            if (!running.get()) return@Thread
                        }
                    }
                    if (got) onPeers()
                }
            }.apply { isDaemon = true; name = "hypersend.discovery"; start() }
        }

        private fun bindUdp(host: String, port: Int): DatagramSocket? {
            return try {
                val s = DatagramSocket(null)
                s.reuseAddress = true
                s.bind(InetSocketAddress(InetAddress.getByName(host), port))
                s.broadcast = true
                s
            } catch (e: Exception) {
                null
            }
        }

        /** Returns true when the packet changed the peer table. */
        private fun handle(p: DatagramPacket): Boolean {
            val decoded = Protocol.decodeBeacon(p.data.copyOf(p.length)) ?: return false
            val (name, port) = decoded
            val host = p.address.hostAddress ?: return false
            if (host == "0.0.0.0" || host == "::") return false
            if (host in ownHosts() || host == "127.0.0.1" || host == "::1") return false
            val key = "$host:$port"
            var changed = false
            synchronized(lock) {
                val existing = peers[key]
                if (existing == null) {
                    peers[key] = PeerRec(name, host, port, System.currentTimeMillis())
                    changed = true
                } else {
                    existing.lastSeen = System.currentTimeMillis()
                    // name is val — swap the record when the device renamed.
                    if (existing.name != name) {
                        peers[key] = PeerRec(name, host, port, existing.lastSeen)
                        changed = true
                    }
                }
            }
            return changed
        }

        /** Peers seen within `maxAgeMs`, best names first. */
        fun snapshot(maxAgeMs: Long = 4_000): List<PeerRec> {
            val now = System.currentTimeMillis()
            return synchronized(lock) {
                peers.values.filter { now - it.lastSeen <= maxAgeMs }
                    .sortedBy { it.name.lowercase() }
            }
        }

        fun stop() {
            running.set(false)
            try { v4?.close() } catch (ignored: Exception) {}
            try { v6?.close() } catch (ignored: Exception) {}
            v4 = null; v6 = null
        }
    }

    // ── Multicast lock ───────────────────────────────────────────────────

    /**
     * Android filters inbound broadcast/multicast on Wi-Fi unless an app holds
     * a MulticastLock. Without it the phone never hears the Mac's beacon and
     * discovery silently finds nothing.
     */
    fun acquireMulticastLock(context: Context): WifiManager.MulticastLock? {
        return try {
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lock = wm.createMulticastLock("hypersend-discovery")
            lock.setReferenceCounted(false)
            lock.acquire()
            lock
        } catch (e: Exception) {
            null
        }
    }
}
