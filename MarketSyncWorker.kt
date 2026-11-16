package com.bloxtrade.capture

import android.content.Context
import androidx.work.*
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/** Downloads the market feed over HTTPS while the app is closed. It only stores the raw text after a
 *  basic sanity check; the Godot app fully validates it (DataValidator) before using any of it. */
class MarketSyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result {
        val url = inputData.getString("url") ?: return Result.failure()
        if (!url.startsWith("https://")) return Result.failure()
        return try {
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 15000
            c.readTimeout = 15000
            c.setRequestProperty("Accept", "application/json")
            c.setRequestProperty("User-Agent", "BloxTradeAI-Worker/1.0")
            if (c.responseCode != 200) return Result.retry()
            val declared = c.contentLengthLong
            if (declared > MAX_BYTES) return Result.failure()
            val bytes = c.inputStream.use { readBounded(it, MAX_BYTES + 1) }
            if (bytes.size > MAX_BYTES || bytes.isEmpty()) return Result.failure()
            val text = String(bytes, Charsets.UTF_8)
            if (!text.trimStart().startsWith("{")) return Result.failure()   // not a JSON object
            val tmp = File(applicationContext.filesDir, "$FILE.tmp")
            tmp.writeText(text)
            tmp.renameTo(File(applicationContext.filesDir, FILE))
            Result.success()
        } catch (e: java.io.IOException) {
            Result.retry()                      // network interruption: WorkManager backs off
        }
    }

    companion object {
        private const val FILE = "market_bg.json"
        private const val NAME = "blox_market_sync"
        private const val MAX_BYTES = 2_000_000

        fun schedule(ctx: Context, url: String, minutes: Long) {
            if (!url.startsWith("https://")) return
            val req = PeriodicWorkRequestBuilder<MarketSyncWorker>(minutes, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .setRequiresBatteryNotLow(true).build())
                .setInputData(workDataOf("url" to url))
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES)
                .build()
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.UPDATE, req)
        }
        /** Reads at most `limit` bytes (InputStream.readNBytes needs API 33; minSdk here is 26). */
        private fun readBounded(input: java.io.InputStream, limit: Int): ByteArray {
            val out = java.io.ByteArrayOutputStream()
            val buf = ByteArray(8192)
            while (out.size() < limit) {
                val n = input.read(buf, 0, minOf(buf.size, limit - out.size()))
                if (n < 0) break
                out.write(buf, 0, n)
            }
            return out.toByteArray()
        }
        fun cancel(ctx: Context) { WorkManager.getInstance(ctx).cancelUniqueWork(NAME) }
        fun read(ctx: Context): String {
            val f = File(ctx.filesDir, FILE)
            return if (f.exists()) f.readText() else ""
        }
        fun clear(ctx: Context) { File(ctx.filesDir, FILE).delete() }
    }
}
