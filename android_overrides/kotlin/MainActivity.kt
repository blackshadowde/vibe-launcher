package com.vibe.vibe_launcher

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.app.SearchManager
import android.app.role.RoleManager
import android.Manifest
import android.content.ComponentName
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.CallLog
import android.provider.ContactsContract
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.provider.MediaStore
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.speech.RecognizerIntent
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import io.flutter.embedding.android.FlutterActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "vibe/launcher"
    private var channel: MethodChannel? = null
    private var listenResult: MethodChannel.Result? = null
    private var pendingShare: Map<String, Any>? = null
    private var docResult: MethodChannel.Result? = null
    private var docText: String? = null
    private val saveCode = 4731
    private val openCode = 4732
    private val packMaps = HashMap<String, Map<String, String>>()

    // ---------- On-phone AI: Gemini Nano through Android's AICore ----------
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val nano: GenerativeModel? by lazy { try { Generation.getClient() } catch (e: Throwable) { null } }

    /** The first number (Long) inside a download status, whatever ML Kit named the field. */
    private fun firstLong(o: Any): Long? = try {
        o.javaClass.declaredFields.firstOrNull { it.type == java.lang.Long.TYPE }?.let {
            it.isAccessible = true
            it.getLong(o)
        }
    } catch (_: Throwable) { null }

    private suspend fun nanoStatus(): String = try {
        when (nano?.checkStatus()) {
            FeatureStatus.AVAILABLE -> "available"
            FeatureStatus.DOWNLOADABLE -> "downloadable"
            FeatureStatus.DOWNLOADING -> "downloading"
            else -> "unavailable"
        }
    } catch (e: Throwable) { "unavailable" }
    private var permResult: MethodChannel.Result? = null
    private val permCode = 4722
    private val peoplePerms = arrayOf(
        Manifest.permission.READ_CONTACTS,
        Manifest.permission.READ_CALL_LOG,
        Manifest.permission.CALL_PHONE,
        Manifest.permission.SEND_SMS
    )
    private val listenCode = 4721

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // If Vibe ever crashes, keep the reason so it can show it in chat on the next start
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        if (prev !is CrashSaver) Thread.setDefaultUncaughtExceptionHandler(CrashSaver(filesDir, prev))
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
        VibeNotifService.listener = { n -> channel?.invokeMethod("notif", n) }
        Sched.listener = { f -> channel?.invokeMethod("fired", f) }
        watchNetwork()
        pendingShare = readShare(intent)
        channel!!.setMethodCallHandler { call, result ->
            try { handleCall(call, result) } catch (t: Throwable) {
                try { result.error("native", t.toString(), null) } catch (_: Throwable) {}
            }
        }
    }

    private fun handleCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
            val pkg = call.argument<String>("package")
            when (call.method) {
                "lastCrash" -> {
                    val f = java.io.File(filesDir, "last_crash.txt")
                    val t = try { if (f.exists()) f.readText() else null } catch (_: Throwable) { null }
                    try { f.delete() } catch (_: Throwable) {}
                    result.success(t)
                }
                "getApps" -> Thread {
                    val pack = call.argument<String>("iconPack") ?: ""
                    val list = try { loadApps(pack) } catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(list) } catch (_: Throwable) {} }
                }.start()
                "launch" -> {
                    val i = pkg?.let { packageManager.getLaunchIntentForPackage(it) }
                    if (i == null) result.success(false) else {
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                        result.success(open(i))
                    }
                }
                "openSettings" -> result.success(open(Intent(Settings.ACTION_SETTINGS)))
                "openAccounts" -> result.success(
                    open(Intent(Settings.ACTION_SYNC_SETTINGS)) || open(Intent(Settings.ACTION_SETTINGS))
                )
                "openAppInfo" -> result.success(
                    open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")))
                )
                "uninstall" -> result.success(
                    open(Intent(Intent.ACTION_DELETE, Uri.parse("package:$pkg")))
                )
                "openHomeSettings" -> result.success(
                    open(Intent(Settings.ACTION_HOME_SETTINGS)) || open(Intent(Settings.ACTION_SETTINGS))
                )
                "isDefaultLauncher" -> result.success(isDefaultLauncher())
                "deviceInfo" -> result.success(deviceInfo())
                "openUrl" -> {
                    val i = Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: ""))
                    val target = call.argument<String>("package")
                    result.success((target != null && open(Intent(i).setPackage(target))) || open(i))
                }
                // ---------- Pictures: save, share, set as wallpaper ----------
                "saveToGallery" -> Thread {
                    val uri = try { saveToGallery(call.argument<String>("path") ?: "") } catch (e: Exception) { null }
                    runOnUiThread { try { result.success(uri) } catch (_: Throwable) {} }
                }.start()
                // Telegram downloads → Download/Vibe Telegram (visible in Files, music & video players)
                "saveDownload" -> Thread {
                    val uri = try {
                        saveDownload(call.argument<String>("path") ?: "", call.argument<String>("name") ?: "file",
                            call.argument<String>("mime") ?: "application/octet-stream")
                    } catch (e: Throwable) { null }
                    runOnUiThread { try { result.success(uri) } catch (_: Throwable) {} }
                }.start()
                "shareImage" -> {
                    val i = Intent(Intent.ACTION_SEND).setType("image/jpeg")
                        .putExtra(Intent.EXTRA_STREAM, Uri.parse(call.argument<String>("uri") ?: ""))
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    result.success(open(Intent.createChooser(i, "Share picture")))
                }
                "setWallpaper" -> Thread {
                    val ok = try {
                        val bmp = BitmapFactory.decodeFile(call.argument<String>("path") ?: "")
                        val which = if (call.argument<Boolean>("lock") == true) android.app.WallpaperManager.FLAG_LOCK
                            else android.app.WallpaperManager.FLAG_SYSTEM or android.app.WallpaperManager.FLAG_LOCK
                        android.app.WallpaperManager.getInstance(this).setBitmap(bmp, null, true, which); true
                    } catch (e: Exception) { false }
                    runOnUiThread { try { result.success(ok) } catch (_: Throwable) {} }
                }.start()
                "openSettingsPage" -> result.success(
                    open(Intent(call.argument<String>("action") ?: Settings.ACTION_SETTINGS)) ||
                        open(Intent(Settings.ACTION_SETTINGS))
                )
                // ---------- Vibe's own music player (songs on this phone) ----------
                "requestAudio" -> {
                    if (has(audioPerm)) result.success(permMap()) else {
                        permResult?.success(permMap())
                        permResult = result
                        requestPermissions(arrayOf(audioPerm), permCode)
                    }
                }
                "searchSongs" -> Thread {
                    val l = try { searchSongs(call.argument<String>("q") ?: "", call.argument<String>("by") ?: "any") }
                        catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(l) } catch (_: Throwable) {} }
                }.start()
                "songArt" -> Thread {
                    val b = try { songArt(call.argument<String>("uri") ?: "") } catch (e: Throwable) { null }
                    runOnUiThread { try { result.success(b) } catch (_: Throwable) {} }
                }.start()
                "playSongs" -> {
                    val songs = call.argument<List<Map<String, Any?>>>("songs") ?: emptyList()
                    val index = call.argument<Int>("index") ?: 0
                    withPlayer { c ->
                        val items = songs.map { m ->
                            val uri = (m["uri"] ?: "").toString()
                            androidx.media3.common.MediaItem.Builder()
                                .setUri(uri)
                                .setMediaId(uri)
                                .setMediaMetadata(
                                    androidx.media3.common.MediaMetadata.Builder()
                                        .setTitle((m["title"] ?: "").toString())
                                        .setArtist((m["artist"] ?: "").toString())
                                        .setAlbumTitle((m["album"] ?: "").toString())
                                        .setArtworkUri((m["art"] as? String)?.let { Uri.parse(it) })
                                        .build()
                                ).build()
                        }
                        c.setMediaItems(items, index.coerceIn(0, (items.size - 1).coerceAtLeast(0)), 0L)
                        c.prepare()
                        c.play()
                    }
                    result.success(true)
                }
                "playerCmd" -> {
                    val a = call.argument<String>("action") ?: ""
                    val ms = (call.argument<Number>("ms") ?: 0).toLong()
                    withPlayer { c ->
                        when (a) {
                            "play" -> c.play()
                            "pause" -> c.pause()
                            "toggle" -> if (c.isPlaying) c.pause() else c.play()
                            "next" -> if (c.hasNextMediaItem()) c.seekToNextMediaItem()
                            "previous" -> if (c.currentPosition > 4000 || !c.hasPreviousMediaItem()) c.seekTo(0) else c.seekToPreviousMediaItem()
                            "seek" -> c.seekTo(ms)
                            "stop" -> { c.stop(); c.clearMediaItems() }
                        }
                    }
                    result.success(true)
                }
                "playerState" -> result.success(player?.let { playerMap(it) })
                // ---------- Streaming apps: play by search in the background, without opening them ----------
                "playSilently" -> playSilently(call.argument<String>("query") ?: "", call.argument<String>("package"), result)
                "musicApp" -> {
                    val p = musicApp()
                    result.success(p?.let { mapOf("package" to it, "label" to labelOf(it)) })
                }
                // ---------- App shortcuts (long-press actions of other apps) ----------
                "shortcuts" -> {
                    val la = getSystemService(LAUNCHER_APPS_SERVICE) as android.content.pm.LauncherApps
                    if (!(try { la.hasShortcutHostPermission() } catch (_: Throwable) { false })) { result.success(null); return }
                    val q = android.content.pm.LauncherApps.ShortcutQuery().setQueryFlags(
                        android.content.pm.LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or
                            android.content.pm.LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST or
                            android.content.pm.LauncherApps.ShortcutQuery.FLAG_MATCH_PINNED)
                    call.argument<String>("package")?.let { q.setPackage(it) }
                    val list = try { la.getShortcuts(q, android.os.Process.myUserHandle()) ?: emptyList() } catch (_: Throwable) { emptyList() }
                    result.success(list.filter { it.isEnabled }.map {
                        mapOf("package" to it.`package`, "id" to it.id, "label" to (it.shortLabel?.toString() ?: ""),
                            "long" to (it.longLabel?.toString() ?: ""), "rank" to it.rank)
                    })
                }
                "shortcutIcon" -> Thread {
                    val bytes = try {
                        val la = getSystemService(LAUNCHER_APPS_SERVICE) as android.content.pm.LauncherApps
                        val q = android.content.pm.LauncherApps.ShortcutQuery()
                            .setPackage(call.argument<String>("package"))
                            .setShortcutIds(listOf(call.argument<String>("id") ?: ""))
                            .setQueryFlags(android.content.pm.LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or
                                android.content.pm.LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST or
                                android.content.pm.LauncherApps.ShortcutQuery.FLAG_MATCH_PINNED)
                        val sc = la.getShortcuts(q, android.os.Process.myUserHandle())?.firstOrNull()
                        val d = sc?.let { la.getShortcutIconDrawable(it, resources.displayMetrics.densityDpi) }
                        d?.let { drawableBytes(it) }
                    } catch (_: Throwable) { null }
                    runOnUiThread { try { result.success(bytes) } catch (_: Throwable) {} }
                }.start()
                "startShortcut" -> {
                    val ok = try {
                        val la = getSystemService(LAUNCHER_APPS_SERVICE) as android.content.pm.LauncherApps
                        la.startShortcut(call.argument<String>("package") ?: "", call.argument<String>("id") ?: "", null, null,
                            android.os.Process.myUserHandle())
                        true
                    } catch (_: Throwable) { false }
                    result.success(ok)
                }
                // ---------- Fingerprints for VirusTotal: a file, a shared file, or an installed app ----------
                "sha256" -> Thread {
                    val r = try { fingerprint(call.argument<String>("path"), call.argument<String>("uri"), call.argument<String>("package")) }
                        catch (e: Throwable) { null }
                    runOnUiThread { try { result.success(r) } catch (_: Throwable) {} }
                }.start()
                "readForUpload" -> Thread {
                    // Copies the file to Vibe's cache so it can be uploaded (only when you tap Upload)
                    val r = try { copyForUpload(call.argument<String>("path"), call.argument<String>("uri"), call.argument<String>("package")) }
                        catch (e: Throwable) { null }
                    runOnUiThread { try { result.success(r) } catch (_: Throwable) {} }
                }.start()
                "playMusic" -> {
                    val q = call.argument<String>("query") ?: ""
                    val i = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
                        .putExtra(MediaStore.EXTRA_MEDIA_FOCUS, "vnd.android.cursor.item/*")
                        .putExtra(SearchManager.QUERY, q)
                    // Replying to a music app: ask that app first, then any player
                    val target = call.argument<String>("package")
                    val ok = (target != null && open(Intent(i).setPackage(target))) || open(i)
                    result.success(ok)
                }
                "setAlarm" -> {
                    val i = Intent(AlarmClock.ACTION_SET_ALARM)
                        .putExtra(AlarmClock.EXTRA_HOUR, call.argument<Int>("hour") ?: 7)
                        .putExtra(AlarmClock.EXTRA_MINUTES, call.argument<Int>("minute") ?: 0)
                        .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                    val label = call.argument<String>("label")
                    if (!label.isNullOrBlank()) i.putExtra(AlarmClock.EXTRA_MESSAGE, label)
                    result.success(open(i))
                }
                "setTimer" -> {
                    val i = Intent(AlarmClock.ACTION_SET_TIMER)
                        .putExtra(AlarmClock.EXTRA_LENGTH, call.argument<Int>("seconds") ?: 60)
                        .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                    val label = call.argument<String>("label")
                    if (!label.isNullOrBlank()) i.putExtra(AlarmClock.EXTRA_MESSAGE, label)
                    result.success(open(i))
                }
                "notifAccess" -> result.success(hasNotifAccess())
                "openNotifAccess" -> {
                    val cn = ComponentName(this, VibeNotifService::class.java)
                    val ok = (Build.VERSION.SDK_INT >= 30 && open(
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, cn.flattenToString())
                    )) || open(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(ok)
                }
                "drainNotifs" -> result.success(VibeNotifService.drain())
                "replyNotif" -> result.success(
                    VibeNotifService.reply(this, call.argument<String>("key") ?: "", call.argument<String>("text") ?: "")
                )
                "openNotif" -> result.success(VibeNotifService.open(call.argument<String>("key") ?: ""))
                "mediaControl" -> result.success(
                    VibeNotifService.instance?.control(call.argument<String>("package"), call.argument<String>("action") ?: "toggle") ?: false
                )
                // ---------- People ----------
                "peoplePerms" -> result.success(permMap())
                "requestPeople" -> {
                    if (peoplePerms.all { has(it) }) result.success(permMap()) else {
                        permResult?.success(permMap())
                        permResult = result
                        requestPermissions(peoplePerms, permCode)
                    }
                }
                "contacts" -> Thread {
                    val l = try { loadContacts() } catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(l) } catch (_: Throwable) {} }
                }.start()
                "contactPhoto" -> Thread {
                    val bytes = try { contactPhoto(call.argument<String>("id") ?: "") } catch (e: Exception) { null }
                    runOnUiThread { try { result.success(bytes) } catch (_: Throwable) {} }
                }.start()
                "callLog" -> Thread {
                    val l = try { callLog(call.argument<Int>("limit") ?: 10) } catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(l) } catch (_: Throwable) {} }
                }.start()
                "call" -> {
                    val num = call.argument<String>("number") ?: ""
                    val uri = Uri.parse("tel:" + Uri.encode(num))
                    result.success(
                        if (has(Manifest.permission.CALL_PHONE)) open(Intent(Intent.ACTION_CALL, uri))
                        else open(Intent(Intent.ACTION_DIAL, uri))
                    )
                }
                // Opens the phone's own dialer with a number filled in (needed for codes like *#06#)
                "dialPad" -> result.success(open(Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(call.argument<String>("number") ?: "")))))
                // "Save as contact" screen with the number filled in
                "addContact" -> result.success(open(Intent(Intent.ACTION_INSERT).apply {
                    type = android.provider.ContactsContract.Contacts.CONTENT_TYPE
                    putExtra(android.provider.ContactsContract.Intents.Insert.PHONE, call.argument<String>("number") ?: "")
                }))
                "sendSms" -> {
                    val num = call.argument<String>("number") ?: ""
                    val text = call.argument<String>("text") ?: ""
                    result.success(try {
                        if (!has(Manifest.permission.SEND_SMS)) false else {
                            val sm = smsManager()
                            sm.sendMultipartTextMessage(num, null, sm.divideMessage(text), null, null)
                            true
                        }
                    } catch (e: Exception) { false })
                }
                "smsApp" -> {
                    val num = call.argument<String>("number") ?: ""
                    val i = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Uri.encode(num)))
                        .putExtra("sms_body", call.argument<String>("text") ?: "")
                    result.success(open(i))
                }
                "whatsapp" -> {
                    val d = waNumber(call.argument<String>("number") ?: "")
                    val text = call.argument<String>("text") ?: ""
                    val url = "https://api.whatsapp.com/send?phone=$d" + (if (text.isEmpty()) "" else "&text=" + Uri.encode(text))
                    val i = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    result.success(
                        open(Intent(i).setPackage("com.whatsapp")) ||
                            open(Intent(i).setPackage("com.whatsapp.w4b")) || open(i)
                    )
                }
                // ---------- Reminders & scheduled messages ----------
                "schedule" -> result.success(Sched.add(this, call.arguments as Map<*, *>))
                "cancelSched" -> { Sched.cancel(this, call.argument<String>("id") ?: ""); result.success(true) }
                "listSched" -> {
                    val a = Sched.items(this)
                    result.success((0 until a.length()).map { Sched.toMap(a.getJSONObject(it)) })
                }
                "takeFired" -> result.success(Sched.takeFired(this))
                "requestPostNotif" -> {
                    if (Build.VERSION.SDK_INT < 33 || has(Manifest.permission.POST_NOTIFICATIONS)) result.success(true) else {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4723)
                        result.success(false)
                    }
                }
                // ---------- Calendar ----------
                "calPerms" -> result.success(has(Manifest.permission.READ_CALENDAR))
                "requestCalendar" -> {
                    if (has(Manifest.permission.READ_CALENDAR) && has(Manifest.permission.WRITE_CALENDAR)) result.success(true) else {
                        permResult?.success(permMap())
                        permResult = result
                        requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR), permCode)
                    }
                }
                "events" -> Thread {
                    val l = try {
                        events(call.argument<Number>("from")!!.toLong(), call.argument<Number>("to")!!.toLong())
                    } catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(l) } catch (_: Throwable) {} }
                }.start()
                "addEvent" -> result.success(addEvent(
                    call.argument<String>("title") ?: "Event",
                    call.argument<Number>("begin")!!.toLong(),
                    call.argument<Number>("end")!!.toLong(),
                    call.argument<Boolean>("allDay") ?: false,
                    call.argument<String>("location") ?: ""
                ))
                "openEvent" -> result.success(open(Intent(Intent.ACTION_VIEW,
                    ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, (call.argument<Number>("id") ?: 0).toLong()))))
                "online" -> result.success(isOnline())
                // ---------- Icon packs ----------
                "iconPacks" -> {
                    val seen = LinkedHashMap<String, String>()
                    for (action in listOf("org.adw.launcher.THEMES", "com.novalauncher.THEME",
                            "com.teslacoilsw.launcher.THEME", "com.gau.go.launcherex.theme", "com.anddoes.launcher.THEME")) {
                        try {
                            for (ri in packageManager.queryIntentActivities(Intent(action), 0)) {
                                val p = ri.activityInfo.packageName
                                if (!seen.containsKey(p)) seen[p] = ri.loadLabel(packageManager).toString()
                            }
                        } catch (_: Exception) {}
                    }
                    result.success(seen.map { mapOf("package" to it.key, "label" to it.value) })
                }
                // ---------- Global search ----------
                "searchSms" -> Thread {
                    val l = try { searchSms(call.argument<String>("q") ?: "") } catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(l) } catch (_: Throwable) {} }
                }.start()
                "searchFiles" -> Thread {
                    val l = try { searchFiles(call.argument<String>("q") ?: "") } catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(l) } catch (_: Throwable) {} }
                }.start()
                "searchEvents" -> Thread {
                    val l = try { searchEvents(call.argument<String>("q") ?: "") } catch (e: Throwable) { emptyList<Map<String, Any>>() }
                    runOnUiThread { try { result.success(l) } catch (_: Throwable) {} }
                }.start()
                "openFile" -> {
                    val i = Intent(Intent.ACTION_VIEW)
                        .setDataAndType(Uri.parse(call.argument<String>("uri") ?: ""), call.argument<String>("mime") ?: "*/*")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    result.success(open(Intent.createChooser(i, null)))
                }
                "searchPerms" -> result.success(mapOf("sms" to has(Manifest.permission.READ_SMS), "files" to filesAccess()))
                "requestSms" -> {
                    if (has(Manifest.permission.READ_SMS)) result.success(permMap()) else {
                        permResult?.success(permMap())
                        permResult = result
                        requestPermissions(arrayOf(Manifest.permission.READ_SMS), permCode)
                    }
                }
                "requestFiles" -> {
                    if (Build.VERSION.SDK_INT >= 30) {
                        result.success(
                            open(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))) ||
                                open(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        )
                    } else {
                        requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 4733)
                        result.success(true)
                    }
                }
                // ---------- Backup & restore (Android's own file picker) ----------
                "saveDoc" -> {
                    docResult?.success(false)
                    docResult = result
                    docText = call.argument<String>("text")
                    try {
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("application/json")
                            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "vibe-backup.json"), saveCode)
                    } catch (e: Exception) { docResult = null; result.success(false) }
                }
                "openDoc" -> {
                    docResult?.success(null)
                    docResult = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("*/*"), openCode)
                    } catch (e: Exception) { docResult = null; result.success(null) }
                }
                "nanoStatus" -> scope.launch { result.success(nanoStatus()) }
                // Why the on-phone AI isn't ready: the exact status / error, and the AICore app versions
                "nanoInfo" -> scope.launch {
                    var status = "unknown"
                    var err = ""
                    if (nano == null) {
                        status = "no client"
                        err = try { Generation.getClient(); "" } catch (e: Throwable) { e.toString() }
                    } else {
                        try {
                            status = when (val st = nano!!.checkStatus()) {
                                FeatureStatus.AVAILABLE -> "available"
                                FeatureStatus.DOWNLOADABLE -> "downloadable"
                                FeatureStatus.DOWNLOADING -> "downloading"
                                FeatureStatus.UNAVAILABLE -> "unavailable"
                                else -> "status $st"
                            }
                        } catch (e: Throwable) { status = "error"; err = e.toString().take(300) }
                    }
                    fun ver(p: String) = try { packageManager.getPackageInfo(p, 0).versionName ?: "?" } catch (_: Throwable) { "not installed" }
                    result.success(mapOf(
                        "status" to status, "error" to err,
                        "aicore" to ver("com.google.android.aicore"),
                        "pcs" to ver("com.google.android.as.oss"),
                        "model" to Build.MODEL
                    ))
                }
                "nanoDownload" -> scope.launch {
                    var ok = false
                    var total = 0L
                    try {
                        nano?.download()?.collect { s ->
                            if (s is DownloadStatus.DownloadCompleted) { ok = true; return@collect }
                            // Started carries the total size, Progress the bytes so far
                            val n = firstLong(s) ?: return@collect
                            if (s.javaClass.simpleName.contains("Start")) total = n
                            val done = if (s.javaClass.simpleName.contains("Start")) 0L else n
                            try { channel?.invokeMethod("nanoProgress", mapOf("done" to done, "total" to total)) } catch (_: Throwable) {}
                        }
                    } catch (e: Throwable) {}
                    result.success(ok || nanoStatus() == "available")
                }
                "nanoAsk" -> scope.launch {
                    val prompt = call.argument<String>("prompt") ?: ""
                    val img = call.argument<String>("image")
                    val text = try {
                        val bmp = if (img != null) BitmapFactory.decodeFile(img) else null
                        val req = if (bmp != null) {
                            generateContentRequest(ImagePart(bmp), TextPart(prompt)) {
                                temperature = 0.4f
                                maxOutputTokens = 600
                            }
                        } else {
                            generateContentRequest(TextPart(prompt)) {
                                temperature = 0.4f
                                maxOutputTokens = 600
                            }
                        }
                        nano?.generateContent(req)?.candidates?.firstOrNull()?.text
                    } catch (e: Throwable) { null }
                    result.success(text)
                }
                "takeShared" -> { result.success(pendingShare); pendingShare = null }
                "filesDir" -> result.success(filesDir.absolutePath)
                "listen" -> {
                    listenResult?.success(null)
                    listenResult = result
                    val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                        .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                        .putExtra(RecognizerIntent.EXTRA_PROMPT, "Tell Vibe what to do")
                        .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                    try { startActivityForResult(i, listenCode) } catch (e: Exception) {
                        listenResult = null; result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
    }

    override fun onDestroy() {
        scope.cancel()
        netCallback?.let { try { getSystemService(android.net.ConnectivityManager::class.java)?.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        netCallback = null
        VibeNotifService.listener = null
        Sched.listener = null
        super.onDestroy()
    }

    private fun hasNotifAccess(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        return flat.contains(ComponentName(this, VibeNotifService::class.java).flattenToString())
    }

    // Pressing Home while the launcher is already open: tell Flutter to go back to the main view
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readShare(intent)?.let { s ->
            pendingShare = null
            channel?.invokeMethod("shared", s)
        }
        if (intent.hasCategory(Intent.CATEGORY_HOME)) channel?.invokeMethod("homePressed", null)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permCode) {
            permResult?.success(permMap())
            permResult = null
        }
    }

    @Suppress("DEPRECATION")
    private fun smsManager(): SmsManager =
        if (Build.VERSION.SDK_INT >= 31) getSystemService(SmsManager::class.java) else SmsManager.getDefault()

    /** Something shared to Vibe from another app: text/link, and/or a picture copied into our files. */
    private fun readShare(i: Intent?): Map<String, Any>? {
        if (i?.action != Intent.ACTION_SEND) return null
        val out = HashMap<String, Any>()
        i.getStringExtra(Intent.EXTRA_TEXT)?.let { if (it.isNotBlank()) out["text"] = it }
        i.getStringExtra(Intent.EXTRA_SUBJECT)?.let { if (it.isNotBlank()) out["subject"] = it }
        @Suppress("DEPRECATION")
        val stream = i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (i.type?.startsWith("image/") == true) {
            if (stream != null) saveImage(stream)?.let { out["image"] = it }
        } else if (stream != null) {
            // Any other file: keep a pointer so Vibe can check it (VirusTotal) without copying it
            try { contentResolver.takePersistableUriPermission(stream, Intent.FLAG_GRANT_READ_URI_PERMISSION) } catch (_: Throwable) {}
            out["file"] = stream.toString()
            out["mime"] = i.type ?: "application/octet-stream"
            try {
                contentResolver.query(stream, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        out["name"] = c.getString(0) ?: "file"
                        out["size"] = c.getLong(1)
                    }
                }
            } catch (_: Throwable) {}
        }
        return if (out.isEmpty()) null else out
    }

    /** Copies a picture into Vibe's files, shrunk to at most ~1600px, as JPEG. */
    private fun saveImage(uri: Uri): String? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (bounds.outWidth / sample > 1600 || bounds.outHeight / sample > 1600) sample *= 2
        val bmp = contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        }
        if (bmp == null) null else {
            val f = java.io.File(filesDir, "shared_${System.currentTimeMillis()}.jpg")
            f.outputStream().use { bmp.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            bmp.recycle()
            f.absolutePath
        }
    } catch (e: Exception) { null }

    private fun events(from: Long, to: Long): List<Map<String, Any>> {
        if (!has(Manifest.permission.READ_CALENDAR)) return emptyList()
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(uri, from)
        ContentUris.appendId(uri, to)
        val out = ArrayList<Map<String, Any>>()
        contentResolver.query(
            uri.build(),
            arrayOf(
                CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.TITLE,
                CalendarContract.Instances.BEGIN, CalendarContract.Instances.END,
                CalendarContract.Instances.ALL_DAY, CalendarContract.Instances.EVENT_LOCATION,
                CalendarContract.Instances.DISPLAY_COLOR
            ),
            null, null, CalendarContract.Instances.BEGIN + " ASC"
        )?.use { c ->
            while (c.moveToNext() && out.size < 50) {
                out.add(mapOf(
                    "id" to c.getLong(0),
                    "title" to (c.getString(1) ?: "(No title)"),
                    "begin" to c.getLong(2),
                    "end" to c.getLong(3),
                    "allDay" to (c.getInt(4) == 1),
                    "location" to (c.getString(5) ?: ""),
                    "color" to c.getInt(6)
                ))
            }
        }
        return out
    }

    /** Adds straight to your main calendar; without permission it opens the calendar app filled in. */
    private fun addEvent(title: String, begin: Long, end: Long, allDay: Boolean, location: String): String {
        if (has(Manifest.permission.WRITE_CALENDAR)) {
            try {
                var calId = -1L
                contentResolver.query(
                    CalendarContract.Calendars.CONTENT_URI,
                    arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.IS_PRIMARY),
                    CalendarContract.Calendars.VISIBLE + "=1 AND " + CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL + ">=" +
                        CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR,
                    null, null
                )?.use { c ->
                    while (c.moveToNext()) {
                        if (calId < 0 || c.getInt(1) == 1) calId = c.getLong(0)
                        if (c.getInt(1) == 1) break
                    }
                }
                if (calId >= 0) {
                    val v = android.content.ContentValues().apply {
                        put(CalendarContract.Events.CALENDAR_ID, calId)
                        put(CalendarContract.Events.TITLE, title)
                        put(CalendarContract.Events.DTSTART, begin)
                        put(CalendarContract.Events.DTEND, end)
                        put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
                        put(CalendarContract.Events.EVENT_TIMEZONE, if (allDay) "UTC" else java.util.TimeZone.getDefault().id)
                        if (location.isNotEmpty()) put(CalendarContract.Events.EVENT_LOCATION, location)
                        put(CalendarContract.Events.HAS_ALARM, 1)
                    }
                    val uri = contentResolver.insert(CalendarContract.Events.CONTENT_URI, v)
                    val id = uri?.lastPathSegment?.toLongOrNull()
                    if (id != null) {
                        contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, android.content.ContentValues().apply {
                            put(CalendarContract.Reminders.EVENT_ID, id)
                            put(CalendarContract.Reminders.MINUTES, 15)
                            put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                        })
                        return "added:$id"
                    }
                }
            } catch (_: Exception) {}
        }
        val i = Intent(Intent.ACTION_INSERT, CalendarContract.Events.CONTENT_URI)
            .putExtra(CalendarContract.Events.TITLE, title)
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
            .putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, allDay)
        if (location.isNotEmpty()) i.putExtra(CalendarContract.Events.EVENT_LOCATION, location)
        return if (open(i)) "opened" else "failed"
    }

    private var netCallback: android.net.ConnectivityManager.NetworkCallback? = null

    private fun isOnline(): Boolean {
        val cm = getSystemService(android.net.ConnectivityManager::class.java) ?: return true
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    /** Tells Vibe when internet comes and goes, so queued questions get answered on reconnect. */
    private fun watchNetwork() {
        if (netCallback != null) return
        val cm = getSystemService(android.net.ConnectivityManager::class.java) ?: return
        val main = Handler(Looper.getMainLooper())
        val cb = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(n: android.net.Network, c: android.net.NetworkCapabilities) {
                main.post { channel?.invokeMethod("net", isOnline()) }
            }
            override fun onLost(n: android.net.Network) {
                main.postDelayed({ channel?.invokeMethod("net", isOnline()) }, 500)
            }
        }
        try { cm.registerDefaultNetworkCallback(cb); netCallback = cb } catch (_: Exception) {}
    }

    /** Reads an icon pack's appfilter (res/xml or assets) into component → drawable name. */
    private fun iconPackMap(pack: String): Map<String, String> {
        packMaps[pack]?.let { return it }
        val out = HashMap<String, String>()
        try {
            val res = packageManager.getResourcesForApplication(pack)
            val id = res.getIdentifier("appfilter", "xml", pack)
            val parser: org.xmlpull.v1.XmlPullParser = if (id != 0) res.getXml(id) else {
                val f = org.xmlpull.v1.XmlPullParserFactory.newInstance().newPullParser()
                f.setInput(res.assets.open("appfilter.xml"), "UTF-8")
                f
            }
            var ev = parser.eventType
            while (ev != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
                if (ev == org.xmlpull.v1.XmlPullParser.START_TAG && parser.name == "item") {
                    val comp = parser.getAttributeValue(null, "component")
                    val draw = parser.getAttributeValue(null, "drawable")
                    if (comp != null && draw != null) {
                        out[comp] = draw
                        // also index by package alone, for apps whose launch activity changed
                        val m = Regex("ComponentInfo\\{([^/}]+)").find(comp)
                        if (m != null && !out.containsKey("ComponentInfo{${m.groupValues[1]}}")) {
                            out["ComponentInfo{${m.groupValues[1]}}"] = draw
                        }
                    }
                }
                ev = parser.next()
            }
        } catch (_: Exception) {}
        packMaps[pack] = out
        return out
    }

    private fun filesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else has(Manifest.permission.READ_EXTERNAL_STORAGE)

    private fun like(q: String) = "%" + q.replace("%", "").replace("_", "") + "%"

    private fun searchSms(q: String): List<Map<String, Any>> {
        if (q.length < 2 || !has(Manifest.permission.READ_SMS)) return emptyList()
        val out = ArrayList<Map<String, Any>>()
        contentResolver.query(
            Uri.parse("content://sms"), arrayOf("_id", "address", "body", "date", "type"),
            "body LIKE ? OR address LIKE ?", arrayOf(like(q), like(q)), "date DESC"
        )?.use { c ->
            while (c.moveToNext() && out.size < 20) {
                out.add(mapOf(
                    "address" to (c.getString(1) ?: ""), "body" to (c.getString(2) ?: ""),
                    "time" to c.getLong(3), "sent" to (c.getInt(4) == 2)
                ))
            }
        }
        return out
    }

    private fun searchFiles(q: String): List<Map<String, Any>> {
        if (q.length < 2) return emptyList()
        val uri = android.provider.MediaStore.Files.getContentUri("external")
        val out = ArrayList<Map<String, Any>>()
        contentResolver.query(
            uri,
            arrayOf(
                android.provider.MediaStore.Files.FileColumns._ID,
                android.provider.MediaStore.Files.FileColumns.DISPLAY_NAME,
                android.provider.MediaStore.Files.FileColumns.MIME_TYPE,
                android.provider.MediaStore.Files.FileColumns.SIZE,
                android.provider.MediaStore.Files.FileColumns.DATE_MODIFIED
            ),
            android.provider.MediaStore.Files.FileColumns.DISPLAY_NAME + " LIKE ?", arrayOf(like(q)),
            android.provider.MediaStore.Files.FileColumns.DATE_MODIFIED + " DESC"
        )?.use { c ->
            while (c.moveToNext() && out.size < 25) {
                val name = c.getString(1) ?: continue
                out.add(mapOf(
                    "uri" to ContentUris.withAppendedId(uri, c.getLong(0)).toString(),
                    "name" to name, "mime" to (c.getString(2) ?: "*/*"),
                    "size" to c.getLong(3), "time" to c.getLong(4) * 1000
                ))
            }
        }
        return out
    }

    private fun searchEvents(q: String): List<Map<String, Any>> {
        if (q.length < 2 || !has(Manifest.permission.READ_CALENDAR)) return emptyList()
        val out = ArrayList<Map<String, Any>>()
        contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(CalendarContract.Events._ID, CalendarContract.Events.TITLE, CalendarContract.Events.DTSTART,
                CalendarContract.Events.ALL_DAY, CalendarContract.Events.EVENT_LOCATION, CalendarContract.Events.DISPLAY_COLOR),
            CalendarContract.Events.TITLE + " LIKE ? OR " + CalendarContract.Events.EVENT_LOCATION + " LIKE ?",
            arrayOf(like(q), like(q)), CalendarContract.Events.DTSTART + " DESC"
        )?.use { c ->
            while (c.moveToNext() && out.size < 15) {
                out.add(mapOf(
                    "id" to c.getLong(0), "title" to (c.getString(1) ?: "(No title)"), "begin" to c.getLong(2),
                    "end" to c.getLong(2), "allDay" to (c.getInt(3) == 1), "location" to (c.getString(4) ?: ""),
                    "color" to c.getInt(5)
                ))
            }
        }
        return out
    }

    /** Copies a picture into Pictures/Vibe so it shows in Gallery; returns its content:// address. */
    private fun saveToGallery(path: String): String? {
        val f = java.io.File(path)
        if (!f.exists()) return null
        val v = android.content.ContentValues().apply {
            put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "Vibe_${System.currentTimeMillis()}.jpg")
            put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= 29) {
                put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/Vibe")
                put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val uri = contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v) ?: return null
        contentResolver.openOutputStream(uri)?.use { out -> f.inputStream().use { it.copyTo(out) } }
        if (Build.VERSION.SDK_INT >= 29) {
            contentResolver.update(uri, android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.IS_PENDING, 0)
            }, null, null)
        }
        return uri.toString()
    }

    // ---------------- Vibe player (Media3) ----------------
    private var player: androidx.media3.session.MediaController? = null
    private val pendingPlayer = ArrayList<(androidx.media3.session.MediaController) -> Unit>()
    private var connecting = false

    private fun withPlayer(block: (androidx.media3.session.MediaController) -> Unit) {
        player?.let { block(it); return }
        pendingPlayer.add(block)
        if (connecting) return
        connecting = true
        val token = androidx.media3.session.SessionToken(this, ComponentName(this, VibePlayerService::class.java))
        val f = androidx.media3.session.MediaController.Builder(this, token).buildAsync()
        val main = Handler(Looper.getMainLooper())
        f.addListener({
            connecting = false
            try {
                val c = f.get()
                player = c
                c.addListener(object : androidx.media3.common.Player.Listener {
                    override fun onEvents(p: androidx.media3.common.Player, events: androidx.media3.common.Player.Events) {
                        try { channel?.invokeMethod("player", playerMap(c)) } catch (_: Throwable) {}
                    }
                })
                val todo = ArrayList(pendingPlayer)
                pendingPlayer.clear()
                for (b in todo) try { b(c) } catch (_: Throwable) {}
            } catch (_: Throwable) { pendingPlayer.clear() }
        }, java.util.concurrent.Executor { r -> main.post(r) })
    }

    private fun playerMap(c: androidx.media3.session.MediaController): Map<String, Any?> {
        val md = c.mediaMetadata
        return mapOf(
            "playing" to c.isPlaying,
            "ready" to (c.mediaItemCount > 0),
            "title" to (md.title?.toString() ?: ""),
            "artist" to (md.artist?.toString() ?: ""),
            "art" to md.artworkUri?.toString(),
            "uri" to (c.currentMediaItem?.mediaId ?: ""),
            "pos" to c.currentPosition,
            "dur" to (if (c.duration > 0) c.duration else 0L),
            "index" to c.currentMediaItemIndex,
            "count" to c.mediaItemCount
        )
    }

    private fun searchSongs(q: String, by: String): List<Map<String, Any>> {
        if (!has(audioPerm)) return emptyList()
        val a = android.provider.MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val cols = arrayOf("_id", "title", "artist", "album", "album_id", "duration")
        val like = "%" + q.replace("%", "").replace("_", "") + "%"
        val (sel, args) = when (by) {
            "downloads" -> (if (Build.VERSION.SDK_INT >= 29) "relative_path LIKE ?" else "_data LIKE ?") to arrayOf("%Vibe Telegram%")
            "artist" -> "artist LIKE ? AND duration > 30000" to arrayOf(like)
            "all" -> "is_music != 0 AND duration > 30000" to arrayOf<String>()
            else -> "(title LIKE ? OR artist LIKE ? OR album LIKE ?) AND duration > 30000" to arrayOf(like, like, like)
        }
        val out = ArrayList<Map<String, Any>>()
        contentResolver.query(a, cols, sel, args, "title COLLATE NOCASE ASC")?.use { c ->
            while (c.moveToNext() && out.size < 300) {
                out.add(mapOf(
                    "uri" to ContentUris.withAppendedId(a, c.getLong(0)).toString(),
                    "title" to (c.getString(1) ?: "Unknown"),
                    "artist" to (c.getString(2)?.takeIf { it != "<unknown>" } ?: ""),
                    "album" to (c.getString(3) ?: ""),
                    "art" to "content://media/external/audio/albumart/${c.getLong(4)}",
                    "duration" to c.getLong(5)
                ))
            }
        }
        return out
    }

    private fun songArt(uri: String): ByteArray? {
        val u = Uri.parse(uri)
        val bmp = if (Build.VERSION.SDK_INT >= 29 && !uri.contains("albumart")) {
            try { contentResolver.loadThumbnail(u, android.util.Size(300, 300), null) } catch (_: Throwable) { null }
        } else {
            try { contentResolver.openInputStream(u)?.use { BitmapFactory.decodeStream(it) } } catch (_: Throwable) { null }
        } ?: return null
        val out = java.io.ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, out)
        return out.toByteArray()
    }

    private fun labelOf(pkg: String) = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Throwable) { pkg }

    /** The music app you use: the one that played last, else the phone's default for "play X". */
    private fun musicApp(): String? {
        VibeNotifService.instance?.lastMusicApp()?.let { return it }
        val i = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH)
        val p = packageManager.resolveActivity(i, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo?.packageName
        return if (p == null || p == "android" || p == packageName) null else p
    }

    /**
     * Asks a music app to play by search in the background, the way car screens do:
     * through its running session, or by connecting to its media browser service.
     */
    private fun playSilently(q: String, pkgArg: String?, result: MethodChannel.Result) {
        val pkg = pkgArg ?: musicApp()
        if (pkg == null || q.isBlank()) { result.success(null); return }
        var done = false
        val main = Handler(Looper.getMainLooper())
        fun finish(v: String?) {
            if (done) return
            done = true
            try { result.success(v?.let { mapOf("package" to it, "label" to labelOf(it)) }) } catch (_: Throwable) {}
        }
        val live = VibeNotifService.instance?.controllerFor(pkg)
        if (live != null) {
            try { live.transportControls.playFromSearch(q, Bundle()); finish(pkg); return } catch (_: Throwable) {}
        }
        val svc = try {
            packageManager.queryIntentServices(Intent("android.media.browse.MediaBrowserService").setPackage(pkg), 0).firstOrNull()
        } catch (_: Throwable) { null }
        if (svc == null) { finish(null); return }
        var browser: android.media.browse.MediaBrowser? = null
        browser = android.media.browse.MediaBrowser(this, ComponentName(pkg, svc.serviceInfo.name),
            object : android.media.browse.MediaBrowser.ConnectionCallback() {
                override fun onConnected() {
                    try {
                        val c = android.media.session.MediaController(this@MainActivity, browser!!.sessionToken)
                        c.transportControls.playFromSearch(q, Bundle())
                        finish(pkg)
                    } catch (_: Throwable) { finish(null) }
                    main.postDelayed({ try { browser?.disconnect() } catch (_: Throwable) {} }, 20000)
                }
                override fun onConnectionFailed() { finish(null) }
                override fun onConnectionSuspended() {}
            }, null)
        try { browser.connect() } catch (_: Throwable) { finish(null); return }
        main.postDelayed({ finish(null) }, 7000)
    }

    private fun drawableBytes(d: android.graphics.drawable.Drawable): ByteArray {
        val w = d.intrinsicWidth.takeIf { it > 0 } ?: 96
        val h = d.intrinsicHeight.takeIf { it > 0 } ?: 96
        val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val cv = android.graphics.Canvas(b)
        d.setBounds(0, 0, w, h)
        d.draw(cv)
        val out = java.io.ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private fun openSource(path: String?, uri: String?, pkg: String?): Pair<java.io.InputStream, Long>? {
        if (!pkg.isNullOrEmpty()) {
            val f = java.io.File(packageManager.getApplicationInfo(pkg, 0).sourceDir)
            return f.inputStream() to f.length()
        }
        if (!path.isNullOrEmpty()) {
            val f = java.io.File(path)
            return f.inputStream() to f.length()
        }
        if (!uri.isNullOrEmpty()) {
            val u = Uri.parse(uri)
            val size = try {
                contentResolver.query(u, arrayOf(android.provider.OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getLong(0) else -1L
                } ?: -1L
            } catch (_: Throwable) { -1L }
            val ins = contentResolver.openInputStream(u) ?: return null
            return ins to size
        }
        return null
    }

    private fun fingerprint(path: String?, uri: String?, pkg: String?): Map<String, Any>? {
        val (ins, size) = openSource(path, uri, pkg) ?: return null
        val md = java.security.MessageDigest.getInstance("SHA-256")
        var total = 0L
        ins.use {
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = it.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
                total += n
            }
        }
        val hex = md.digest().joinToString("") { b -> "%02x".format(b) }
        return mapOf("sha256" to hex, "size" to (if (size > 0) size else total))
    }

    private fun copyForUpload(path: String?, uri: String?, pkg: String?): String? {
        val (ins, _) = openSource(path, uri, pkg) ?: return null
        val out = java.io.File(cacheDir, "vt_upload.bin")
        ins.use { i -> out.outputStream().use { o -> i.copyTo(o, 1 shl 16) } }
        return out.absolutePath
    }

    private fun saveDownload(path: String, name: String, mime: String): String? {
        val f = java.io.File(path)
        if (!f.exists()) return null
        val clean = name.replace(Regex("[\\\\/:*?\"<>|]"), "_").take(120).ifBlank { "file" }
        if (Build.VERSION.SDK_INT >= 29) {
            val v = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Downloads.DISPLAY_NAME, clean)
                put(android.provider.MediaStore.Downloads.MIME_TYPE, mime)
                put(android.provider.MediaStore.Downloads.RELATIVE_PATH, "Download/Vibe Telegram")
                put(android.provider.MediaStore.Downloads.IS_PENDING, 1)
            }
            val col = android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val uri = contentResolver.insert(col, v) ?: return null
            contentResolver.openOutputStream(uri)?.use { out -> f.inputStream().use { it.copyTo(out, 1 shl 16) } }
            contentResolver.update(uri, android.content.ContentValues().apply {
                put(android.provider.MediaStore.Downloads.IS_PENDING, 0)
            }, null, null)
            return uri.toString()
        }
        @Suppress("DEPRECATION")
        val dir = java.io.File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Vibe Telegram")
        dir.mkdirs()
        val out = java.io.File(dir, clean)
        f.copyTo(out, overwrite = true)
        return Uri.fromFile(out).toString()
    }

    private fun has(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun permMap(): Map<String, Boolean> = mapOf(
        "contacts" to has(Manifest.permission.READ_CONTACTS),
        "calls" to has(Manifest.permission.READ_CALL_LOG),
        "phone" to has(Manifest.permission.CALL_PHONE),
        "sms" to has(Manifest.permission.SEND_SMS),
        "calendar" to has(Manifest.permission.READ_CALENDAR),
        "readSms" to has(Manifest.permission.READ_SMS),
        "audio" to has(audioPerm)
    )

    private val audioPerm =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun loadContacts(): List<Map<String, Any>> {
        if (!has(Manifest.permission.READ_CONTACTS)) return emptyList()
        val out = ArrayList<Map<String, Any>>()
        val seen = HashSet<String>()
        contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
                ContactsContract.CommonDataKinds.Phone.TYPE,
                ContactsContract.CommonDataKinds.Phone.IS_SUPER_PRIMARY,
                ContactsContract.CommonDataKinds.Phone.STARRED,
                ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI
            ), null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0).toString()
                val name = c.getString(1) ?: continue
                val num = c.getString(2) ?: continue
                val key = id + "|" + num.filter { it.isDigit() }.takeLast(10)
                if (!seen.add(key)) continue
                out.add(mapOf(
                    "id" to id, "name" to name, "number" to num,
                    "mobile" to (c.getInt(3) == ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE),
                    "primary" to (c.getInt(4) == 1),
                    "starred" to (c.getInt(5) == 1),
                    "photo" to (c.getString(6) != null)
                ))
            }
        }
        return out
    }

    private fun contactPhoto(id: String): ByteArray? {
        if (!has(Manifest.permission.READ_CONTACTS) || id.isEmpty()) return null
        val uri = ContentUris.withAppendedId(ContactsContract.Contacts.CONTENT_URI, id.toLong())
        return ContactsContract.Contacts.openContactPhotoInputStream(contentResolver, uri, false)?.use { it.readBytes() }
    }

    private fun callLog(limit: Int): List<Map<String, Any>> {
        if (!has(Manifest.permission.READ_CALL_LOG)) return emptyList()
        val out = ArrayList<Map<String, Any>>()
        contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
            null, null, CallLog.Calls.DATE + " DESC"
        )?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                val type = when (c.getInt(2)) {
                    CallLog.Calls.INCOMING_TYPE -> "incoming"
                    CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                    CallLog.Calls.MISSED_TYPE -> "missed"
                    CallLog.Calls.REJECTED_TYPE -> "rejected"
                    CallLog.Calls.BLOCKED_TYPE -> "blocked"
                    else -> "other"
                }
                out.add(mapOf(
                    "number" to (c.getString(0) ?: ""),
                    "name" to (c.getString(1) ?: ""),
                    "type" to type,
                    "time" to c.getLong(3),
                    "duration" to c.getLong(4)
                ))
            }
        }
        return out
    }

    private fun waNumber(raw: String) = waNumberFor(this, raw)

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == saveCode) {
            val uri = data?.data
            val ok = resultCode == RESULT_OK && uri != null && try {
                contentResolver.openOutputStream(uri, "wt")?.use { it.write((docText ?: "").toByteArray()) }; true
            } catch (e: Exception) { false }
            docResult?.success(ok); docResult = null; docText = null
        }
        if (requestCode == openCode) {
            val uri = data?.data
            val text = if (resultCode == RESULT_OK && uri != null) try {
                contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
            } catch (e: Exception) { null } else null
            docResult?.success(text); docResult = null
        }
        if (requestCode == listenCode) {
            val text = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            listenResult?.success(if (resultCode == RESULT_OK) text else null)
            listenResult = null
        }
    }

    private fun open(i: Intent): Boolean = try {
        if (i.flags and Intent.FLAG_ACTIVITY_NEW_TASK == 0) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(i); true
    } catch (e: Exception) { false }

    private fun loadApps(pack: String): List<Map<String, Any>> {
        val pm = packageManager
        val map = if (pack.isNotEmpty()) iconPackMap(pack) else emptyMap()
        val packRes = if (map.isNotEmpty()) try { pm.getResourcesForApplication(pack) } catch (e: Exception) { null } else null
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, Any>>()
        for (ri in pm.queryIntentActivities(intent, 0)) {
            val p = ri.activityInfo.packageName
            if (p == packageName || !seen.add(p)) continue
            val cat = if (Build.VERSION.SDK_INT >= 26) ri.activityInfo.applicationInfo.category else -1
            // Icon pack first ("ComponentInfo{package/activity}" → drawable), then the app's own icon
            var themed: android.graphics.drawable.Drawable? = null
            if (packRes != null) {
                val name = map["ComponentInfo{$p/${ri.activityInfo.name}}"] ?: map["ComponentInfo{$p}"]
                if (name != null) {
                    val id = packRes.getIdentifier(name, "drawable", pack)
                    if (id != 0) themed = try { packRes.getDrawable(id, null) } catch (e: Exception) { null }
                }
            }
            out.add(mapOf(
                "label" to ri.loadLabel(pm).toString(),
                "package" to p,
                "category" to cat,
                "icon" to iconBytes(themed ?: ri.loadIcon(pm))
            ))
        }
        return out
    }

    private fun iconBytes(d: android.graphics.drawable.Drawable): ByteArray {
        val size = 144
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        d.setBounds(0, 0, size, size)
        d.draw(c)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        return out.toByteArray()
    }

    private fun isDefaultLauncher(): Boolean {
        if (Build.VERSION.SDK_INT >= 29) {
            val rm = getSystemService(RoleManager::class.java)
            if (rm != null && rm.isRoleAvailable(RoleManager.ROLE_HOME)) return rm.isRoleHeld(RoleManager.ROLE_HOME)
        }
        val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val r = packageManager.resolveActivity(i, PackageManager.MATCH_DEFAULT_ONLY)
        return r?.activityInfo?.packageName == packageName
    }

    private fun deviceInfo(): Map<String, Any> {
        val stat = StatFs(Environment.getDataDirectory().path)
        val bm = getSystemService(BATTERY_SERVICE) as BatteryManager
        return mapOf(
            "maker" to Build.MANUFACTURER.replaceFirstChar { it.uppercase() },
            "model" to Build.MODEL,
            "android" to Build.VERSION.RELEASE,
            "storageTotal" to stat.totalBytes,
            "storageFree" to stat.availableBytes,
            "battery" to bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
            "charging" to (Build.VERSION.SDK_INT >= 23 && bm.isCharging)
        )
    }
}

