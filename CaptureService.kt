package com.bloxtrade.capture

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.*
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.*
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs

class CaptureService : Service() {
    companion object {
        const val ACTION_START = "com.bloxtrade.capture.START"
        const val ACTION_STOP = "com.bloxtrade.capture.STOP"
        private const val CHANNEL = "blox_capture"
        private const val GRID = 32
        @Volatile var running = false
        @Volatile var instance: CaptureService? = null
        var scalePct = 50
        var intervalMs = 500
        var minChangedCells = 3
        private var title = "Blox Trade AI"
        private var body = "Capturing."
        private var color = "#FFD700"

        fun setOverlay(t: String, b: String, c: String) {
            title = t; body = b; color = c
            instance?.main?.post { instance?.renderOverlay() }
        }
    }

    val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var prev: IntArray? = null
    private var lastProcessed = 0L
    @Volatile private var paused = false
    @Volatile private var closing = false

    private var wm: WindowManager? = null
    private var overlay: LinearLayout? = null
    private var lp: WindowManager.LayoutParams? = null
    private var titleTv: TextView? = null
    private var bodyTv: TextView? = null
    private var buttons: LinearLayout? = null
    private var pauseBtn: Button? = null
    private var expanded = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> shutdown("stopped")
            ACTION_START -> startCapture(intent)
        }
        return START_NOT_STICKY
    }

    private fun startCapture(intent: Intent) {
        if (running) return
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Screen analysis", NotificationManager.IMPORTANCE_LOW))
        val stopPi = PendingIntent.getService(this, 0,
            Intent(this, CaptureService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val notif = Notification.Builder(this, CHANNEL)
            .setContentTitle("Blox Trade AI is capturing your screen")
            .setContentText("Analysis runs on this device. Tap Stop to end.")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(this, android.R.drawable.ic_delete),
                "Stop", stopPi).build())
            .build()
        if (Build.VERSION.SDK_INT >= 29)
            startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        else startForeground(1, notif)

        try {
            val code = intent.getIntExtra("code", 0)
            @Suppress("DEPRECATION")
            val data: Intent? = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra("data", Intent::class.java) else intent.getParcelableExtra("data")
            if (data == null) { shutdown("error:no_projection_data"); return }
            thread = HandlerThread("blox-capture").also { it.start() }
            handler = Handler(thread!!.looper)
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            projection = mpm.getMediaProjection(code, data)
            // Must be registered before createVirtualDisplay on Android 14+.
            projection!!.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() { shutdown("stopped_by_system") }
            }, handler)
            running = true
            instance = this
            setupDisplay()
            main.post { showOverlay() }
            CaptureBus.emit("capture_status", "started")
        } catch (e: Exception) {
            shutdown("error:" + (e.message ?: e.javaClass.simpleName))
        }
    }

    private fun setupDisplay() {
        val dm = resources.displayMetrics
        val w = maxOf(2, dm.widthPixels * scalePct / 100)
        val h = maxOf(2, dm.heightPixels * scalePct / 100)
        reader?.close()
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        r.setOnImageAvailableListener({ onImage(it) }, handler)
        reader = r
        val d = display
        if (d == null) {
            display = projection!!.createVirtualDisplay("BloxCapture", w, h, dm.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, r.surface, null, handler)
        } else {
            d.resize(w, h, dm.densityDpi)
            d.surface = r.surface
        }
        prev = null
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (running && !closing) {
            try { setupDisplay() } catch (e: Exception) { shutdown("error:rotation") }
        }
    }

    private fun onImage(r: ImageReader) {
        var img: android.media.Image? = null
        try {
            img = r.acquireLatestImage() ?: return
            if (paused || closing) return
            val now = SystemClock.elapsedRealtime()
            if (now - lastProcessed < intervalMs) return
            lastProcessed = now
            val p = img.planes[0]
            val pad = p.rowStride - p.pixelStride * img.width
            val full = Bitmap.createBitmap(img.width + pad / p.pixelStride, img.height, Bitmap.Config.ARGB_8888)
            full.copyPixelsFromBuffer(p.buffer)
            val bmp = Bitmap.createBitmap(full, 0, 0, img.width, img.height)
            full.recycle()
            val sample = IntArray(GRID * GRID)
            for (gy in 0 until GRID) for (gx in 0 until GRID) {
                val c = bmp.getPixel(gx * (bmp.width - 1) / (GRID - 1), gy * (bmp.height - 1) / (GRID - 1))
                sample[gy * GRID + gx] = (Color.red(c) * 299 + Color.green(c) * 587 + Color.blue(c) * 114) / 1000
            }
            val old = prev
            var changed = old == null
            if (old != null) {
                var cells = 0
                for (i in sample.indices) if (abs(sample[i] - old[i]) > 24) cells++
                changed = cells >= minChangedCells
            }
            if (changed) {
                prev = sample
                val tmp = File(cacheDir, "frame.tmp")
                FileOutputStream(tmp).use { bmp.compress(Bitmap.CompressFormat.JPEG, 85, it) }
                val out = File(cacheDir, "frame.jpg")
                tmp.renameTo(out)
                CaptureBus.emit("frame_ready", out.absolutePath)
            }
            bmp.recycle()
        } catch (e: Exception) {
            CaptureBus.emit("capture_status", "frame_error")
        } finally {
            img?.close()
        }
    }

    fun shutdown(reason: String) {
        if (closing) return
        closing = true
        running = false
        instance = null
        try { display?.release() } catch (_: Exception) {}
        try { reader?.close() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        display = null; reader = null; projection = null
        main.post { removeOverlay() }
        File(cacheDir, "frame.jpg").delete()
        File(cacheDir, "frame.tmp").delete()
        thread?.quitSafely()
        CaptureBus.emit("capture_status", reason)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (!closing) shutdown("stopped")
        super.onDestroy()
    }

    // ---------- Overlay ----------
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun showOverlay() {
        if (!Settings.canDrawOverlays(this) || overlay != null) return
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), dp(8), dp(10), dp(8))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#E60B2A4A")); cornerRadius = dp(14).toFloat()
                setStroke(dp(2), Color.parseColor("#FFD700"))
            }
        }
        titleTv = TextView(this).apply { setTextColor(Color.WHITE); textSize = 14f }
        bodyTv = TextView(this).apply { setTextColor(Color.WHITE); textSize = 12f; maxWidth = dp(220) }
        pauseBtn = Button(this).apply {
            text = "Pause"; textSize = 11f
            setOnClickListener {
                paused = !paused
                text = if (paused) "Resume" else "Pause"
                CaptureBus.emit("capture_status", if (paused) "paused" else "resumed")
            }
        }
        val stopBtn = Button(this).apply { text = "Stop"; textSize = 11f; setOnClickListener { shutdown("stopped") } }
        buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; visibility = View.GONE
            addView(pauseBtn); addView(stopBtn)
        }
        root.addView(titleTv); root.addView(bodyTv); root.addView(buttons)
        bodyTv!!.visibility = View.GONE

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT).apply { gravity = Gravity.TOP or Gravity.START; x = dp(8); y = dp(120) }
        lp = params

        var sx = 0f; var sy = 0f; var ox = 0; var oy = 0; var moved = false
        root.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> { sx = e.rawX; sy = e.rawY; ox = params.x; oy = params.y; moved = false }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (e.rawX - sx).toInt(); val dy = (e.rawY - sy).toInt()
                    if (abs(dx) > dp(6) || abs(dy) > dp(6)) moved = true
                    if (moved) { params.x = ox + dx; params.y = oy + dy; wm?.updateViewLayout(root, params) }
                }
                MotionEvent.ACTION_UP -> if (!moved) {
                    expanded = !expanded
                    bodyTv?.visibility = if (expanded) View.VISIBLE else View.GONE
                    buttons?.visibility = if (expanded) View.VISIBLE else View.GONE
                    wm?.updateViewLayout(root, params)
                }
            }
            true
        }
        overlay = root
        wm!!.addView(root, params)
        renderOverlay()
    }

    private fun renderOverlay() {
        val ov = overlay ?: return
        titleTv?.text = title
        bodyTv?.text = body
        try { titleTv?.setTextColor(Color.parseColor(color)) } catch (_: Exception) {}
        wm?.updateViewLayout(ov, lp)
    }

    private fun removeOverlay() {
        overlay?.let { try { wm?.removeView(it) } catch (_: Exception) {} }
        overlay = null
    }
}
