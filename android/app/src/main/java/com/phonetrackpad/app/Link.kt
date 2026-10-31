package com.phonetrackpad.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import java.io.BufferedOutputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread

/**
 * Connection to the Mac helper. Tries USB first (127.0.0.1 through `adb reverse`), then the
 * chosen Mac on Wi-Fi (found via Bonjour). Reconnects on its own.
 *
 * Pairing: the phone sends its id and secret; a Mac that hasn't approved this phone shows a
 * code and asks its user. Touches are only sent once the Mac has said OK.
 */
class Link(context: Context, private val listener: Listener) {

    interface Listener {
        fun onStatus(text: String, connected: Boolean)
        fun onHaptic()
        fun onNatural(on: Boolean)
        /** Macs found on Wi-Fi changed. [needsChoice]: several found and none chosen yet. */
        fun onMacs(names: List<String>, chosen: String?, needsChoice: Boolean)
    }

    @Volatile var connected = false   // paired and accepting touches
        private set
    @Volatile private var running = false
    @Volatile private var socket: Socket? = null
    private val queue = LinkedBlockingQueue<Out>()
    private val seq = AtomicLong()
    @Volatile private var udp = false
    private val found = ConcurrentHashMap<String, List<InetSocketAddress>>()
    private var lastAnnounced: Pair<List<String>, String?>? = null
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val nsdExecutor = Executors.newSingleThreadExecutor()
    private val infoCallbacks = mutableListOf<NsdManager.ServiceInfoCallback>()
    private var worker: Thread? = null

    private val prefs = context.getSharedPreferences("link", Context.MODE_PRIVATE)
    private val phoneId: String = prefs.getString("phoneId", null)
        ?: UUID.randomUUID().toString().replace("-", "").also { prefs.edit().putString("phoneId", it).apply() }
    private val secret: String = prefs.getString("secret", null)
        ?: ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
            .also { prefs.edit().putString("secret", it).apply() }
    @Volatile var chosenMac: String? = prefs.getString("chosenMac", null)
        private set
    @Volatile private var deniedTarget: String? = null   // a Mac that said no; not retried until chosen again

    fun start() {
        if (running) return
        running = true
        startDiscovery()
        worker = thread(name = "trackpad-link") { loop() }
    }

    fun stop() {
        running = false
        stopDiscovery()
        socket?.close()
        worker?.interrupt()
        worker = null
    }

    /** Use this Mac from now on (reconnects straight away). */
    fun choose(name: String) {
        remember(name)
        deniedTarget = null
        socket?.close()
    }

    private fun remember(name: String) {
        chosenMac = name
        prefs.edit().putString("chosenMac", name).apply()
        lastAnnounced = null
    }

    /**
     * Touch frame body "<ms> <count> ...". On Wi-Fi frames go over UDP so one lost packet
     * can't stall the rest; lifts also go over TCP so a release is never lost.
     * The Mac drops anything older than the newest sequence number it has seen.
     */
    fun sendFrame(body: String, lift: Boolean) {
        if (!connected) return
        queue.offer(Out("T ${seq.incrementAndGet()} $body", tcp = lift || !udp, udp = udp))
    }

    private fun loop() {
        listener.onStatus("Looking for your Mac…", false)
        while (running) {
            announceMacs()
            val targets = mutableListOf<Triple<String, String, InetSocketAddress>>()   // name, via, address
            targets += Triple("USB", "USB", InetSocketAddress("127.0.0.1", PORT))
            val mac = chosenMac ?: found.keys.singleOrNull()
            if (mac != null) {
                found[mac].orEmpty().sortedByDescending { onLocalSubnet(it.address) }
                    .forEach { targets += Triple(mac, "Wi-Fi", it) }
            }
            var pause = 800L
            for ((name, via, addr) in targets) {
                if (!running) break
                if (name == deniedTarget) continue
                val s = Socket()
                try {
                    s.tcpNoDelay = true
                    s.connect(addr, 700)
                } catch (e: IOException) {
                    s.close()
                    continue
                }
                pause = session(s, name, via)
                break
            }
            if (running && !connected) listener.onStatus(idleStatus(), false)
            try { Thread.sleep(pause) } catch (e: InterruptedException) { break }
        }
    }

    private fun idleStatus(): String = when {
        deniedTarget != null -> "This phone wasn't allowed on ${deniedTarget}. Tap with five fingers to choose a Mac."
        chosenMac == null && found.size > 1 -> "Several Macs found. Choose one."
        chosenMac != null && found[chosenMac] == null -> "Looking for $chosenMac…"
        else -> "Looking for your Mac…"
    }

    private fun announceMacs() {
        val names = found.keys.sorted()
        if (lastAnnounced == names to chosenMac) return
        lastAnnounced = names to chosenMac
        listener.onMacs(names, chosenMac, chosenMac == null && names.size > 1)
    }