/** Receives every app's notifications so they can appear as messages in the Vibe chat. */
class VibeNotifService : NotificationListenerService() {

    companion object {
        /** Set by MainActivity while the launcher is alive; otherwise notifications wait in [pending]. */
        var listener: ((Map<String, Any>) -> Unit)? = null
        var instance: VibeNotifService? = null
        val pending = ArrayList<Map<String, Any>>()
        private val replyActions = HashMap<String, Notification.Action>()
        private val contentIntents = HashMap<String, PendingIntent>()
        private val lastSeen = LinkedHashMap<String, String>()

        fun drain(): List<Map<String, Any>> {
            val out = ArrayList(pending)
            pending.clear()
            return out
        }

        fun reply(ctx: Context, key: String, text: String): Boolean {
            val a = replyActions[key] ?: return false
            val inputs = a.remoteInputs ?: return false
            return try {
                val intent = Intent()
                val bundle = Bundle()
                for (ri in inputs) bundle.putCharSequence(ri.resultKey, text)
                RemoteInput.addResultsToIntent(inputs, intent, bundle)
                a.actionIntent.send(ctx, 0, intent)
                true
            } catch (e: Exception) {
                false
            }
        }

        fun open(key: String): Boolean = try {
            contentIntents[key]?.send(); contentIntents.containsKey(key)
        } catch (e: Exception) {
            false
        }

        private fun <K, V> trim(m: MutableMap<K, V>, max: Int) {
            val it = m.keys.iterator()
            while (m.size > max && it.hasNext()) { it.next(); it.remove() }
        }
    }

