package com.vibe.vibe_launcher

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaScannerConnection
import android.media.ThumbnailUtils
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.util.Size
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/** Files for Vibe's file commands (ls, cd, find, grep, rm…): list, search, read, write, move, trash, share. */
object VibeFiles {
    private const val TRASH = ".vibe_trash"
    private const val INDEX = ".index.json"
    private const val DAY = 24L * 60 * 60 * 1000

    val root: File get() = Environment.getExternalStorageDirectory()

    /** Phone storage plus any SD card, e.g. /storage/emulated/0 and /storage/1A2B-3C4D. */
    fun volumes(ctx: Context): List<String> {
        val out = ArrayList<String>()
        out.add(root.absolutePath)
        for (d in ctx.getExternalFilesDirs(null)) {
            val p = d?.absolutePath ?: continue
            val i = p.indexOf("/Android/")
            if (i > 0) {
                val v = p.substring(0, i)
                if (!out.contains(v)) out.add(v)
            }
        }
        return out
    }

    fun access(): Boolean = if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager() else true

    /** Other apps' private folders and anything outside shared storage stay off-limits. */
    fun blocked(f: File): Boolean {
        val p = f.absolutePath
        return !p.startsWith("/storage/") || p.contains("/Android/data") || p.contains("/Android/obb")
    }

