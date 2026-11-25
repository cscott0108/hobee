package com.alok.hobee

import android.content.ContentValues
import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaMetadataRetriever
import android.media.MediaExtractor
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.WindowManager
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

// FragmentActivity: the fingerprint / face prompt (local_auth) needs it.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // App lock's "Hide in recent apps": FLAG_SECURE blanks the app-switcher preview and blocks screenshots.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hobee/window").setMethodCallHandler { call, result ->
            if (call.method == "secure") {
                if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
        // Reddit session login (Phase 7): read the cookies the in-app login page set (webview_flutter can't).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hobee/web").setMethodCallHandler { call, result ->
            when (call.method) {
                "cookies" -> result.success(CookieManager.getInstance().getCookie(call.argument<String>("url")!!))
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hobee/media").setMethodCallHandler { call, result ->
            Thread {
                try {
                    when (call.method) {
                        "sdk" -> runOnUiThread { result.success(Build.VERSION.SDK_INT) }
                        "mux" -> {
                            mux(call.argument<String>("video")!!, call.argument<String>("audio")!!, call.argument<String>("out")!!)
                            runOnUiThread { result.success(true) }
                        }
                        "frames" -> {
                            val r = frames(call.argument<String>("path")!!,
                                call.argument<List<Int>>("spots") ?: listOf(10, 40, 70, 90))
                            runOnUiThread { result.success(r) }
                        }
                        "save" -> {
                            val uri = save(call.argument<String>("path")!!, call.argument<String>("name")!!,
                                call.argument<String>("mime")!!, call.argument<Boolean>("video")!!)
                            runOnUiThread { result.success(uri) }
                        }
                        "zip" -> {
                            val uri = zip(call.argument<List<String>>("paths")!!, call.argument<List<String>>("names")!!,
                                call.argument<String>("name")!!)
                            runOnUiThread { result.success(uri) }
                        }
                        "download" -> {
                            val path = call.argument<String>("path")!!
                            val uri = toDownloads(call.argument<String>("name")!!, call.argument<String>("mime")!!) { o ->
                                FileInputStream(path).use { it.copyTo(o) }
                            }
                            runOnUiThread { result.success(uri) }
                        }
                        "unzip" -> {
                            val names = unzip(call.argument<String>("src")!!, call.argument<String>("dir")!!)
                            runOnUiThread { result.success(names) }
                        }
                        else -> runOnUiThread { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    runOnUiThread { result.error("ERR", e.toString(), null) }
                }
            }.start()
        }
    }

    /** Merge a video-only mp4 and an audio-only mp4 (Reddit DASH tracks) into one mp4, no re-encode. */
    private fun mux(video: String, audio: String, out: String) {
        val muxer = MediaMuxer(out, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val ve = MediaExtractor().apply { setDataSource(video) }
        val ae = MediaExtractor().apply { setDataSource(audio) }
        fun pick(ex: MediaExtractor, prefix: String): Int {
            for (i in 0 until ex.trackCount) {
                val m = ex.getTrackFormat(i).getString(android.media.MediaFormat.KEY_MIME) ?: ""
                if (m.startsWith(prefix)) { ex.selectTrack(i); return muxer.addTrack(ex.getTrackFormat(i)) }
            }
            return -1
        }
        val vt = pick(ve, "video/"); val at = pick(ae, "audio/")
        muxer.start()
        val buf = ByteBuffer.allocate(4 * 1024 * 1024)
        val info = MediaCodec.BufferInfo()
        for ((ex, t) in listOf(ve to vt, ae to at)) {
            if (t < 0) continue
            while (true) {
                val size = ex.readSampleData(buf, 0)
                if (size < 0) break
                info.offset = 0; info.size = size; info.presentationTimeUs = ex.sampleTime
                info.flags = if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                muxer.writeSampleData(t, buf, info)
                ex.advance()
            }
        }
        muxer.stop(); muxer.release(); ve.release(); ae.release()
    }

    /** True if a file with this name already exists in Pictures/ or Movies/. */
    private fun taken(coll: android.net.Uri, dir: String, name: String): Boolean {
        contentResolver.query(coll, arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
            arrayOf(name, "$dir/"), null)?.use { return it.count > 0 }
        return false
    }

    /** Adds _1, _2, ... before the extension until the name is free. */
    private fun freeName(base: String, exists: (String) -> Boolean): String {
        if (!exists(base)) return base
        val dot = base.lastIndexOf('.')
        val stem = if (dot > 0) base.substring(0, dot) else base
        val ext = if (dot > 0) base.substring(dot) else ""
        var n = 1
        while (exists("${stem}_$n$ext")) n++
        return "${stem}_$n$ext"
    }

    /** Save into plain Pictures/ or Movies/ via MediaStore (API 29+) or legacy public dir. No title or description is set. */
    private fun save(path: String, base: String, mime: String, video: Boolean): String {
        val dir = if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        if (Build.VERSION.SDK_INT >= 29) {
            val coll = if (video) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                       else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val name = freeName(base) { taken(coll, dir, it) }
            val v = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$dir/")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(coll, v) ?: throw Exception("MediaStore insert failed")
            contentResolver.openOutputStream(uri)!!.use { o -> FileInputStream(path).use { it.copyTo(o) } }
            v.clear(); v.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, v, null, null)
            return uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val d = Environment.getExternalStoragePublicDirectory(dir).apply { mkdirs() }
            val f = File(d, freeName(base) { File(d, it).exists() })
            File(path).copyTo(f, overwrite = true)
            MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), arrayOf(mime), null)
            return f.absolutePath
        }
    }

    /**
     * One .zip in Downloads/ with [paths] stored under [names] (Hobees gallery export). Stored, not compressed:
     * pictures and videos are already compressed, so this is fast and the zip is about the same size.
     */
    private fun zip(paths: List<String>, names: List<String>, base: String): String {
        fun write(o: OutputStream) {
            ZipOutputStream(BufferedOutputStream(o)).use { z ->
                z.setLevel(Deflater.NO_COMPRESSION)
                for (i in paths.indices) {
                    z.putNextEntry(ZipEntry(names[i]))
                    FileInputStream(paths[i]).use { it.copyTo(z) }
                    z.closeEntry()
                }
            }
        }
        return toDownloads(base, "application/zip", ::write)
    }

    /** Writes a new file named [base] (or "base (1)" and so on) into Downloads; returns its uri or path. */
    private fun toDownloads(base: String, mime: String, write: (OutputStream) -> Unit): String {
        val dir = Environment.DIRECTORY_DOWNLOADS
        if (Build.VERSION.SDK_INT >= 29) {
            val coll = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val name = freeName(base) { taken(coll, dir, it) }
            val v = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$dir/")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(coll, v) ?: throw Exception("MediaStore insert failed")
            try {
                contentResolver.openOutputStream(uri)!!.use { write(it) }
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null) // no half-written zip left behind
                throw e
            }
            v.clear(); v.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, v, null, null)
            return uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val d = Environment.getExternalStoragePublicDirectory(dir).apply { mkdirs() }
            val f = File(d, freeName(base) { File(d, it).exists() })
            try {
                FileOutputStream(f).use { write(it) }
            } catch (e: Exception) {
                f.delete()
                throw e
            }
            MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), arrayOf(mime), null)
            return f.absolutePath
        }
    }

    /**
     * Unpacks a Hobees backup ([src]: a content:// uri from the file picker or a file path) into [dir]. Only plain
     * file names at the top level are written, never paths, so an entry can't land outside [dir].
     */
    private fun unzip(src: String, dir: String): List<String> {
        val root = File(dir).canonicalFile
        val input = if (src.startsWith("content://")) contentResolver.openInputStream(android.net.Uri.parse(src))
                    else FileInputStream(src.removePrefix("file://"))
        val out = ArrayList<String>()
        ZipInputStream(BufferedInputStream(input ?: throw Exception("Can't open the file"))).use { z ->
            while (true) {
                val e = z.nextEntry ?: break
                val name = e.name
                if (e.isDirectory || name.contains('/') || name.contains('\\') || name.startsWith(".")) continue
                val f = File(root, name).canonicalFile
                if (f.parentFile != root) continue
                FileOutputStream(f).use { z.copyTo(it) }
                out.add(name)
            }
        }
        return out
    }

    /**
     * Small JPEG frames at [spots] percent of a local video file, for duplicate hashing. Returns
     * durationMs (0 if unknown) and one byte array per spot (empty when that frame could not be read).
     */
    private fun frames(path: String, spots: List<Int>): Map<String, Any> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val out = ArrayList<ByteArray>()
            if (ms > 0) {
                for (p in spots) {
                    val us = ms * 1000L * p / 100L
                    val full = r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)
                    if (full == null) { out.add(ByteArray(0)); continue }
                    val w = 64
                    val h = maxOf(1, full.height * w / maxOf(1, full.width))
                    val small = Bitmap.createScaledBitmap(full, w, h, true)
                    val bytes = ByteArrayOutputStream()
                    small.compress(Bitmap.CompressFormat.JPEG, 90, bytes)
                    if (small !== full) small.recycle()
                    full.recycle()
                    out.add(bytes.toByteArray())
                }
            }
            return mapOf("durationMs" to ms, "frames" to out)
        } finally {
            try { r.release() } catch (e: Exception) { }
        }
    }
}