    private val main = Handler(Looper.getMainLooper())

    private fun emit(map: Map<String, Any>) {
        main.post {
            val l = listener
            if (l != null) l(map) else {
                pending.add(map)
                while (pending.size > 300) pending.removeAt(0)
            }
        }
    }

    // ---------------- Music: "Playing X", "Paused X", song changes ----------------
    private var msm: MediaSessionManager? = null
    private val controllers = HashMap<String, Pair<MediaController, MediaController.Callback>>()
    private val mediaLast = HashMap<String, Pair<String, Int>>() // package -> (title, 1 playing / 2 paused)
    private val mediaTimers = HashMap<String, Runnable>()
    private val mediaKeys = HashMap<String, String>()
    private val mediaChangedAt = HashMap<String, Long>()

    private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { list ->
        main.post { syncSessions(list ?: emptyList(), false) }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        try {
            msm = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
            val cn = ComponentName(this, VibeNotifService::class.java)
            msm!!.addOnActiveSessionsChangedListener(sessionsListener, cn, main)
            syncSessions(msm!!.getActiveSessions(cn), true)
        } catch (_: Exception) {}
    }

    override fun onListenerDisconnected() {
        instance = null
        try { msm?.removeOnActiveSessionsChangedListener(sessionsListener) } catch (_: Exception) {}
        for ((c, cb) in controllers.values) try { c.unregisterCallback(cb) } catch (_: Exception) {}
        controllers.clear()
        super.onListenerDisconnected()
    }

