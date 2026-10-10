package com.vibe.vibe_launcher

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.app.SearchManager
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.graphics.Bitmap
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
import android.provider.MediaStore
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.speech.RecognizerIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val channelName = "vibe/launcher"
    private var channel: MethodChannel? = null
    private var listenResult: MethodChannel.Result? = null
    private val listenCode = 4721

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
        VibeNotifService.listener = { n -> channel?.invokeMethod("notif", n) }
        channel!!.setMethodCallHandler { call, result ->
            val pkg = call.argument<String>("package")
            when (call.method) {
                "getApps" -> Thread {
                    val list = try { loadApps() } catch (e: Exception) { emptyList<Map<String, Any>>() }
                    runOnUiThread { result.success(list) }
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
                "openUrl" -> result.success(
                    open(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: "")))
                )
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
    }

    override fun onDestroy() {
        VibeNotifService.listener = null
        super.onDestroy()
    }

    private fun hasNotifAccess(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: return false
        return flat.contains(ComponentName(this, VibeNotifService::class.java).flattenToString())
    }

    // Pressing Home while the launcher is already open: tell Flutter to go back to the main view
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) channel?.invokeMethod("homePressed", null)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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

    private fun loadApps(): List<Map<String, Any>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val out = ArrayList<Map<String, Any>>()
        for (ri in pm.queryIntentActivities(intent, 0)) {
            val p = ri.activityInfo.packageName
            if (p == packageName || !seen.add(p)) continue
            val cat = if (Build.VERSION.SDK_INT >= 26) ri.activityInfo.applicationInfo.category else -1
            out.add(mapOf(
                "label" to ri.loadLabel(pm).toString(),
                "package" to p,
                "category" to cat,
                "icon" to iconBytes(ri.loadIcon(pm))
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
        for (c in list) {
            val id = sessionId(c)
            if (controllers.containsKey(id) || c.packageName == packageName) continue
            val cb = object : MediaController.Callback() {
                override fun onMetadataChanged(metadata: MediaMetadata?) = schedule(c)
                override fun onPlaybackStateChanged(state: PlaybackState?) = schedule(c)
            }
            try { c.registerCallback(cb, main) } catch (_: Exception) { continue }
            controllers[id] = c to cb
            // Sessions already running when Vibe starts: remember them quietly instead of announcing
            if (initial) mediaLast[c.packageName] = title(c) to state(c) else schedule(c)
        }
    }

    private fun title(c: MediaController) =
        c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)?.trim() ?: ""

    private fun artist(c: MediaController) = (c.metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST)
        ?: c.metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST))?.trim() ?: ""

    private fun state(c: MediaController): Int = when (c.playbackState?.state) {
        PlaybackState.STATE_PLAYING -> 1
        PlaybackState.STATE_PAUSED, PlaybackState.STATE_STOPPED -> 2
        else -> 0 // buffering, skipping, none: wait for it to settle
    }

    /** Apps fire many callbacks per change; wait until things settle, then announce once. */
    private fun schedule(c: MediaController) {
        val pkg = c.packageName
        mediaTimers[pkg]?.let { main.removeCallbacks(it) }
        val r = Runnable { try { announce(c) } catch (_: Exception) {} }
        mediaTimers[pkg] = r
        main.postDelayed(r, 450)
    }

    private fun announce(c: MediaController) {
        val pkg = c.packageName
        val t = title(c)
        val st = state(c)
        if (t.isEmpty() || st == 0) return
        val (lastT, lastSt) = mediaLast[pkg] ?: ("" to 0)
        val event = when {
            t != lastT && st == 1 -> if (lastT.isEmpty()) "play" else "track"
            t == lastT && st != lastSt -> if (st == 1) "play" else "pause"
            else -> null
        }
        mediaLast[pkg] = t to st
        if (event == null) return
        val label = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
        } catch (e: Exception) { pkg }
        emit(mapOf(
            "type" to "media", "event" to event, "pkg" to pkg, "app" to label,
            "title" to t, "artist" to artist(c), "prev" to lastT,
            "time" to System.currentTimeMillis()
        ))
    }

    /** play / pause / toggle / next / previous on a music app (or whichever is playing). */
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
        try { handle(sbn) } catch (_: Exception) {}
    }

    private fun handle(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification
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
