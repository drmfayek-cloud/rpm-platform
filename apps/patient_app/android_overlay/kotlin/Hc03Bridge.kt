package __PACKAGE__

import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.linktop.DeviceType
import com.linktop.MonitorDataTransmission
import com.linktop.MonitorDataTransmissionManager
import com.linktop.constant.BluetoothState
import com.linktop.constant.DeviceInfo
import com.linktop.constant.WareType
import com.linktop.infs.AuthCheckResult
import com.linktop.infs.OnBatteryListener
import com.linktop.infs.OnBleConnectListener
import com.linktop.infs.OnBpResultListener
import com.linktop.infs.OnDeviceInfoListener
import com.linktop.infs.OnDeviceVersionListener
import com.linktop.whealthService.MeasureType
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between the Flutter app and the Linktop HC03 Android SDK (BleDev v2.7.2).
 *
 * Scope: Bluetooth connection, device identity/battery/versions, blood pressure.
 * Other HC03 measurements are deliberately not exposed in the hypertension pilot.
 *
 * Method channel  "rpm/hc03"         — commands (see onMethodCall)
 * Event channel   "rpm/hc03/events"  — maps with a "type" key, always delivered on the main thread
 *
 * Notes from the SDK (verified against the compiled classes, which differ from the PDF guide):
 *  - bind(DeviceType.HealthMonitor, context, listener); listeners are set after onServiceBind().
 *  - MeasureType.BP == 1 (the PDF says 0 — the PDF is out of date).
 *  - connectToBle takes a BluetoothDevice, not a MAC string.
 *  - scan(true) auto-connects to the first device it finds; we use autoScan(true) instead so
 *    the user (or the kit set-up) picks the right unit when several are nearby.
 */