    private fun sessionId(c: MediaController) = c.packageName + "@" + c.sessionToken.hashCode()

    private fun syncSessions(list: List<MediaController>, initial: Boolean) {
        val ids = list.map { sessionId(it) }.toSet()
        for (id in controllers.keys.filter { it !in ids }) {
            controllers.remove(id)?.let { (c, cb) -> try { c.unregisterCallback(cb) } catch (_: Exception) {} }
        }
        for (c in list) watch(c, initial)
    }

    /** Follows one player's session: song changes, play and pause. */
    private fun watch(c: MediaController, initial: Boolean) {
        val id = sessionId(c)
        if (controllers.containsKey(id) || c.packageName == packageName) return
        val cb = object : MediaController.Callback() {
            override fun onMetadataChanged(metadata: MediaMetadata?) = schedule(c)
            override fun onPlaybackStateChanged(state: PlaybackState?) = schedule(c)
        }
        try { c.registerCallback(cb, main) } catch (_: Exception) { return }
        controllers[id] = c to cb
        // Sessions already running when Vibe starts: show what's playing now (Vibe skips repeats)
        if (initial) {
            if (!mediaLast.containsKey(c.packageName)) mediaLast[c.packageName] = "" to 0
            if (state(c) == 1) schedule(c, true)
        } else schedule(c)
    }

