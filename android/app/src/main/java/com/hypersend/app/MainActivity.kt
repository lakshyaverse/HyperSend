package com.hypersend.app

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView

class MainActivity : Activity() {

    private var service: ReceiveService? = null
    private var bound = false

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = (binder as ReceiveService.LocalBinder).service
            bound = true
            service?.listener = { runOnUiThread { refresh() } }
            refresh()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            bound = false
            service = null
        }
    }

    private lateinit var statusText: TextView
    private lateinit var statsText: TextView
    private lateinit var toggle: Switch

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        statusText = TextView(this).apply { textSize = 18f; setPadding(48, 48, 48, 16) }
        statsText = TextView(this).apply {
            textSize = 14f
            setPadding(48, 0, 48, 32)
            setMonospace()
        }
        toggle = Switch(this).apply {
            text = "  Receive files"
            textSize = 18f
            setPadding(48, 24, 48, 24)
            setOnCheckedChangeListener { _, checked ->
                if (checked) startReceiveService() else stopReceiveService()
            }
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(statusText)
            addView(statsText)
            addView(toggle)
            addView(
                TextView(this@MainActivity).apply {
                    text =
                        "Files arrive in Download/HyperSend.\n\n" +
                            "From your Mac:\n" +
                            "  hypersend send <file> --peer-name <this device>\n\n" +
                            "Both devices must be on the same Wi-Fi network."
                    textSize = 13f
                    setPadding(48, 48, 48, 48)
                },
            )
        }
        setContentView(root)

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private fun TextView.setMonospace() {
        typeface = android.graphics.Typeface.MONOSPACE
    }

    override fun onStart() {
        super.onStart()
        bindService(Intent(this, ReceiveService::class.java), connection, Context.BIND_AUTO_CREATE)
    }

    override fun onStop() {
        super.onStop()
        if (bound) {
            unbindService(connection)
            bound = false
        }
    }

    private fun startReceiveService() {
        val intent = Intent(this, ReceiveService::class.java)
        startForegroundService(intent)
    }

    private fun stopReceiveService() {
        stopService(Intent(this, ReceiveService::class.java))
        service?.setRunning(false)
    }

    private fun refresh() {
        val svc = service
        val running = svc?.isRunning == true
        if (!running) {
            statusText.text = "HyperSend — receiver is off"
            statsText.text = "Flip the switch to start receiving."
            return
        }
        val ip = svc?.ipAddress ?: "…"
        statusText.text = "✅ Ready — visible as \"${svc?.deviceName ?: ""}\"\nIP: $ip"
        val engine = svc?.engine
        statsText.text = buildString {
            append("received files: ${engine?.receivedCount ?: 0}\n")
            val name = engine?.lastFileName
            if (!name.isNullOrEmpty()) {
                append("now: $name\n")
                append("bytes: ${engine?.lastFileBytes ?: 0} / ${engine?.lastFileTotal ?: 0}\n")
                val mbps = (engine?.bytesPerSec ?: 0) / (1024.0 * 1024.0)
                append("speed: %.1f MB/s".format(mbps))
            } else {
                append("waiting for a sender…")
            }
        }
    }
}
