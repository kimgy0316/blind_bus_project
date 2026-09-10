package com.blindbus.guide

import android.app.Activity
import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import android.view.Surface
import kotlin.math.*

/** Screen-top azimuth. Invalid, stale and low-accuracy readings are never north=0. */
class CompassBridge(private val activity: Activity) : SensorEventListener {
    private val manager = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val sensor = manager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private var started = false
    private var heading: Double? = null
    private var sampledAt = 0L
    private var accuracy = SensorManager.SENSOR_STATUS_UNRELIABLE

    fun current(latitude: Double, longitude: Double): Map<String, Any?> {
        if (!started && sensor != null) {
            started = manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_UI)
        }
        val azimuth = heading
        val valid = azimuth != null && accuracy >= SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM &&
            SystemClock.elapsedRealtime() - sampledAt < 3000
        val declination = GeomagneticField(latitude.toFloat(), longitude.toFloat(), 0f, System.currentTimeMillis()).declination
        return mapOf("heading" to if (valid) (azimuth!! + declination + 360) % 360 else null)
    }

    @Suppress("DEPRECATION")
    override fun onSensorChanged(event: SensorEvent) {
        val matrix = FloatArray(9)
        val screen = FloatArray(9)
        val values = FloatArray(3)
        SensorManager.getRotationMatrixFromVector(matrix, event.values)
        val rotation = activity.windowManager.defaultDisplay.rotation
        val axes = when (rotation) {
            Surface.ROTATION_90 -> Pair(SensorManager.AXIS_Y, SensorManager.AXIS_MINUS_X)
            Surface.ROTATION_180 -> Pair(SensorManager.AXIS_MINUS_X, SensorManager.AXIS_MINUS_Y)
            Surface.ROTATION_270 -> Pair(SensorManager.AXIS_MINUS_Y, SensorManager.AXIS_X)
            else -> Pair(SensorManager.AXIS_X, SensorManager.AXIS_Y)
        }
        SensorManager.remapCoordinateSystem(matrix, axes.first, axes.second, screen)
        SensorManager.getOrientation(screen, values)
        if (abs(values[1]) > 1.05 || abs(values[2]) > 1.05) { heading = null; return }
        val raw = (Math.toDegrees(values[0].toDouble()) + 360) % 360
        val previous = heading
        heading = if (previous == null) raw else (previous + ((raw - previous + 540) % 360 - 180) * 0.2 + 360) % 360
        sampledAt = SystemClock.elapsedRealtime()
    }
    override fun onAccuracyChanged(sensor: Sensor?, value: Int) { accuracy = value }
    fun stop() {
        manager.unregisterListener(this)
        started = false; heading = null; sampledAt = 0
        accuracy = SensorManager.SENSOR_STATUS_UNRELIABLE
    }
}