    /**
     * Music players show a media notification. Local players often don't list their session as
     * "active", so take the session from the notification itself; with no session at all,
     * read the song from the notification text.
     */
    private fun mediaFromNotif(sbn: StatusBarNotification) {
        val pkg = sbn.packageName
        if (pkg == packageName) return
        val ex = sbn.notification.extras
        @Suppress("DEPRECATION")
        val token = try { ex.getParcelable<android.media.session.MediaSession.Token>(Notification.EXTRA_MEDIA_SESSION) } catch (_: Throwable) { null }
        if (token != null) {
            val c = try { MediaController(this, token) } catch (_: Throwable) { null }
            if (c != null) {
                if (controllers.containsKey(sessionId(c))) return // already following it
                watch(c, false)
                return
            }
        }
        if (controllers.values.any { it.first.packageName == pkg }) return
        // No session: use the notification's title / text and its Play or Pause button
        val t = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""
        if (t.isEmpty()) return
        val artist = ex.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim() ?: ""
        val labels = sbn.notification.actions?.map { it.title?.toString()?.lowercase() ?: "" } ?: emptyList()
        val st = when {
            labels.any { it.contains("pause") } -> 1
            labels.any { it.contains("play") } -> 2
            else -> 1
        }
        val (lastT, lastSt) = mediaLast[pkg] ?: ("" to 0)
        val now = System.currentTimeMillis()
        // Titles changing every few seconds = lyrics, not new songs
        val tt = if (lastT.isNotEmpty() && t != lastT && now - (mediaChangedAt[pkg] ?: 0L) < 15000) lastT else t
        val event = when {
            tt != lastT && st == 1 -> if (lastT.isEmpty()) "play" else "track"
            tt == lastT && st != lastSt -> if (st == 1) "play" else "pause"
            else -> null
        }
        if (tt != lastT) mediaChangedAt[pkg] = now
        mediaLast[pkg] = tt to st
        if (event == null) return
        val label = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) { pkg }
        emit(mapOf(
            "type" to "media", "event" to event, "pkg" to pkg, "app" to label,
            "title" to tt, "artist" to artist.take(120), "prev" to lastT,
            "time" to System.currentTimeMillis(), "initial" to false
        ))
    }

    // Some players (e.g. Media3-based ones) only fill the display title or the description
    private fun title(c: MediaController): String {
        val m = c.metadata ?: return ""
        return listOf(
            m.getString(MediaMetadata.METADATA_KEY_TITLE),
            m.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE),
            m.description?.title?.toString()
        ).firstOrNull { !it.isNullOrBlank() }?.trim() ?: ""
    }

    private fun artist(c: MediaController): String {
        val m = c.metadata ?: return ""
        return listOf(
            m.getString(MediaMetadata.METADATA_KEY_ARTIST),
            m.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST),
            m.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE),
            m.description?.subtitle?.toString()
        ).firstOrNull { !it.isNullOrBlank() }?.trim() ?: ""
    }

    private fun state(c: MediaController): Int = when (c.playbackState?.state) {
        PlaybackState.STATE_PLAYING -> 1
        PlaybackState.STATE_PAUSED, PlaybackState.STATE_STOPPED -> 2
        else -> 0 // buffering, skipping, none: wait for it to settle
    }

    /** Apps fire many callbacks per change; wait until things settle, then announce once. */
    private fun schedule(c: MediaController, initial: Boolean = false) {
        val pkg = c.packageName
        mediaTimers[pkg]?.let { main.removeCallbacks(it) }
        val r = Runnable { try { announce(c, initial) } catch (_: Throwable) {} }
        mediaTimers[pkg] = r
        main.postDelayed(r, 450)
    }

    /** Identity of the song itself, so lyric lines shown in the title don't count as new songs. */
    private fun songKey(c: MediaController): String {
        val m = c.metadata ?: return ""
        val id = m.getString(MediaMetadata.METADATA_KEY_MEDIA_ID) ?: ""
        if (id.isNotBlank()) return "id:$id"
        val dur = m.getLong(MediaMetadata.METADATA_KEY_DURATION)
        val album = m.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
        return if (dur > 0 || album.isNotBlank()) "s:$album|$dur" else ""
    }

    private fun announce(c: MediaController, initial: Boolean = false) {
        val pkg = c.packageName
        var t = title(c)
        val st = state(c)
        if (t.isEmpty() || st == 0) return
        val (lastT, lastSt) = mediaLast[pkg] ?: ("" to 0)
        val key = songKey(c)
        val now = System.currentTimeMillis()
        // Same song with a different title = a lyric line (or a small edit): keep the first title
        val sameSong = lastT.isNotEmpty() && t != lastT &&
            (if (key.isNotEmpty() && !mediaKeys[pkg].isNullOrEmpty()) key == mediaKeys[pkg]
             else now - (mediaChangedAt[pkg] ?: 0L) < 15000)
        if (sameSong) t = lastT
        val event = when {
            t != lastT && st == 1 -> if (lastT.isEmpty()) "play" else "track"
            t == lastT && st != lastSt -> if (st == 1) "play" else "pause"
            else -> null
        }
        if (t != lastT) { mediaKeys[pkg] = key; mediaChangedAt[pkg] = now }
        mediaLast[pkg] = t to st
        if (st == 1) lastPlayed = pkg
        if (event == null) return
        val label = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) { pkg }
        emit(mapOf(
            "type" to "media", "event" to event, "pkg" to pkg, "app" to label,
            "title" to t, "artist" to artist(c), "prev" to lastT,
            "time" to System.currentTimeMillis(), "initial" to initial
        ))
    }

    /** play / pause / toggle / next / previous on a music app (or whichever is playing). */
    fun controllerFor(pkg: String): MediaController? = controllers.values.map { it.first }.firstOrNull { it.packageName == pkg }

    /** The app that played music most recently (or is playing now). */
    fun lastMusicApp(): String? {
        controllers.values.map { it.first }.firstOrNull { state(it) == 1 }?.let { return it.packageName }
        return lastPlayed
    }
    var lastPlayed: String? = null

    fun control(pkg: String?, action: String): Boolean {
        val list = controllers.values.map { it.first }
        val c = list.firstOrNull { it.packageName == pkg }
            ?: list.firstOrNull { state(it) == 1 }
            ?: list.maxByOrNull { mediaLast[it.packageName]?.let { 1 } ?: 0 }
            ?: return false
        val tc = c.transportControls
        when (action) {
            "play" -> tc.play()
            "pause" -> tc.pause()
            "next" -> tc.skipToNext()
            "previous" -> tc.skipToPrevious()
            else -> if (state(c) == 1) tc.pause() else tc.play()
        }
        return true
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try { handle(sbn) } catch (_: Throwable) {}
    }

    private fun handle(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification
        val template = n.extras.getString(Notification.EXTRA_TEMPLATE) ?: ""
        if (n.extras.containsKey(Notification.EXTRA_MEDIA_SESSION) || template.contains("MediaStyle") ||
            n.category == Notification.CATEGORY_TRANSPORT) {
            try { mediaFromNotif(sbn) } catch (_: Throwable) {}
            return
        }
        if (n.flags and Notification.FLAG_ONGOING_EVENT != 0) return
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return
        when (n.category) {
            Notification.CATEGORY_PROGRESS, Notification.CATEGORY_SERVICE,
            Notification.CATEGORY_TRANSPORT, Notification.CATEGORY_SYSTEM -> return
        }

        val ex = n.extras
        var title = ex.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        var text = (ex.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: ex.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""

        // Chat apps: take the newest message from MessagingStyle
        @Suppress("DEPRECATION")
        val msgs = ex.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (msgs != null && msgs.isNotEmpty()) {
            val last = msgs.last() as? Bundle
            val t = last?.getCharSequence("text")?.toString()
            val sender = last?.getCharSequence("sender")?.toString()
            val convo = ex.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()
            if (!t.isNullOrBlank()) {
                text = t
                if (!convo.isNullOrBlank() && !sender.isNullOrBlank()) title = "$sender · $convo"
                else if (!sender.isNullOrBlank()) title = sender
            }
        }
        title = title.trim(); text = text.trim()
        if (title.isEmpty() && text.isEmpty()) return

        // Apps re-post the same notification often; only pass on real changes
        val sig = "$title|$text"
        if (lastSeen[sbn.key] == sig) return
        lastSeen[sbn.key] = sig
        trim(lastSeen, 500)

        var canReply = false
        n.actions?.forEach { a ->
            if (a.remoteInputs?.any { it.allowFreeFormInput } == true) {
                replyActions[sbn.key] = a; canReply = true
            }
        }
        n.contentIntent?.let { contentIntents[sbn.key] = it }
        trim(replyActions, 300); trim(contentIntents, 300)

        val label = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (e: Exception) { sbn.packageName }

        val map = mapOf<String, Any>(
            "key" to sbn.key,
            "pkg" to sbn.packageName,
            "app" to label,
            "title" to title,
            "text" to text.take(2000),
            "time" to sbn.postTime,
            "canReply" to canReply
        )
        emit(map)
    }
}