    fun mimeOf(f: File): String =
        if (f.isDirectory) "inode/directory"
        else MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase()) ?: when (f.extension.lowercase()) {
            "md", "log", "ini", "conf", "yml", "yaml", "toml", "dart", "kt", "py", "sh", "srt", "vtt" -> "text/plain"
            "json" -> "application/json"
            "apk" -> "application/vnd.android.package-archive"
            else -> "application/octet-stream"
        }

    fun item(f: File): Map<String, Any> = mapOf(
        "n" to f.name,
        "p" to f.absolutePath,
        "d" to f.isDirectory,
        "s" to (if (f.isDirectory) 0L else f.length()),
        "t" to f.lastModified(),
        "c" to (if (f.isDirectory) (f.list()?.size ?: -1) else -1),
        "m" to mimeOf(f)
    )

    fun list(path: String, hidden: Boolean): Map<String, Any> {
        val d = File(path)
        if (blocked(d)) return mapOf("error" to "blocked", "path" to path)
        if (!d.exists()) return mapOf("error" to "missing", "path" to path)
        if (!d.isDirectory) return mapOf("error" to "notdir", "path" to path, "item" to item(d))
        val arr = d.listFiles() ?: return mapOf("error" to "denied", "path" to path)
        return mapOf("path" to d.absolutePath, "items" to arr.filter { hidden || !it.name.startsWith(".") }.map { item(it) })
    }

    // ---------- search ----------
    private fun likeToRegex(like: String): Regex {
        val sb = StringBuilder()
        for (ch in like) {
            when (ch) {
                '%' -> sb.append(".*")
                '_' -> sb.append('.')
                else -> sb.append(Regex.escape(ch.toString()))
            }
        }
        return Regex("^$sb$", RegexOption.IGNORE_CASE)
    }

    /** Walks folders (skipping hidden and private ones) until [limit] matches or the time runs out. */
    private fun walk(start: File, limit: Int, ms: Long, hidden: Boolean = false, match: (File) -> Boolean): Pair<List<File>, Boolean> {
        val out = ArrayList<File>()
        val end = System.currentTimeMillis() + ms
        val stack = ArrayDeque<Pair<File, Int>>()
        stack.add(start to 0)
        var partial = false
        while (stack.isNotEmpty()) {
            if (System.currentTimeMillis() > end) { partial = true; break }
            val (dir, depth) = stack.removeLast()
            val kids = dir.listFiles() ?: continue
            for (k in kids) {
                if ((!hidden && k.name.startsWith(".")) || blocked(k)) continue
                if (match(k)) {
                    out.add(k)
                    if (out.size >= limit) return out to true
                }
                if (k.isDirectory && depth < 12) stack.add(k to depth + 1)
            }
        }
        return out to partial
    }

    fun find(
        ctx: Context, rootPath: String, like: String?, mime: String?, exts: List<String>, minSize: Long, maxSize: Long,
        newer: Long, older: Long, dirs: Boolean, limit: Int
    ): Map<String, Any> {
        val extSet = exts.map { it.lowercase() }.toSet()
        val out = ArrayList<Map<String, Any>>()
        val base = rootPath.trimEnd('/')
        if (!dirs) {
            val sel = ArrayList<String>()
            val args = ArrayList<String>()
            sel.add("_data LIKE ?"); args.add("$base/%")
            if (like != null) { sel.add("_display_name LIKE ?"); args.add(like) }
            if (mime != null) { sel.add("mime_type LIKE ?"); args.add(mime) }
            if (extSet.isNotEmpty()) {
                sel.add("(" + extSet.joinToString(" OR ") { "_display_name LIKE ?" } + ")")
                extSet.forEach { args.add("%.$it") }
            }
            if (minSize > 0) { sel.add("_size >= ?"); args.add("$minSize") }
            if (maxSize > 0) { sel.add("_size <= ?"); args.add("$maxSize") }
            if (newer > 0) { sel.add("date_modified >= ?"); args.add("${newer / 1000}") }
            if (older > 0) { sel.add("date_modified <= ?"); args.add("${older / 1000}") }
            try {
                @Suppress("DEPRECATION")
                ctx.contentResolver.query(
                    MediaStore.Files.getContentUri("external"), arrayOf(MediaStore.Files.FileColumns.DATA),
                    sel.joinToString(" AND "), args.toTypedArray(), "date_modified DESC"
                )?.use { c ->
                    while (c.moveToNext() && out.size < limit) {
                        val p = c.getString(0) ?: continue
                        if (p.contains("/.")) continue
                        val f = File(p)
                        if (!f.isFile || blocked(f)) continue
                        out.add(item(f))
                    }
                }
            } catch (_: Throwable) {}
        }
        var partial = false
        // Not in Android's index (new files, unusual types, folders): look through the folders directly
        if (out.isEmpty() && (like != null || dirs || extSet.isNotEmpty())) {
            val re = like?.let { likeToRegex(it) }
            val mimeRe = mime?.let { likeToRegex(it) }
            val (found, part) = walk(File(base), limit, 6000) { f ->
                (if (dirs) f.isDirectory else f.isFile) &&
                    (re == null || re.matches(f.name)) &&
                    (mimeRe == null || mimeRe.matches(mimeOf(f))) &&
                    (extSet.isEmpty() || f.extension.lowercase() in extSet) &&
                    (minSize <= 0 || f.length() >= minSize) && (maxSize <= 0 || f.length() <= maxSize) &&
                    (newer <= 0 || f.lastModified() >= newer) && (older <= 0 || f.lastModified() <= older)
            }
            partial = part
            found.sortedByDescending { it.lastModified() }.forEach { out.add(item(it)) }
        }
        return mapOf("items" to out, "partial" to partial)
    }

    private val textExt = setOf(
        "txt", "md", "html", "htm", "json", "csv", "log", "xml", "js", "css", "py", "kt", "dart", "java", "c", "cpp",
        "h", "sh", "yml", "yaml", "ini", "conf", "srt", "vtt", "tex", "sql", "toml", "properties", "gradle", "ts",
        "tsx", "jsx", "php", "rb", "go", "rs", "swift", "bat", "env", "cfg", "tsv", "svg", "rtf"
    )

    fun isText(f: File) = f.extension.lowercase() in textExt

    /** Finds text inside text files (up to 1 MB each). */
    fun grep(path: String, text: String, ignoreCase: Boolean, limit: Int): Map<String, Any> {
        val start = File(path)
        val hits = ArrayList<Map<String, Any>>()
        val files = if (start.isFile) listOf(start) to false
        else walk(start, 3000, 4000) { it.isFile && isText(it) && it.length() < 1_000_000 }
        val end = System.currentTimeMillis() + 8000
        var partial = files.second
        for (f in files.first) {
            if (System.currentTimeMillis() > end) { partial = true; break }
            var n = 0
            var perFile = 0
            try {
                f.bufferedReader().useLines { lines ->
                    for (line in lines) {
                        n++
                        if (line.contains(text, ignoreCase)) {
                            hits.add(item(f) + mapOf("ln" to n, "line" to line.trim().take(200)))
                            if (++perFile >= 3 || hits.size >= limit) break
                        }
                    }
                }
            } catch (_: Throwable) {}
            if (hits.size >= limit) break
        }
        return mapOf("items" to hits, "partial" to partial)
    }

    /** Sizes of everything in a folder (folders added up), biggest first. */
    fun du(path: String): Map<String, Any> {
        val d = File(path)
        val kids = d.listFiles() ?: return mapOf("error" to "denied")
        val end = System.currentTimeMillis() + 12000
        var partial = false
        val out = ArrayList<Map<String, Any>>()
        var total = 0L
        for (k in kids) {
            if (blocked(k)) continue
            var size = 0L
            if (k.isDirectory) {
                val stack = ArrayDeque<File>()
                stack.add(k)
                while (stack.isNotEmpty()) {
                    if (System.currentTimeMillis() > end) { partial = true; break }
                    for (x in stack.removeLast().listFiles() ?: continue) {
                        if (x.isDirectory) stack.add(x) else size += x.length()
                    }
                }
            } else size = k.length()
            total += size
            out.add(item(k) + mapOf("s" to size))
        }
        return mapOf("items" to out.sortedByDescending { it["s"] as Long }, "total" to total, "partial" to partial)
    }

    fun df(ctx: Context): List<Map<String, Any>> = volumes(ctx).mapNotNull { v ->
        try {
            val s = StatFs(v)
            mapOf("path" to v, "total" to s.totalBytes, "free" to s.availableBytes)
        } catch (_: Throwable) { null }
    }

    fun read(path: String, max: Int): Map<String, Any> {
        val f = File(path)
        if (blocked(f)) return mapOf("error" to "blocked")
        if (!f.isFile) return mapOf("error" to "missing")
        return try {
            val len = f.length()
            val bytes = f.inputStream().use { s ->
                val buf = ByteArray(minOf(len, max.toLong()).toInt())
                var off = 0
                while (off < buf.size) { val r = s.read(buf, off, buf.size - off); if (r < 0) break; off += r }
                buf.copyOf(off)
            }
            mapOf("text" to String(bytes, Charsets.UTF_8), "truncated" to (len > max), "size" to len)
        } catch (e: Throwable) { mapOf("error" to "${e.message}") }
    }

    fun write(ctx: Context, path: String, text: String, append: Boolean): Boolean {
        val f = File(path)
        if (blocked(f) || f.isDirectory) return false
        return try {
            f.parentFile?.mkdirs()
            if (append) f.appendText(text) else f.writeText(text)
            rescan(ctx, listOf(f))
            true
        } catch (_: Throwable) { false }
    }

    // ---------- changes ----------
    private fun unique(f: File): File {
        if (!f.exists()) return f
        val base = f.nameWithoutExtension
        val ext = if (f.extension.isEmpty() || f.isDirectory) "" else ".${f.extension}"
        var i = 1
        while (true) {
            val c = File(f.parentFile, "$base ($i)$ext")
            if (!c.exists()) return c
            i++
        }
    }

    private fun volumeOf(f: File): File {
        val p = f.absolutePath
        val r = root.absolutePath
        if (p.startsWith(r)) return root
        val parts = p.split('/')
        return if (parts.size > 2) File("/" + parts[1] + "/" + parts[2]) else root
    }

    private fun trashDir(f: File): File {
        val t = File(volumeOf(f), TRASH)
        if (!t.exists()) {
            t.mkdirs()
            try { File(t, ".nomedia").createNewFile() } catch (_: Throwable) {}
        }
        return t
    }

    private fun readIndex(t: File): JSONObject = try {
        val f = File(t, INDEX)
        if (f.exists()) JSONObject(f.readText()) else JSONObject()
    } catch (_: Throwable) { JSONObject() }

    private fun writeIndex(t: File, j: JSONObject) {
        try { File(t, INDEX).writeText(j.toString()) } catch (_: Throwable) {}
    }

    /** Tells Android's file index what changed (so galleries and search see it). */
    fun rescan(ctx: Context, files: List<File>) {
        val paths = ArrayList<String>()
        for (f in files) {
            if (f.isDirectory) {
                walk(f, 300, 1500, true) { it.isFile }.first.forEach { paths.add(it.absolutePath) }
            }
            paths.add(f.absolutePath)
            if (paths.size > 400) break
        }
        if (paths.isEmpty()) return
        try { MediaScannerConnection.scanFile(ctx, paths.toTypedArray(), null, null) } catch (_: Throwable) {}
    }

    private fun moveFile(src: File, dst: File): Boolean {
        if (src.renameTo(dst)) return true
        // Different storage (phone ↔ SD card): copy, then remove the original
        return try {
            src.copyRecursively(dst, overwrite = false)
            src.deleteRecursively()
        } catch (_: Throwable) { false }
    }

    fun op(ctx: Context, op: String, paths: List<String>, dest: String?, name: String?): Map<String, Any> {
        val done = ArrayList<String>()
        val changed = ArrayList<File>()
        var error = ""
        fun fail(e: String) { if (error.isEmpty()) error = e }
        try {
            when (op) {
                "mkdir" -> {
                    val d = File(dest ?: "")
                    if (blocked(d)) fail("blocked") else if (d.exists()) fail("exists") else if (d.mkdirs()) { done.add(d.absolutePath); changed.add(d) } else fail("failed")
                }
                "touch" -> {
                    val f = File(dest ?: "")
                    if (blocked(f)) fail("blocked")
                    else if (f.exists()) { f.setLastModified(System.currentTimeMillis()); done.add(f.absolutePath) }
                    else { f.parentFile?.mkdirs(); if (f.createNewFile()) { done.add(f.absolutePath); changed.add(f) } else fail("failed") }
                }
                "copy", "move" -> {
                    val d = File(dest ?: "")
                    if (blocked(d)) { fail("blocked") } else {
                        val intoDir = d.isDirectory || paths.size > 1
                        if (intoDir) d.mkdirs()
                        for (p in paths) {
                            val s = File(p)
                            if (!s.exists() || blocked(s)) { fail("missing: ${s.name}"); continue }
                            val t = unique(if (intoDir) File(d, s.name) else d)
                            if (t.absolutePath.startsWith(s.absolutePath + "/")) { fail("can't put a folder inside itself"); continue }
                            val ok = if (op == "move") moveFile(s, t) else try { s.copyRecursively(t, overwrite = false) } catch (_: Throwable) { false }
                            if (ok) { done.add(t.absolutePath); changed.add(t); if (op == "move") changed.add(s) } else fail("failed: ${s.name}")
                        }
                    }
                }
                "rename" -> {
                    val s = File(paths.firstOrNull() ?: "")
                    val t = File(s.parentFile, name ?: "")
                    if (!s.exists() || blocked(s)) fail("missing")
                    else if (t.exists()) fail("exists")
                    else if (s.renameTo(t)) { done.add(t.absolutePath); changed.add(s); changed.add(t) } else fail("failed")
                }
                "trash" -> {
                    for (p in paths) {
                        val s = File(p)
                        if (!s.exists() || blocked(s)) { fail("missing: ${s.name}"); continue }
                        if (s.absolutePath.contains("/$TRASH")) { if (s.deleteRecursively()) done.add(p); continue }
                        val t = trashDir(s)
                        val dst = File(t, "${System.currentTimeMillis()}__${s.name}")
                        if (moveFile(s, dst)) {
                            val j = readIndex(t)
                            j.put(dst.name, s.absolutePath)
                            writeIndex(t, j)
                            done.add(dst.absolutePath)
                            changed.add(s)
                        } else fail("failed: ${s.name}")
                    }
                }
                "restore" -> {
                    for (p in paths) {
                        val s = File(p)
                        val t = s.parentFile ?: continue
                        val j = readIndex(t)
                        val from = j.optString(s.name, "")
                        val target = unique(if (from.isNotEmpty()) File(from) else File(volumeOf(s), s.name.substringAfter("__")))
                        target.parentFile?.mkdirs()
                        if (s.exists() && moveFile(s, target)) {
                            j.remove(s.name)
                            writeIndex(t, j)
                            done.add(target.absolutePath)
                            changed.add(target)
                        } else fail("failed: ${s.name.substringAfter("__")}")
                    }
                }
                "delete" -> {
                    for (p in paths) {
                        val s = File(p)
                        if (blocked(s)) { fail("blocked"); continue }
                        if (s.deleteRecursively()) { done.add(p); changed.add(s) } else fail("failed: ${s.name}")
                    }
                }
                "emptyTrash", "purge" -> {
                    for (v in volumes(ctx)) {
                        val t = File(v, TRASH)
                        val kids = t.listFiles() ?: continue
                        val j = readIndex(t)
                        for (k in kids) {
                            if (k.name == INDEX || k.name == ".nomedia") continue
                            val at = k.name.substringBefore("__").toLongOrNull() ?: 0L
                            if (op == "emptyTrash" || System.currentTimeMillis() - at > 30 * DAY) {
                                if (k.deleteRecursively()) { done.add(k.absolutePath); j.remove(k.name) }
                            }
                        }
                        writeIndex(t, j)
                    }
                }
                else -> fail("unknown")
            }
        } catch (e: Throwable) { fail("${e.message}") }
        rescan(ctx, changed)
        return mapOf("done" to done, "error" to error)
    }

    fun trashList(ctx: Context): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        for (v in volumes(ctx)) {
            val t = File(v, TRASH)
            val j = readIndex(t)
            for (k in t.listFiles() ?: continue) {
                if (k.name == INDEX || k.name == ".nomedia") continue
                out.add(item(k) + mapOf(
                    "n" to k.name.substringAfter("__"),
                    "from" to j.optString(k.name, ""),
                    "at" to (k.name.substringBefore("__").toLongOrNull() ?: k.lastModified())
                ))
            }
        }
        return out.sortedByDescending { it["at"] as Long }
    }

    // ---------- open & share ----------
    private fun uriOf(ctx: Context, f: File): Uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)

    fun share(act: Activity, paths: List<String>): Boolean {
        val files = paths.map { File(it) }.filter { it.isFile && !blocked(it) }
        if (files.isEmpty()) return false
        val uris = ArrayList(files.map { uriOf(act, it) })
        val mimes = files.map { mimeOf(it) }.distinct()
        val mime = if (mimes.size == 1) mimes[0] else {
            val tops = mimes.map { it.substringBefore('/') }.distinct()
            if (tops.size == 1) "${tops[0]}/*" else "*/*"
        }
        val i = if (uris.size == 1) Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        else Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        i.type = mime
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val clip = ClipData.newRawUri(files[0].name, uris[0])
        for (u in uris.drop(1)) clip.addItem(ClipData.Item(u))
        i.clipData = clip
        return try {
            act.startActivity(Intent.createChooser(i, if (files.size == 1) files[0].name else "${files.size} files"))
            true
        } catch (_: Throwable) { false }
    }

    /** "ok", "apk" (install from the Files app), "noapp" or "missing". */
    fun open(act: Activity, path: String): String {
        val f = File(path)
        if (!f.isFile || blocked(f)) return "missing"
        if (f.extension.equals("apk", true)) return "apk"
        val i = Intent(Intent.ACTION_VIEW).setDataAndType(uriOf(act, f), mimeOf(f))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        return try {
            act.startActivity(i); "ok"
        } catch (_: Throwable) {
            try { act.startActivity(Intent.createChooser(i, f.name)); "ok" } catch (_: Throwable) { "noapp" }
        }
    }

    /** A small picture of a photo, video or song cover. */
    fun thumb(path: String, size: Int): ByteArray? {
        val f = File(path)
        if (!f.isFile) return null
        val mime = mimeOf(f)
        val bmp: Bitmap? = try {
            if (Build.VERSION.SDK_INT >= 29) {
                val sz = Size(size, size)
                when {
                    mime.startsWith("image") -> ThumbnailUtils.createImageThumbnail(f, sz, null)
                    mime.startsWith("video") -> ThumbnailUtils.createVideoThumbnail(f, sz, null)
                    mime.startsWith("audio") -> ThumbnailUtils.createAudioThumbnail(f, sz, null)
                    else -> null
                }
            } else if (mime.startsWith("image")) {
                val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, o)
                var s = 1
                while (o.outWidth / (s * 2) >= size && o.outHeight / (s * 2) >= size) s *= 2
                BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = s })
            } else null
        } catch (_: Throwable) { null }
        if (bmp == null) return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
        return out.toByteArray()
    }
}
