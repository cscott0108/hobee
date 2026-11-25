package io.github.cscott0108.hobee_net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Hobees' network helper (Wi-Fi safety):
 *  - "current": the active network's type, Wi-Fi name and router id (BSSID) and Android's id for the connection.
 *    The name and router id need location permission; without it they come back null (treated as untrusted).
 *  - "watch": calls "changed" on the Dart side whenever the default network changes.
 *  - "bindCellular" / "unbind": route this app's traffic (Dart, images, video) over mobile data only.
 * A plugin, not MainActivity code, so the background refresh engine has it too.
 */
class HobeeNetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var ch: MethodChannel
    private lateinit var ctx: Context
    private val main = Handler(Looper.getMainLooper())
    private var watcher: ConnectivityManager.NetworkCallback? = null

    private val cm get() = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ctx = b.applicationContext
        ch = MethodChannel(b.binaryMessenger, "hobee/net")
        ch.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ch.setMethodCallHandler(null)
        watcher?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        watcher = null
        if (owner === this) unbind() // only the engine that bound the app releases it
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "current" -> result.success(current())
                "watch" -> { watch(); result.success(null) }
                "bindCellular" -> bindCellular(result)
                "unbind" -> { unbind(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("ERR", e.toString(), null)
        }
    }

    private fun current(): Map<String, Any?> {
        val n = cm.activeNetwork ?: return mapOf("type" to "none")
        val c = cm.getNetworkCapabilities(n) ?: return mapOf("type" to "none", "handle" to n.networkHandle)
        val vpn = c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        val type = when {
            c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            vpn -> "vpn"
            else -> "other"
        }
        var ssid: String? = null
        var bssid: String? = null
        if (type == "wifi") {
            @Suppress("DEPRECATION")
            val info = (ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager).connectionInfo
            ssid = info?.ssid?.removeSurrounding("\"")?.takeIf { it.isNotEmpty() && it != "<unknown ssid>" }
            bssid = info?.bssid?.lowercase()?.takeIf { it != "02:00:00:00:00:00" }
        }
        return mapOf("type" to type, "ssid" to ssid, "bssid" to bssid, "handle" to n.networkHandle, "vpn" to vpn)
    }

    private fun changed() {
        main.post { try { ch.invokeMethod("changed", null) } catch (_: Exception) {} }
    }

    private fun watch() {
        if (watcher != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { changed() }
            override fun onLost(network: Network) { changed() }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { changed() }
        }
        cm.registerDefaultNetworkCallback(cb)
        watcher = cb
    }

    private fun bindCellular(result: MethodChannel.Result) {
        unbind()
        var answered = false
        fun answer(ok: Boolean) {
            main.post { if (!answered) { answered = true; result.success(ok) } }
        }
        val cb = object : ConnectivityManager.NetworkCallback() {
            // Android can announce the network a moment before it lets this app use it (it's still marked as a
            // background network), so binding is refused at first: retry for a few seconds, and again as soon as
            // the network reports it's in the foreground.
            override fun onAvailable(network: Network) = tryBind(network, 0)
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                if (!answered && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_FOREGROUND)) tryBind(network, -1)
            }
            fun tryBind(network: Network, attempt: Int) {
                if (answered) return
                val ok = cm.bindProcessToNetwork(network)
                Log.i("hobee_net", "mobile data available, bound=$ok (attempt $attempt)")
                if (ok) answer(true)
                else if (attempt in 0 until 10) main.postDelayed({ tryBind(network, attempt + 1) }, 300)
                else if (attempt >= 10) answer(false)
            }
            override fun onUnavailable() {
                Log.i("hobee_net", "mobile data unavailable")
                answer(false)
            }
            // Mobile data dropped: stay bound to it (requests fail) rather than silently falling back to Wi-Fi.
            override fun onLost(network: Network) { changed() }
        }
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        cellular = cb
        owner = this
        if (Build.VERSION.SDK_INT >= 26) cm.requestNetwork(req, cb, 10_000) else cm.requestNetwork(req, cb)
        main.postDelayed({ answer(false) }, 12_000)
        Log.i("hobee_net", "asked for mobile data")
    }

    private fun unbind() {
        if (cellular != null) Log.i("hobee_net", "released mobile data")
        try { cm.bindProcessToNetwork(null) } catch (_: Exception) {}
        cellular?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        cellular = null
        owner = null
    }

    companion object {
        // One binding per process (bindProcessToNetwork is process-wide), whichever engine asked for it.
        private var cellular: ConnectivityManager.NetworkCallback? = null
        private var owner: HobeeNetPlugin? = null
    }
}
