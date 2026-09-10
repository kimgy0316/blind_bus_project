package com.blindbus.guide

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel

class LocationBridge(private val activity: Activity) {
    private val manager = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var maximumAgeMs = 15000L
    private var pendingOwner: String? = null
    private var tracking = false
    private var best: Location? = null
    private val timeout = Runnable { fail("LOCATION_TIMEOUT", "위치를 확인하지 못했습니다. 위치 기능을 켜고 실외에서 다시 시도해주세요.") }
    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val previous = best
            val age = if (previous == null) Long.MAX_VALUE else
                (SystemClock.elapsedRealtimeNanos() - previous.elapsedRealtimeNanos) / 1000000L
            if (location.hasAccuracy() && !location.isFromMockProvider &&
                (previous == null || age > 5000 || location.accuracy <= previous.accuracy)) best = location
            accept(best ?: location)
        }
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    fun current(result: MethodChannel.Result, maxAgeMs: Long = 15000L, owner: String? = null) {
        if (pending != null) { result.error("LOCATION_BUSY", "위치 확인 중입니다.", null); return }
        pendingOwner = owner
        maximumAgeMs = maxAgeMs.coerceIn(1000L, 15000L)
        pending = result
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), 7010)
        } else { start() }
    }

    fun permissionResult() {
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) start()
        else fail("LOCATION_PERMISSION", "위치 권한에서 정확한 위치와 앱 사용 중 허용을 선택해주세요.")
    }

    @Suppress("MissingPermission")
    private fun start() {
        if (pending == null) return
        try {
            val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter { manager.isProviderEnabled(it) }
            if (providers.isEmpty()) { fail("LOCATION_OFF", "갤럭시의 위치 기능을 켜주세요."); return }
            handler.removeCallbacks(timeout)
            handler.postDelayed(timeout, 30000)
            if (pendingOwner == "walking") {
                if (!tracking) {
                    tracking = true
                    for (provider in providers) manager.requestLocationUpdates(provider, 1000L, 0f, listener, Looper.getMainLooper())
                }
                val candidates = providers.mapNotNull { manager.getLastKnownLocation(it) } + listOfNotNull(best)
                val candidate = candidates.filter {
                    val age = (SystemClock.elapsedRealtimeNanos() - it.elapsedRealtimeNanos) / 1000000L
                    age in 0..maximumAgeMs && it.hasAccuracy() && !it.isFromMockProvider
                }.minByOrNull { it.accuracy }
                if (candidate != null) accept(candidate)
            } else {
                for (provider in providers) {
                    val cached = manager.getLastKnownLocation(provider)
                    if (cached != null) accept(cached)
                    if (pending == null) return
                    manager.requestLocationUpdates(provider, 1000L, 0f, listener, Looper.getMainLooper())
                }
            }
        } catch (_: SecurityException) { fail("LOCATION_PERMISSION", "위치 권한을 확인해주세요.") }
        catch (_: Exception) { fail("LOCATION_ERROR", "위치 센서에 연결하지 못했습니다.") }
    }

    @Suppress("DEPRECATION")
    private fun accept(location: Location) {
        val result = pending ?: return
        val age = (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1000000L
        if (age < 0 || age > maximumAgeMs || !location.hasAccuracy() || location.accuracy > (if (pendingOwner == "walking") 25f else 100f) || location.isFromMockProvider) return
        pending = null
        handler.removeCallbacks(timeout)
        if (pendingOwner != "walking") cleanup()
        result.success(mapOf("latitude" to location.latitude, "longitude" to location.longitude,
            "accuracy" to location.accuracy.toDouble(), "ageMs" to age,
            "timestamp" to location.time, "provider" to location.provider))
    }
    private fun cleanup() {
        tracking = false
        best = null
        handler.removeCallbacks(timeout)
        try { manager.removeUpdates(listener) } catch (_: Exception) {}
    }
    private fun fail(code: String, message: String) {
        val result = pending
        pending = null
        cleanup()
        result?.error(code, message, null)
    }
    fun cancel(owner: String?) { if (owner == pendingOwner) fail("LOCATION_CANCELLED", "위치 확인이 취소됐습니다.") }
    fun close() { fail("LOCATION_CLOSED", "위치 확인이 종료됐습니다.") }
}
