package com.vibe.vibe_launcher

import android.app.role.RoleManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
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