    /** Returns how long to wait before the next attempt. */
    private fun session(s: Socket, target: String, via: String): Long {
        socket = s
        queue.clear()
        var macName = if (via == "USB") "your Mac" else target
        var pause = 800L
        // adb reverse (USB) only forwards TCP, so UDP is for Wi-Fi only.
        val dgram = if (via == "Wi-Fi") DatagramSocket().apply { connect(s.inetAddress, PORT) } else null
        val reader = thread(name = "trackpad-read") {
            try {
                s.getInputStream().bufferedReader().forEachLine { line ->
                    when {
                        line == "V" -> listener.onHaptic()
                        line.startsWith("N ") -> listener.onNatural(line.endsWith("1"))
                        line.startsWith("M ") -> macName = line.substring(2)
                        line.startsWith("C ") ->
                            listener.onStatus("Allow this phone on $macName. Check the code there: ${line.substring(2)}", false)
                        line == "OK" -> {
                            udp = dgram != null
                            connected = true
                            if (via == "Wi-Fi" && chosenMac != target) remember(target)
                            listener.onStatus("Connected to $macName ($via)", true)
                        }
                        line == "D" -> {
                            deniedTarget = target
                            listener.onStatus("This phone wasn't allowed on $macName. Tap with five fingers to choose a Mac.", false)
                        }
                        line == "B" -> {
                            pause = 3000
                            listener.onStatus("$macName is being used by another phone.", false)
                        }
                    }
                }
            } catch (_: IOException) {
            }
            s.close()
        }
        try {
            val out = BufferedOutputStream(s.getOutputStream(), 16 * 1024)
            out.write("A $phoneId $secret ${Build.MANUFACTURER} ${Build.MODEL}\n".toByteArray())
            out.flush()
            while (running && !s.isClosed) {
                val first = queue.poll(1, TimeUnit.SECONDS)
                if (first == null) {
                    out.write(PING)   // keep-alive, also detects a dead link
                } else {
                    write(first, out, dgram)
                    while (true) write(queue.poll() ?: break, out, dgram)
                }
                out.flush()
            }
        } catch (_: IOException) {
        } catch (_: InterruptedException) {
        } finally {
            connected = false
            udp = false
            dgram?.close()
            s.close()
            reader.join(500)
            socket = null
        }
        return pause
    }

    private fun write(o: Out, out: BufferedOutputStream, dgram: DatagramSocket?) {
        val bytes = o.line.toByteArray()
        if (o.udp && dgram != null) dgram.send(DatagramPacket(bytes, bytes.size))
        if (o.tcp) out.write(bytes)
    }

    private class Out(val line: String, val tcp: Boolean, val udp: Boolean)

    // Bonjour discovery of Macs on the same Wi-Fi.

    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(info: NsdServiceInfo) { Log.d(TAG, "found ${info.serviceName}"); resolve(info) }
        override fun onServiceLost(info: NsdServiceInfo) { found.remove(info.serviceName) }
        override fun onDiscoveryStarted(type: String) { Log.d(TAG, "discovery started") }
        override fun onDiscoveryStopped(type: String) {}
        override fun onStartDiscoveryFailed(type: String, code: Int) { Log.w(TAG, "discovery failed $code") }
        override fun onStopDiscoveryFailed(type: String, code: Int) {}
    }

    private fun startDiscovery() {
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
        } catch (e: Exception) {
            Log.w(TAG, "discovery error", e)
        }
    }

    private fun stopDiscovery() {
        try { nsd.stopServiceDiscovery(discovery) } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= 34) {
            synchronized(infoCallbacks) {
                infoCallbacks.forEach { try { nsd.unregisterServiceInfoCallback(it) } catch (_: Exception) {} }
                infoCallbacks.clear()
            }
        }
    }

    private fun resolve(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= 34) {
            val cb = object : NsdManager.ServiceInfoCallback {
                override fun onServiceUpdated(si: NsdServiceInfo) {
                    val addrs = si.hostAddresses.filterIsInstance<Inet4Address>()
                    Log.d(TAG, "resolved ${si.serviceName} ${si.hostAddresses} port ${si.port}")
                    if (addrs.isNotEmpty()) found[si.serviceName] = addrs.map { InetSocketAddress(it, si.port) }
                }
                override fun onServiceLost() { found.remove(info.serviceName) }
                override fun onServiceInfoCallbackRegistrationFailed(code: Int) { Log.w(TAG, "resolve failed $code") }
                override fun onServiceInfoCallbackUnregistered() {}
            }
            try {
                nsd.registerServiceInfoCallback(info, nsdExecutor, cb)
                synchronized(infoCallbacks) { infoCallbacks.add(cb) }
            } catch (_: Exception) {
            }
        } else {
            @Suppress("DEPRECATION")
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onServiceResolved(si: NsdServiceInfo) {
                    @Suppress("DEPRECATION")
                    found[si.serviceName] = listOf(InetSocketAddress(si.host, si.port))
                }
                override fun onResolveFailed(si: NsdServiceInfo, code: Int) {}
            })
        }
    }

    /** True when [addr] shares a /24 with one of this phone's IPv4 addresses (the Mac may also advertise unreachable ones). */
    private fun onLocalSubnet(addr: InetAddress): Boolean {
        val target = addr.address.takeIf { it.size == 4 } ?: return false
        return try {
            NetworkInterface.getNetworkInterfaces().asSequence().flatMap { it.inetAddresses.asSequence() }
                .filterIsInstance<Inet4Address>()
                .any { it.address.take(3) == target.take(3) && !it.isLoopbackAddress }
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        const val PORT = 9876
        private const val TAG = "TrackpadLink"
        const val SERVICE_TYPE = "_phonetrackpad._tcp"
        private val PING = "P\n".toByteArray()
    }
}