class Hc03Bridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    MonitorDataTransmission.OnServiceBindListener,
    OnBleConnectListener,
    OnBatteryListener,
    OnDeviceInfoListener,
    OnDeviceVersionListener,
    OnBpResultListener {

    companion object {
        private const val TAG = "Hc03Bridge"
        const val SDK_VERSION = "BleDev 2.7.2"
        private const val MIN_BATTERY_PERCENT = 20   // same guard as the vendor demo
    }

    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "rpm/hc03")
    private val events = EventChannel(messenger, "rpm/hc03/events")
    private var sink: EventChannel.EventSink? = null

    private var bound = false
    private var deviceSn: String? = null
    private var firmwareVersion: String? = null
    private var hardwareVersion: String? = null
    private var softwareVersion: String? = null
    private var batteryLevel: Int = -1
    private var charging: Boolean = false

    private val mgr: MonitorDataTransmissionManager
        get() = MonitorDataTransmissionManager.getInstance()

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        try {
            if (bound) {
                if (mgr.isMeasuring) mgr.stopMeasure()
                if (mgr.isConnected) mgr.disConnectBle()
                mgr.unBind()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "dispose", t)
        }
        bound = false
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }

    // ------------------------------------------------------------------
    // Commands from Dart
    // ------------------------------------------------------------------
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "bind" -> {
                    if (!bound) mgr.bind(DeviceType.HealthMonitor, activity, this)
                    result.success(bound)
                }
                "status" -> result.success(statusMap())
                "androidSdkInt" -> result.success(android.os.Build.VERSION.SDK_INT)
                "openBluetooth" -> { mgr.bleCheckOpen(); result.success(null) }
                "startScan" -> { requireBound(); mgr.autoScan(true); result.success(null) }
                "stopScan" -> { if (bound) mgr.autoScan(false); result.success(null) }
                "devices" -> { requireBound(); result.success(deviceList()) }
                "connect" -> {
                    requireBound()
                    val mac = call.argument<String>("mac")
                        ?: return result.error("BAD_ARGS", "mac is required", null)
                    connect(mac)
                    result.success(null)
                }
                "disconnect" -> { if (bound && mgr.isConnected) mgr.disConnectBle(); result.success(null) }
                "startBp" -> {
                    requireBound()
                    if (!mgr.isConnected) return result.error("NOT_CONNECTED", "Device is not connected", null)
                    if (mgr.isMeasuring) return result.error("BUSY", "A measurement is already running", null)
                    val battery = mgr.batteryValue
                    if (!mgr.isCharging && battery in 0 until MIN_BATTERY_PERCENT) {
                        return result.error("LOW_BATTERY", "Device battery is $battery%", battery)
                    }
                    mgr.setMeasurePosition(false)            // upper arm only; wrist is not used in the pilot
                    mgr.startMeasure(MeasureType.BP)
                    emit(mapOf("type" to "bpStarted"))
                    result.success(null)
                }
                "stopBp" -> {
                    if (bound && mgr.isMeasuring) mgr.stopMeasure(MeasureType.BP)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION", e.message, null)
        } catch (t: Throwable) {
            Log.e(TAG, "onMethodCall ${call.method}", t)
            result.error("HC03_ERROR", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private fun requireBound() {
        if (!bound) throw IllegalStateException("SDK service is not bound yet; call bind first")
    }

    @SuppressLint("MissingPermission")
    private fun connect(mac: String) {
        val adapter = activity.getSystemService(BluetoothManager::class.java)?.adapter
            ?: throw IllegalStateException("Bluetooth is not available on this phone")
        mgr.autoScan(false)
        deviceSn = null
        mgr.connectToBle(adapter.getRemoteDevice(mac.uppercase()))
    }

    @SuppressLint("MissingPermission")
    private fun deviceList(): List<Map<String, Any?>> =
        (mgr.deviceList ?: emptyList()).map { d ->
            val name = try { d.bleDevice?.name } catch (e: SecurityException) { null }
            mapOf("mac" to d.bleDevice?.address, "name" to name, "rssi" to d.rssi)
        }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "bound" to bound,
        "bleState" to if (bound) mgr.bleState else null,
        "bleStateName" to if (bound) bleStateName(mgr.bleState) else "UNBOUND",
        "connected" to (bound && mgr.isConnected),
        "measuring" to (bound && mgr.isMeasuring),
        "deviceSn" to deviceSn,
        "firmwareVersion" to firmwareVersion,
        "hardwareVersion" to hardwareVersion,
        "softwareVersion" to softwareVersion,
        "battery" to batteryLevel,
        "charging" to charging,
        "sdkVersion" to SDK_VERSION,
    )

    private fun bleStateName(state: Int) = when (state) {
        BluetoothState.BLE_CLOSED -> "BLUETOOTH_OFF"
        BluetoothState.BLE_OPENED_AND_DISCONNECT -> "DISCONNECTED"
        BluetoothState.BLE_CONNECTING_DEVICE -> "CONNECTING"
        BluetoothState.BLE_CONNECTED_DEVICE -> "CONNECTED"
        BluetoothState.BLE_NOTIFICATION_ENABLED -> "READY"
        BluetoothState.BLE_NOTIFICATION_DISABLED -> "NOT_READY"
        else -> "UNKNOWN"
    }

    // ------------------------------------------------------------------
    // Event stream
    // ------------------------------------------------------------------
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        emit(mapOf("type" to "status") + statusMap())
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    // ------------------------------------------------------------------
    // SDK callbacks (may arrive on SDK threads)
    // ------------------------------------------------------------------
    override fun onServiceBind() {
        bound = true
        mgr.setOnBleConnectListener(this)
        mgr.setOnBatteryListener(this)
        mgr.setOnDevIdAndKeyListener(this)
        mgr.setOnDeviceVersionListener(this)
        mgr.setOnBpResultListener(this)
        // Only some custom HC03 batches need this; harmless (times out) on the others.
        mgr.needDeviceAuthCheck(object : AuthCheckResult {
            override fun onAuthCheckResult(success: Boolean) =
                emit(mapOf("type" to "authCheck", "success" to success))
            override fun onAuthCheckResultTimeout() =
                emit(mapOf("type" to "authCheck", "success" to null))
        })
        emit(mapOf("type" to "serviceBound"))
    }

    override fun onServiceUnbind() {
        bound = false
        emit(mapOf("type" to "serviceUnbound"))
    }

    override fun onSDKThrowable(e: Throwable) {
        Log.e(TAG, "SDK error", e)
        emit(mapOf("type" to "sdkError", "message" to (e.message ?: e.javaClass.simpleName)))
    }

    override fun onBLENoSupported() = emit(mapOf("type" to "bleNotSupported"))

    override fun onOpenBLE() = emit(mapOf("type" to "bluetoothOffRequest"))

    override fun onBleState(state: Int) {
        if (state == BluetoothState.BLE_OPENED_AND_DISCONNECT || state == BluetoothState.BLE_CLOSED) {
            deviceSn = null
        }
        emit(mapOf("type" to "bleState", "state" to state, "name" to bleStateName(state)))
    }

    override fun onUpdateDialogBleList() =
        emit(mapOf("type" to "scanResults", "devices" to deviceList()))

    override fun onBatteryCharging() {
        charging = true
        emit(mapOf("type" to "battery", "level" to batteryLevel, "charging" to true, "full" to false))
    }

    override fun onBatteryQuery(level: Int) {
        charging = false
        batteryLevel = level
        emit(mapOf("type" to "battery", "level" to level, "charging" to false, "full" to false))
    }

    override fun onBatteryFull() {
        charging = true
        batteryLevel = 100
        emit(mapOf("type" to "battery", "level" to 100, "charging" to true, "full" to true))
    }

    override fun onDeviceInfo(info: DeviceInfo) {
        deviceSn = info.deviceId?.lowercase()
        emit(mapOf("type" to "deviceInfo", "deviceSn" to deviceSn, "deviceType" to info.deviceType))
    }

    override fun onReadDeviceInfoFailed() {
        deviceSn = null
        emit(mapOf("type" to "deviceInfoFailed"))
    }

    override fun onDeviceVersion(wareType: Int, version: String?) {
        when (wareType) {
            WareType.VER_FIRMWARE -> firmwareVersion = version
            WareType.VER_HARDWARE -> hardwareVersion = version
            WareType.VER_SOFTWARE -> softwareVersion = version
        }
        emit(mapOf("type" to "version", "kind" to wareType, "version" to version))
    }

    override fun onBpResult(systolic: Int, diastolic: Int, heartRate: Int) {
        emit(
            mapOf(
                "type" to "bpResult",
                "systolic" to systolic,
                "diastolic" to diastolic,
                "pulse" to heartRate,
                "deviceSn" to deviceSn,
                "firmwareVersion" to firmwareVersion,
                "sdkVersion" to SDK_VERSION,
                "measuredAtMillis" to System.currentTimeMillis(),
            )
        )
    }

    override fun onBpResultError() = emit(mapOf("type" to "bpError", "reason" to "calculation"))

    /** 0 = cuff leak (check tube/cuff); 1 = movement or talking made the measurement invalid. */
    override fun onLeakError(errorType: Int) =
        emit(mapOf("type" to "bpError", "reason" to if (errorType == 0) "leak" else "movement", "code" to errorType))
}
