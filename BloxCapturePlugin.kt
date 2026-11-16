package com.bloxtrade.capture

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

class BloxCapturePlugin(godot: Godot) : GodotPlugin(godot) {
    private val reqCapture = 7421

    init {
        CaptureBus.listener = { signal, arg -> emitSignal(signal, arg) }
    }

    override fun getPluginName() = "BloxCapture"

    override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
        SignalInfo("capture_status", String::class.java),
        SignalInfo("frame_ready", String::class.java)
    )

    @UsedByGodot fun hasOverlayPermission(): Boolean {
        val a = activity ?: return false
        return Settings.canDrawOverlays(a)
    }

    @UsedByGodot fun requestOverlayPermission() {
        val a = activity ?: return
        a.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:" + a.packageName)))
    }

    @UsedByGodot fun requestNotificationPermission() {
        val a = activity ?: return
        if (Build.VERSION.SDK_INT >= 33) {
            a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7422)
        }
    }

    /** scalePct: capture size as % of screen. intervalMs: min time between processed frames.
     *  minChangedCells: how many of the 32x32 sample cells must change to count as a change. */
    @UsedByGodot fun requestCapture(scalePct: Int, intervalMs: Int, minChangedCells: Int) {
        val a = activity ?: return
        CaptureService.scalePct = scalePct.coerceIn(10, 100)
        CaptureService.intervalMs = intervalMs.coerceIn(100, 10000)
        CaptureService.minChangedCells = minChangedCells.coerceAtLeast(1)
        val mpm = a.getSystemService(MediaProjectionManager::class.java)
        a.startActivityForResult(mpm.createScreenCaptureIntent(), reqCapture)
    }

    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != reqCapture) return
        val a = activity ?: return
        if (resultCode == Activity.RESULT_OK && data != null) {
            val i = Intent(a, CaptureService::class.java)
                .setAction(CaptureService.ACTION_START)
                .putExtra("code", resultCode)
                .putExtra("data", data)
            a.startForegroundService(i)
        } else {
            CaptureBus.emit("capture_status", "permission_denied")
        }
    }

    @UsedByGodot fun stopCapture() { CaptureService.instance?.shutdown("stopped") }
    @UsedByGodot fun isCapturing(): Boolean = CaptureService.running
    @UsedByGodot fun setOverlay(title: String, body: String, colorHex: String) {
        CaptureService.setOverlay(title, body, colorHex)
    }

    // ---- market data background sync (WorkManager) ----
    /** Schedules a periodic, battery-friendly download of the market feed. Android decides the exact
     *  run time (minimum interval 15 min). The app re-validates everything the worker saves. */
    @UsedByGodot fun scheduleMarketSync(url: String, minutes: Int) {
        val a = activity ?: return
        MarketSyncWorker.schedule(a.applicationContext, url, minutes.toLong().coerceAtLeast(15))
    }
    @UsedByGodot fun cancelMarketSync() {
        val a = activity ?: return
        MarketSyncWorker.cancel(a.applicationContext)
    }
    /** Returns the last downloaded feed text, or "" if none. */
    @UsedByGodot fun readMarketSnapshot(): String {
        val a = activity ?: return ""
        return MarketSyncWorker.read(a.applicationContext)
    }
    @UsedByGodot fun clearMarketSnapshot() {
        val a = activity ?: return
        MarketSyncWorker.clear(a.applicationContext)
    }
}
