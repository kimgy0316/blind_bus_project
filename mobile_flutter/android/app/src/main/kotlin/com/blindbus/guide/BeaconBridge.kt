package com.blindbus.guide

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

class BeaconBridge(
    private val activity: Activity
) {
    companion object {
        const val REQUEST_CODE = 7020
    }

    private val handler = Handler(Looper.getMainLooper())

    private var scanner: BluetoothLeScanner? = null
    private var callback: ScanCallback? = null

    // 기존 1회 스캔용
    private var activeResult: MethodChannel.Result? = null

    // 권한 요청 대기용
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingDurationMs: Long = 5000L
    private var pendingMonitor = false

    private var finishRunnable: Runnable? = null

    private val foundBeacons =
        LinkedHashMap<String, MutableMap<String, Any>>()

    private val rssiSamples =
        LinkedHashMap<String, MutableList<Int>>()

    // 연속 스캔 상태
    private var continuousMonitoring = false

    fun scan(
        result: MethodChannel.Result,
        durationMs: Long = 5000L
    ) {
        if (
            activeResult != null ||
            pendingPermissionResult != null ||
            continuousMonitoring
        ) {
            result.error(
                "BEACON_BUSY",
                "비콘 스캔이 이미 진행 중입니다.",
                null
            )
            return
        }

        if (!hasPermission()) {
            pendingPermissionResult = result
            pendingDurationMs = durationMs
            pendingMonitor = false

            requestPermission()
            return
        }

        beginScan(result, durationMs)
    }

    fun startMonitor(
        result: MethodChannel.Result
    ) {
        if (continuousMonitoring) {
            result.success(
                mapOf(
                    "ok" to true,
                    "alreadyRunning" to true
                )
            )
            return
        }

        if (
            activeResult != null ||
            pendingPermissionResult != null
        ) {
            result.error(
                "BEACON_BUSY",
                "비콘 스캔이 이미 진행 중입니다.",
                null
            )
            return
        }

        if (!hasPermission()) {
            pendingPermissionResult = result
            pendingMonitor = true

            requestPermission()
            return
        }

        beginMonitor(result)
    }

    fun latest(
        result: MethodChannel.Result
    ) {
        val now =
            System.currentTimeMillis()

        val recentBeacons =
            foundBeacons.values.filter { beacon ->
                val lastSeen =
                    beacon["lastSeenMs"] as? Long ?: 0L

                now - lastSeen <= 3000L
            }

        result.success(
            mapOf(
                "ok" to true,
                "running" to continuousMonitoring,
                "beacons" to recentBeacons
            )
        )
    }

    private fun hasPermission(): Boolean {
        return if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        ) {
            activity.checkSelfPermission(
                Manifest.permission.BLUETOOTH_SCAN
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            activity.checkSelfPermission(
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestPermission() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        ) {
            activity.requestPermissions(
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN
                ),
                REQUEST_CODE
            )
        } else {
            activity.requestPermissions(
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION
                ),
                REQUEST_CODE
            )
        }
    }

    fun permissionResult(
        requestCode: Int,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != REQUEST_CODE) {
            return false
        }

        val result = pendingPermissionResult
        pendingPermissionResult = null

        if (result == null) {
            return true
        }

        val granted =
            grantResults.isNotEmpty() &&
                grantResults.all {
                    it == PackageManager.PERMISSION_GRANTED
                }

        if (!granted) {
            pendingMonitor = false

            result.error(
                "BEACON_PERMISSION_DENIED",
                "블루투스 스캔 권한이 거부되었습니다.",
                null
            )

            return true
        }

        if (pendingMonitor) {
            pendingMonitor = false
            beginMonitor(result)
        } else {
            beginScan(
                result,
                pendingDurationMs
            )
        }

        return true
    }

    private fun beginScan(
        result: MethodChannel.Result,
        durationMs: Long
    ) {
        try {
            val manager =
                activity.getSystemService(
                    Context.BLUETOOTH_SERVICE
                ) as BluetoothManager

            val adapter = manager.adapter

            if (adapter == null) {
                result.error(
                    "BLUETOOTH_UNAVAILABLE",
                    "이 기기에서는 블루투스를 사용할 수 없습니다.",
                    null
                )
                return
            }

            val bleScanner = adapter.bluetoothLeScanner

            if (bleScanner == null) {
                result.error(
                    "BLUETOOTH_OFF",
                    "블루투스가 꺼져 있습니다.",
                    null
                )
                return
            }

            foundBeacons.clear()
            rssiSamples.clear()

            scanner = bleScanner
            activeResult = result

            val scanCallback =
                createScanCallback()

            callback = scanCallback

            val settings =
                ScanSettings.Builder()
                    .setScanMode(
                        ScanSettings.SCAN_MODE_LOW_LATENCY
                    )
                    .build()

            bleScanner.startScan(
                null,
                settings,
                scanCallback
            )

            finishRunnable = Runnable {
                finishScan()
            }

            handler.postDelayed(
                finishRunnable!!,
                durationMs
            )

        } catch (error: SecurityException) {
            activeResult = null

            result.error(
                "BEACON_PERMISSION_ERROR",
                "블루투스 스캔 권한을 사용할 수 없습니다.",
                error.message
            )

        } catch (error: Exception) {
            activeResult = null

            result.error(
                "BEACON_ERROR",
                "비콘 스캔을 시작하지 못했습니다.",
                error.message
            )
        }
    }

    private fun beginMonitor(
        result: MethodChannel.Result
    ) {
        try {
            val manager =
                activity.getSystemService(
                    Context.BLUETOOTH_SERVICE
                ) as BluetoothManager

            val adapter = manager.adapter

            if (adapter == null) {
                result.error(
                    "BLUETOOTH_UNAVAILABLE",
                    "이 기기에서는 블루투스를 사용할 수 없습니다.",
                    null
                )
                return
            }

            val bleScanner = adapter.bluetoothLeScanner

            if (bleScanner == null) {
                result.error(
                    "BLUETOOTH_OFF",
                    "블루투스가 꺼져 있습니다.",
                    null
                )
                return
            }

            foundBeacons.clear()
            rssiSamples.clear()

            scanner = bleScanner
            continuousMonitoring = true

            val scanCallback =
                createScanCallback()

            callback = scanCallback

            val settings =
                ScanSettings.Builder()
                    .setScanMode(
                        ScanSettings.SCAN_MODE_LOW_LATENCY
                    )
                    .build()

            bleScanner.startScan(
                null,
                settings,
                scanCallback
            )

            android.util.Log.d(
                "BEACON",
                "continuous monitor started"
            )

            result.success(
                mapOf(
                    "ok" to true
                )
            )

        } catch (error: SecurityException) {
            continuousMonitoring = false
            stopScannerOnly()

            result.error(
                "BEACON_PERMISSION_ERROR",
                "블루투스 스캔 권한을 사용할 수 없습니다.",
                error.message
            )

        } catch (error: Exception) {
            continuousMonitoring = false
            stopScannerOnly()

            result.error(
                "BEACON_ERROR",
                "비콘 연속 스캔을 시작하지 못했습니다.",
                error.message
            )
        }
    }

    private fun createScanCallback(): ScanCallback {
        return object : ScanCallback() {

            override fun onScanResult(
                callbackType: Int,
                scanResult: ScanResult
            ) {
                handleResult(scanResult)
            }

            override fun onBatchScanResults(
                results: MutableList<ScanResult>
            ) {
                for (scanResult in results) {
                    handleResult(scanResult)
                }
            }

            override fun onScanFailed(
                errorCode: Int
            ) {
                android.util.Log.e(
                    "BEACON",
                    "scan failed: $errorCode"
                )

                if (continuousMonitoring) {
                    continuousMonitoring = false
                    stopScannerOnly()
                } else {
                    failScan(
                        "BEACON_SCAN_FAILED",
                        "비콘 스캔에 실패했습니다. 코드: $errorCode"
                    )
                }
            }
        }
    }

    private fun handleResult(
        scanResult: ScanResult
    ) {
        val record =
            scanResult.scanRecord ?: return

        val data =
            record.getManufacturerSpecificData(0x004C)
                ?: return

        if (data.size < 23) {
            return
        }

        if (
            data[0] != 0x02.toByte() ||
            data[1] != 0x15.toByte()
        ) {
            return
        }

        val uuidBytes =
            data.copyOfRange(2, 18)

        val uuidHex =
            uuidBytes.joinToString("") {
                "%02X".format(
                    it.toInt() and 0xFF
                )
            }

        val uuid =
            "${uuidHex.substring(0, 8)}-" +
                "${uuidHex.substring(8, 12)}-" +
                "${uuidHex.substring(12, 16)}-" +
                "${uuidHex.substring(16, 20)}-" +
                uuidHex.substring(20, 32)

        val major =
            ((data[18].toInt() and 0xFF) shl 8) or
                (data[19].toInt() and 0xFF)

        val minor =
            ((data[20].toInt() and 0xFF) shl 8) or
                (data[21].toInt() and 0xFF)

        val txPower =
            data[22].toInt()

        val rssi =
            scanResult.rssi

        val key =
            "$uuid:$major:$minor"

        val samples =
            rssiSamples.getOrPut(key) {
                mutableListOf()
            }

        samples.add(rssi)

        // 연속 스캔이므로 최근 9개만 유지
        if (samples.size > 9) {
            samples.removeAt(0)
        }

        val sortedSamples =
            samples.sorted()

        val medianRssi =
            sortedSamples[
                sortedSamples.size / 2
            ]

        foundBeacons[key] =
            mutableMapOf(
                "uuid" to uuid,
                "major" to major,
                "minor" to minor,
                "rssi" to medianRssi,
                "txPower" to txPower,
                "lastSeenMs" to System.currentTimeMillis()
            )

        android.util.Log.d(
            "BEACON",
            "uuid=$uuid " +
                "major=$major " +
                "minor=$minor " +
                "rssi=$rssi " +
                "median=$medianRssi " +
                "txPower=$txPower"
        )
    }

    private fun finishScan() {
        val result =
            activeResult ?: return

        stopScannerOnly()

        activeResult = null

        result.success(
            mapOf(
                "ok" to true,
                "beacons" to
                    foundBeacons.values.toList()
            )
        )
    }

    private fun failScan(
        code: String,
        message: String
    ) {
        val result =
            activeResult ?: return

        stopScannerOnly()

        activeResult = null

        result.error(
            code,
            message,
            null
        )
    }

    private fun stopScannerOnly() {
        finishRunnable?.let {
            handler.removeCallbacks(it)
        }

        finishRunnable = null

        try {
            val scanCallback = callback

            if (scanCallback != null) {
                scanner?.stopScan(scanCallback)
            }
        } catch (_: SecurityException) {
        }

        callback = null
        scanner = null
    }

    fun stop() {
        if (continuousMonitoring) {
            continuousMonitoring = false

            stopScannerOnly()

            foundBeacons.clear()
            rssiSamples.clear()

            android.util.Log.d(
                "BEACON",
                "continuous monitor stopped"
            )

            return
        }

        if (activeResult != null) {
            finishScan()
        } else {
            stopScannerOnly()
        }
    }

    fun close() {
        continuousMonitoring = false

        stopScannerOnly()

        activeResult = null
        pendingPermissionResult = null
        pendingMonitor = false
    }
}