/**
 * Reminders and scheduled messages. Kept in Android's own storage and alarm system, so they
 * fire on time even if Vibe is closed, and come back after a restart.
 */
object Sched {
    var listener: ((Map<String, Any>) -> Unit)? = null
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("vibe_sched", Context.MODE_PRIVATE)

    fun items(ctx: Context): org.json.JSONArray =
        try { org.json.JSONArray(prefs(ctx).getString("items", "[]")) } catch (e: Exception) { org.json.JSONArray() }

    private fun saveItems(ctx: Context, a: org.json.JSONArray) = prefs(ctx).edit().putString("items", a.toString()).apply()

    fun toMap(o: org.json.JSONObject): Map<String, Any> {
        val m = HashMap<String, Any>()
        for (k in o.keys()) m[k] = o.get(k)
        return m
    }

    private fun pi(ctx: Context, id: String): PendingIntent = PendingIntent.getBroadcast(
        ctx, id.hashCode(),
        Intent(ctx, VibeAlarmReceiver::class.java).putExtra("id", id),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    /** Returns true if the alarm is exact (rings on the minute). */
    fun arm(ctx: Context, o: org.json.JSONObject): Boolean {
        val am = ctx.getSystemService(android.app.AlarmManager::class.java)
        val at = o.getLong("at")
        val p = pi(ctx, o.getString("id"))
        return try {
            if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
                am.setExactAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, at, p); true
            } else {
                am.setAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, at, p); false
            }
        } catch (e: Exception) {
            am.set(android.app.AlarmManager.RTC_WAKEUP, at, p); false
        }
    }

    fun add(ctx: Context, m: Map<*, *>): Boolean {
        val o = org.json.JSONObject()
        for ((k, v) in m) if (k != null && v != null) o.put(k.toString(), v)
        val a = items(ctx)
        val out = org.json.JSONArray()
        for (i in 0 until a.length()) if (a.getJSONObject(i).optString("id") != o.optString("id")) out.put(a.getJSONObject(i))
        out.put(o)
        saveItems(ctx, out)
        return arm(ctx, o)
    }

    fun cancel(ctx: Context, id: String) {
        val a = items(ctx)
        val out = org.json.JSONArray()
        for (i in 0 until a.length()) if (a.getJSONObject(i).optString("id") != id) out.put(a.getJSONObject(i))
        saveItems(ctx, out)
        ctx.getSystemService(android.app.AlarmManager::class.java).cancel(pi(ctx, id))
    }

    fun takeFired(ctx: Context): List<Map<String, Any>> {
        val a = try { org.json.JSONArray(prefs(ctx).getString("fired", "[]")) } catch (e: Exception) { org.json.JSONArray() }
        prefs(ctx).edit().putString("fired", "[]").apply()
        return (0 until a.length()).map { toMap(a.getJSONObject(it)) }
    }

    /** Re-arms everything after a restart; anything already due fires now. */
    fun rearm(ctx: Context) {
        val a = items(ctx)
        val now = System.currentTimeMillis()
        for (i in 0 until a.length()) {
            val o = a.getJSONObject(i)
            if (o.getLong("at") <= now) fire(ctx, o.getString("id")) else arm(ctx, o)
        }
    }

    fun fire(ctx: Context, id: String) {
        val a = items(ctx)
        var item: org.json.JSONObject? = null
        val rest = org.json.JSONArray()
        for (i in 0 until a.length()) {
            val o = a.getJSONObject(i)
            if (o.optString("id") == id) item = o else rest.put(o)
        }
        val o = item ?: return
        saveItems(ctx, rest)

        val type = o.optString("type")
        val text = o.optString("text")
        if (type == "brief") {
            // Daily: book tomorrow's straight away
            val next = org.json.JSONObject(o.toString())
            var at = o.getLong("at")
            while (at <= System.currentTimeMillis()) at += 24L * 60 * 60 * 1000
            next.put("at", at)
            val again = items(ctx)
            again.put(next)
            saveItems(ctx, again)
            arm(ctx, next)
        }
        val name = o.optString("name")
        val number = o.optString("number")
        val via = o.optString("via")
        var title = "⏰ Reminder"
        var body = text
        var tap: Intent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: Intent(ctx, MainActivity::class.java)

        if (type == "brief") {
            title = "☀️ Your daily brief is ready"
            body = "Weather, today's plans, missed calls and more"
        }
        if (type == "message") {
            if (via == "sms") {
                val late = System.currentTimeMillis() - o.getLong("at") > 60 * 60 * 1000
                val ok = !late && ctx.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED &&
                    try {
                        @Suppress("DEPRECATION")
                        val sm = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java) else SmsManager.getDefault()
                        sm.sendMultipartTextMessage(number, null, sm.divideMessage(text), null, null); true
                    } catch (e: Exception) { false }
                o.put("sent", ok)
                title = if (ok) "✓ Sent your SMS to $name" else "Couldn't send your SMS to $name"
            } else {
                title = "💬 Time to message $name"
                body = if (text.isEmpty()) "Tap to open the chat" else "Tap to send: $text"
                val d = waNumberFor(ctx, number)
                tap = Intent(Intent.ACTION_VIEW, Uri.parse(
                    "https://api.whatsapp.com/send?phone=$d" + (if (text.isEmpty()) "" else "&text=" + Uri.encode(text))
                ))
            }
        }
        o.put("firedAt", System.currentTimeMillis())
        notify(ctx, id.hashCode(), title, body, tap)

        val map = toMap(o)
        val l = listener
        if (l != null) Handler(Looper.getMainLooper()).post { l(map) } else {
            val f = try { org.json.JSONArray(prefs(ctx).getString("fired", "[]")) } catch (e: Exception) { org.json.JSONArray() }
            f.put(o)
            prefs(ctx).edit().putString("fired", f.toString()).apply()
        }
    }

    private fun notify(ctx: Context, nid: Int, title: String, body: String, tap: Intent) {
        val nm = ctx.getSystemService(android.app.NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                android.app.NotificationChannel("vibe_reminders", "Reminders", android.app.NotificationManager.IMPORTANCE_HIGH)
            )
        }
        tap.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val content = PendingIntent.getActivity(ctx, nid, tap, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, "vibe_reminders") else Notification.Builder(ctx)
        b.setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(content)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
        try { nm.notify(nid, b.build()) } catch (_: Exception) {}
    }
}

class VibeAlarmReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        try { Sched.fire(ctx, id) } catch (_: Exception) {}
    }
}

class VibeBootReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        try { Sched.rearm(ctx) } catch (_: Exception) {}
    }
}

/** WhatsApp wants the number with country code and no symbols. */
fun waNumberFor(ctx: Context, raw: String): String {
    val t = raw.trim()
    val digits = t.filter { it.isDigit() }
    if (t.startsWith("+")) return digits
    if (digits.startsWith("00")) return digits.drop(2)
    val iso = try {
        (ctx.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager).simCountryIso.lowercase()
    } catch (e: Exception) { "" }
    val cc = mapOf(
        "in" to "91", "us" to "1", "ca" to "1", "gb" to "44", "ae" to "971", "sa" to "966", "qa" to "974",
        "kw" to "965", "om" to "968", "bh" to "973", "sg" to "65", "my" to "60", "ph" to "63", "id" to "62",
        "pk" to "92", "bd" to "880", "lk" to "94", "np" to "977", "au" to "61", "nz" to "64", "de" to "49",
        "fr" to "33", "it" to "39", "es" to "34", "nl" to "31", "gr" to "30", "no" to "47", "se" to "46",
        "dk" to "45", "pl" to "48", "ie" to "353", "tr" to "90", "eg" to "20", "za" to "27", "ng" to "234",
        "ke" to "254", "cn" to "86", "hk" to "852", "jp" to "81", "kr" to "82", "th" to "66", "vn" to "84",
        "br" to "55", "mx" to "52", "ru" to "7", "ua" to "380"
    )[iso] ?: ""
    val local = digits.trimStart('0')
    // 10 digits or fewer = local number: add the SIM's country code
    return if (cc.isNotEmpty() && local.length <= 10) cc + local else local
}

