package com.hypersend.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.Environment
import android.os.IBinder
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class ReceiveService : Service() {

    inner class LocalBinder : Binder() {
        val service: ReceiveService get() = this@ReceiveService
    }

    private val binder = LocalBinder()
    private val running = AtomicBoolean(false)
    private var thread: Thread? = null

    @Volatile var listener: (() -> Unit)? = null
    @Volatile var ipAddress: String? = null
        private set
    @Volatile var deviceName: String = "android"
        private set
    @Volatile var isRunning: Boolean = false
        private set
    var engine: ReceiverEngine? = null
        private set

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundInternal()
        if (!running.get()) startEngine()
        return START_STICKY
    }

    private fun startForegroundInternal() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel("rx", "Receiving", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification: Notification =
            if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(this, "rx")
                    .setContentTitle("HyperSend ready")
                    .setContentText("Waiting for senders on this Wi-Fi")
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setOngoing(true)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
                    .setContentTitle("HyperSend ready")
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .build()
            }
        startForeground(1, notification)
    }

    private fun startEngine() {
        running.set(true)
        val dest = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "HyperSend",
        )
        dest.mkdirs()
        deviceName = Build.MODEL.take(24).ifEmpty { "android" }
        ipAddress = localIpAddress()

        val eng = ReceiverEngine(
            destDir = dest,
            port = Protocol.DEFAULT_PORT,
            deviceName = deviceName,
            running = running,
            log = { msg -> android.util.Log.i("HyperSend", msg) },
            onStateChange = { listener?.invoke() },
        )
        engine = eng
        isRunning = true
        listener?.invoke()
        thread = Thread {
            try {
                eng.start()
            } catch (e: Exception) {
                android.util.Log.e("HyperSend", "engine died: ${e.message}")
            } finally {
                isRunning = false
                running.set(false)
                listener?.invoke()
            }
        }.apply { isDaemon = true; start() }
    }

    private fun stopEngine() {
        running.set(false)
        engine?.stop()
        thread?.interrupt()
        thread = null
        engine = null
        isRunning = false
        listener?.invoke()
    }

    fun setRunning(value: Boolean) {
        if (!value) stopEngine()
    }

    override fun onDestroy() {
        stopEngine()
        super.onDestroy()
    }
}