/** Saves the reason for a crash to a small file, then lets Android handle it as usual. */
class CrashSaver(private val dir: java.io.File, private val prev: Thread.UncaughtExceptionHandler?) :
    Thread.UncaughtExceptionHandler {
    override fun uncaughtException(t: Thread, e: Throwable) {
        try {
            val trace = e.stackTrace.take(10).joinToString("\n") { "  at $it" }
            val cause = e.cause?.let { "\nCaused by: $it" } ?: ""
            java.io.File(dir, "last_crash.txt").writeText("$e$cause\n$trace")
        } catch (_: Throwable) {}
        prev?.uncaughtException(t, e)
    }
}

/** Plays music for Vibe in the background, with lock-screen and notification controls (Media3). */
class VibePlayerService : androidx.media3.session.MediaSessionService() {
    private var session: androidx.media3.session.MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val player = androidx.media3.exoplayer.ExoPlayer.Builder(this)
            .setAudioAttributes(
                androidx.media3.common.AudioAttributes.Builder()
                    .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                    .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                true
            )
            .setHandleAudioBecomingNoisy(true)
            .build()
        session = androidx.media3.session.MediaSession.Builder(this, player).build()
    }

    override fun onGetSession(controllerInfo: androidx.media3.session.MediaSession.ControllerInfo) = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        val p = session?.player
        if (p == null || !p.playWhenReady || p.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        session?.run {
            player.release()
            release()
        }
        session = null
        super.onDestroy()
    }
}
