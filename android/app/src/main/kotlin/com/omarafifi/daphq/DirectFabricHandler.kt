package com.omarafifi.daphq

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class DirectFabricHandler(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "com.omarafifi.daphq/direct_fabric"
        const val EVENT_CHANNEL = "com.omarafifi.daphq/direct_fabric/events"
        const val MANUFACTURER_ID = 0x4451 // 'DQ'

        val SERVICE_UUID: UUID = UUID.fromString("d4f90001-5b2e-4f13-9c12-446170687100")
        val CHAR_INFO_UUID: UUID = UUID.fromString("d4f90002-5b2e-4f13-9c12-446170687100")
        val CHAR_LINK_UUID: UUID = UUID.fromString("d4f90003-5b2e-4f13-9c12-446170687100")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val connectivityManager: ConnectivityManager? =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private val wifiManager: WifiManager? =
        appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val wifiP2pManager: WifiP2pManager? =
        appContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    @Volatile
    private var p2pChannel: WifiP2pManager.Channel? = null

    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var gattServer: BluetoothGattServer? = null

    @Volatile
    private var localInfoJson: String = "{}"
    private val subscribedDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val preparedWrites = ConcurrentHashMap<String, ByteArrayOutputStream>()

    private val networkLock = Any()
    private val networkSessionSeq = AtomicLong(0)
    @Volatile
    private var activeNetworkSessionId: Long = 0
    private var activeNetworkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile
    private var legacyWifiNetId: Int = -1

    private val gattClientLock = Any()
    private val gattSessionSeq = AtomicLong(0)
    private var activeClientGatt: BluetoothGatt? = null

    private val bleDiscoverySeq = AtomicLong(0)
    private val hostSessionSeq = AtomicLong(0)

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        initP2pChannel()
    }

    private fun initP2pChannel() {
        try {
            p2pChannel = wifiP2pManager?.initialize(appContext, Looper.getMainLooper()) {
                p2pChannel = null
                emitEvent(
                    mapOf(
                        "type" to "p2pState",
                        "state" to "disconnected",
                        "error" to "p2pChannelDisconnected",
                    ),
                )
            }
        } catch (_: Throwable) {
            p2pChannel = null
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitEvent(map: Map<String, Any?>) {
        mainHandler.post {
            try {
                eventSink?.success(map)
            } catch (_: Throwable) {}
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCapabilities" -> result.success(buildCapabilities())
            "startBleDiscovery" -> handleStartBleDiscovery(call, result)
            "stopBleDiscovery" -> {
                stopBle()
                result.success(null)
            }
            "startDirectHost" -> handleStartDirectHost(call, result)
            "connectDirectClient" -> handleConnectDirectClient(call, result)
            "exchangeGattLink" -> handleExchangeGattLink(call, result)
            "stopDirectSession" -> {
                stopDirectSessionInternal()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPerm(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(appContext, permission) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun hasBleScanPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPerm(Manifest.permission.BLUETOOTH_SCAN)
        } else {
            hasPerm(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    private fun hasBleAdvertisePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPerm(Manifest.permission.BLUETOOTH_ADVERTISE)
        } else {
            true
        }
    }

    private fun hasBleConnectPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            hasPerm(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            true
        }
    }

    private fun hasNearbyWifiPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            hasPerm(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            hasPerm(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    private fun buildCapabilities(): Map<String, Any> {
        val adapter = bluetoothManager?.adapter
        val hasBleFeature =
            appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val hasP2pFeature =
            appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
        val bleEnabled = hasBleFeature && adapter != null && adapter.isEnabled
        val wifiEnabled = try {
            wifiManager?.isWifiEnabled == true
        } catch (_: Throwable) {
            false
        }
        val supports5g = wifiEnabled && wifiManager != null &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP || wifiManager.is5GHzBandSupported)
        val canHost5g = wifiEnabled && hasP2pFeature && supports5g

        return mapOf(
            "hasWifi" to wifiEnabled,
            "hasBle" to bleEnabled,
            "canHostDirect5g" to canHost5g,
        )
    }

    @SuppressLint("MissingPermission")
    private fun handleStartBleDiscovery(call: MethodCall, result: MethodChannel.Result) {
        val adapter = bluetoothManager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.success(false)
            return
        }

        val manufacturerId = call.argument<Int>("manufacturerId") ?: MANUFACTURER_ID
        val payload = call.argument<ByteArray>("beaconPayload")
        val peerId = call.argument<String>("peerId") ?: ""
        val peerName = call.argument<String>("peerName") ?: "Android Device"
        val fingerprint = call.argument<String>("fingerprint") ?: ""
        if (payload == null || payload.size != 22) {
            result.success(false)
            return
        }

        localInfoJson = JSONObject().apply {
            put("peerId", peerId)
            put("name", peerName)
            put("fp", fingerprint)
            put("port", 62004)
            put("platform", "android")
        }.toString()

        stopBle()
        val discoveryToken = bleDiscoverySeq.incrementAndGet()

        var gattStarted = false
        if (hasBleConnectPermission()) {
            try {
                val server = bluetoothManager?.openGattServer(appContext, gattServerCallback)
                if (server != null) {
                    val service = BluetoothGattService(
                        SERVICE_UUID,
                        BluetoothGattService.SERVICE_TYPE_PRIMARY,
                    )
                    val infoChar = BluetoothGattCharacteristic(
                        CHAR_INFO_UUID,
                        BluetoothGattCharacteristic.PROPERTY_READ,
                        BluetoothGattCharacteristic.PERMISSION_READ,
                    )
                    val linkChar = BluetoothGattCharacteristic(
                        CHAR_LINK_UUID,
                        BluetoothGattCharacteristic.PROPERTY_WRITE or
                            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                        BluetoothGattCharacteristic.PERMISSION_WRITE,
                    )
                    val cccd = BluetoothGattDescriptor(
                        CCCD_UUID,
                        BluetoothGattDescriptor.PERMISSION_READ or
                            BluetoothGattDescriptor.PERMISSION_WRITE,
                    )
                    linkChar.addDescriptor(cccd)
                    service.addCharacteristic(infoChar)
                    service.addCharacteristic(linkChar)
                    gattStarted = server.addService(service)
                    gattServer = server
                }
            } catch (_: SecurityException) {
            } catch (_: Throwable) {}
        }

        var scanStarted = false
        if (hasBleScanPermission()) {
            try {
                val leScanner = adapter.bluetoothLeScanner
                if (leScanner != null) {
                    val filter = ScanFilter.Builder()
                        .setManufacturerData(
                            manufacturerId,
                            byteArrayOf(0x02),
                            byteArrayOf(0xFF.toByte()),
                        )
                        .build()
                    val scanSettings = ScanSettings.Builder()
                        .setScanMode(ScanSettings.SCAN_MODE_BALANCED)
                        .build()
                    val cb = object : ScanCallback() {
                        override fun onScanResult(callbackType: Int, scanResult: ScanResult?) {
                            val r = scanResult ?: return
                            val mfg =
                                r.scanRecord?.getManufacturerSpecificData(manufacturerId) ?: return
                            if (mfg.size != 22) return
                            val devName = try {
                                if (hasBleConnectPermission()) r.device?.name else null
                            } catch (_: SecurityException) {
                                null
                            } catch (_: Throwable) {
                                null
                            }
                            emitEvent(
                                mapOf(
                                    "type" to "bleBeacon",
                                    "address" to (r.device?.address ?: ""),
                                    "name" to (devName ?: r.scanRecord?.deviceName),
                                    "rssi" to r.rssi,
                                    "payload" to mfg,
                                ),
                            )
                        }

                        override fun onScanFailed(errorCode: Int) {
                            emitEvent(
                                mapOf(
                                    "type" to "radioState",
                                    "hasWifi" to (wifiManager?.isWifiEnabled == true),
                                    "hasBle" to adapter.isEnabled,
                                    "bleAdvertising" to (advertiser != null),
                                    "bleScanning" to false,
                                    "canHostDirect5g" to (wifiManager?.is5GHzBandSupported == true),
                                ),
                            )
                        }
                    }
                    leScanner.startScan(listOf(filter), scanSettings, cb)
                    scanner = leScanner
                    scanCallback = cb
                    scanStarted = true
                }
            } catch (_: SecurityException) {
            } catch (_: Throwable) {}
        }

        val resolved = AtomicBoolean(false)
        fun completeDiscovery(ok: Boolean) {
            if (resolved.compareAndSet(false, true)) {
                mainHandler.post { result.success(ok) }
            }
        }

        var advPending = false
        if (hasBleAdvertisePermission()) {
            try {
                val adv = adapter.bluetoothLeAdvertiser
                if (adv != null) {
                    val settings = AdvertiseSettings.Builder()
                        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                        .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                        .setConnectable(true)
                        .build()
                    val data = AdvertiseData.Builder()
                        .setIncludeDeviceName(false)
                        .setIncludeTxPowerLevel(false)
                        .addManufacturerData(manufacturerId, payload)
                        .build()
                    val cb = object : AdvertiseCallback() {
                        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                            if (bleDiscoverySeq.get() != discoveryToken) {
                                completeDiscovery(false)
                                return
                            }
                            completeDiscovery(true)
                        }

                        override fun onStartFailure(errorCode: Int) {
                            if (advertiseCallback === this) {
                                advertiser = null
                                advertiseCallback = null
                            }
                            if (bleDiscoverySeq.get() != discoveryToken) {
                                completeDiscovery(false)
                                return
                            }
                            completeDiscovery(scanStarted || gattStarted)
                        }
                    }
                    advertiser = adv
                    advertiseCallback = cb
                    advPending = true
                    adv.startAdvertising(settings, data, cb)
                }
            } catch (_: SecurityException) {
                advertiser = null
                advertiseCallback = null
                advPending = false
            } catch (_: Throwable) {
                advertiser = null
                advertiseCallback = null
                advPending = false
            }
        }

        if (!advPending) {
            completeDiscovery(scanStarted || gattStarted)
        } else {
            mainHandler.postDelayed({
                if (bleDiscoverySeq.get() == discoveryToken) {
                    completeDiscovery(scanStarted || gattStarted || advertiser != null)
                } else {
                    completeDiscovery(false)
                }
            }, 350)
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopBle() {
        bleDiscoverySeq.incrementAndGet()
        try {
            if (hasBleAdvertisePermission()) {
                advertiseCallback?.let { advertiser?.stopAdvertising(it) }
            }
        } catch (_: SecurityException) {
        } catch (_: Throwable) {}
        advertiseCallback = null
        advertiser = null

        try {
            if (hasBleScanPermission()) {
                scanCallback?.let { scanner?.stopScan(it) }
            }
        } catch (_: SecurityException) {
        } catch (_: Throwable) {}
        scanCallback = null
        scanner = null

        try {
            if (hasBleConnectPermission()) {
                gattServer?.close()
            }
        } catch (_: SecurityException) {
        } catch (_: Throwable) {}
        subscribedDevices.clear()
        preparedWrites.clear()
        gattServer = null
    }

    @SuppressLint("MissingPermission")
    private fun safeSendGattResponse(
        device: BluetoothDevice,
        requestId: Int,
        status: Int,
        offset: Int,
        value: ByteArray?,
    ) {
        try {
            if (hasBleConnectPermission()) {
                gattServer?.sendResponse(device, requestId, status, offset, value)
            }
        } catch (_: SecurityException) {
        } catch (_: Throwable) {}
    }

    private fun dispatchGattLinkJson(
        value: ByteArray,
        sourceBleAddress: String? = null,
    ): Boolean {
        return try {
            val json = JSONObject(String(value, Charsets.UTF_8))
            fun optNullableString(key: String): String? {
                if (!json.has(key) || json.isNull(key)) return null
                val v = json.optString(key, "")
                return v.ifEmpty { null }
            }
            val freq: Int? = if (json.has("frequencyMhz") && !json.isNull("frequencyMhz")) {
                json.optInt("frequencyMhz", 0).takeIf { it > 0 }
            } else {
                null
            }
            emitEvent(
                mapOf(
                    "type" to "gattLinkRequest",
                    "requestId" to (optNullableString("requestId") ?: ""),
                    "peerId" to (optNullableString("peerId") ?: ""),
                    "peerName" to (optNullableString("peerName") ?: "Nearby Peer"),
                    "peerFingerprint" to optNullableString("peerFingerprint"),
                    "action" to (optNullableString("action") ?: ""),
                    "ssid" to optNullableString("ssid"),
                    "psk" to optNullableString("psk"),
                    "hostIp" to optNullableString("hostIp"),
                    "port" to json.optInt("port", 62004),
                    "reverseConnect" to json.optBoolean("reverseConnect", false),
                    "frequencyMhz" to freq,
                    "reverseToken" to optNullableString("reverseToken"),
                    "sourceBleAddress" to sourceBleAddress,
                ),
            )
            true
        } catch (_: Throwable) {
            false
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            if (device != null && newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedDevices.remove(device.address)
                val prefix = "${device.address}:"
                for (k in preparedWrites.keys.filter { it.startsWith(prefix) }) {
                    preparedWrites.remove(k)
                }
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == CHAR_INFO_UUID) {
                val bytes = localInfoJson.toByteArray(Charsets.UTF_8)
                val slice = if (offset >= bytes.size) {
                    ByteArray(0)
                } else {
                    bytes.copyOfRange(offset, bytes.size)
                }
                safeSendGattResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
            } else {
                safeSendGattResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (descriptor.uuid == CCCD_UUID && value != null) {
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                    value.contentEquals(BluetoothGattDescriptor.ENABLE_INDICATION_VALUE)
                ) {
                    subscribedDevices[device.address] = device
                } else {
                    subscribedDevices.remove(device.address)
                }
            }
            if (responseNeeded) {
                safeSendGattResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (characteristic.uuid != CHAR_LINK_UUID || value == null) {
                if (responseNeeded) {
                    safeSendGattResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                }
                return
            }

            if (preparedWrite) {
                if (offset < 0 || offset + value.size > 8192) {
                    if (responseNeeded) {
                        safeSendGattResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH,
                            offset,
                            null,
                        )
                    }
                    return
                }
                val key = "${device.address}:${characteristic.uuid}"
                val stream = preparedWrites.computeIfAbsent(key) { ByteArrayOutputStream() }
                synchronized(stream) {
                    if (offset == 0) {
                        stream.reset()
                    }
                    if (offset > stream.size()) {
                        stream.write(ByteArray(offset - stream.size()))
                    }
                    if (offset == stream.size()) {
                        stream.write(value)
                    }
                }
                if (responseNeeded) {
                    safeSendGattResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                }
                return
            }

            val ok = dispatchGattLinkJson(value, device.address)
            if (responseNeeded) {
                safeSendGattResponse(
                    device,
                    requestId,
                    if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                    offset,
                    if (ok) value else null,
                )
            }
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val prefix = "${device.address}:"
            val keys = preparedWrites.keys.filter { it.startsWith(prefix) }
            var ok = true
            for (k in keys) {
                val stream = preparedWrites.remove(k)
                if (execute && stream != null && k.endsWith(CHAR_LINK_UUID.toString())) {
                    val bytes = synchronized(stream) { stream.toByteArray() }
                    if (!dispatchGattLinkJson(bytes, device.address)) {
                        ok = false
                    }
                }
            }
            safeSendGattResponse(
                device,
                requestId,
                if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                0,
                null,
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleExchangeGattLink(call: MethodCall, result: MethodChannel.Result) {
        val address = call.argument<String>("bleAddress")
        val payloadMap = call.argument<Map<String, Any?>>("payload")
        val adapter = bluetoothManager?.adapter
        if (address.isNullOrBlank() || payloadMap == null || adapter == null || !hasBleConnectPermission()) {
            result.success(null)
            return
        }

        val jsonBytes = JSONObject(payloadMap).toString().toByteArray(Charsets.UTF_8)
        val finished = AtomicBoolean(false)
        val myGattToken = gattSessionSeq.incrementAndGet()
        var sessionGatt: BluetoothGatt? = null

        val timeoutRunnable = object : Runnable {
            override fun run() {
                if (finished.compareAndSet(false, true)) {
                    synchronized(gattClientLock) {
                        try {
                            sessionGatt?.close()
                        } catch (_: SecurityException) {
                        } catch (_: Throwable) {}
                        if (activeClientGatt === sessionGatt) {
                            activeClientGatt = null
                        }
                    }
                    mainHandler.post { result.success(null) }
                }
            }
        }

        fun closeGattSafely(gatt: BluetoothGatt?) {
            if (gatt == null) return
            synchronized(gattClientLock) {
                try {
                    gatt.close()
                } catch (_: SecurityException) {
                } catch (_: Throwable) {}
                if (activeClientGatt === gatt) {
                    activeClientGatt = null
                }
            }
        }

        fun completeOnce(gatt: BluetoothGatt?, res: Map<String, Any?>?) {
            mainHandler.removeCallbacks(timeoutRunnable)
            if (finished.compareAndSet(false, true)) {
                closeGattSafely(gatt)
                mainHandler.post { result.success(res) }
            }
        }

        mainHandler.postDelayed(timeoutRunnable, 9000)

        try {
            synchronized(gattClientLock) {
                try {
                    activeClientGatt?.close()
                } catch (_: Throwable) {}
                activeClientGatt = null
            }

            val device = adapter.getRemoteDevice(address)
            val callback = object : BluetoothGattCallback() {
                private var remoteInfo: JSONObject? = null
                private var mtuStepDone = false

                override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                    if (gattSessionSeq.get() != myGattToken || finished.get()) {
                        closeGattSafely(gatt)
                        return
                    }
                    if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                        val mtuRequested = try {
                            gatt.requestMtu(512)
                        } catch (_: SecurityException) {
                            false
                        }
                        if (!mtuRequested) {
                            mtuStepDone = true
                            val disc = try {
                                gatt.discoverServices()
                            } catch (_: SecurityException) {
                                false
                            }
                            if (!disc) {
                                completeOnce(gatt, null)
                            }
                        }
                    } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                        completeOnce(gatt, null)
                    }
                }

                override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                    if (gattSessionSeq.get() != myGattToken) {
                        completeOnce(gatt, null)
                        return
                    }
                    if (finished.get() || mtuStepDone) return
                    mtuStepDone = true
                    val disc = try {
                        gatt.discoverServices()
                    } catch (_: SecurityException) {
                        false
                    }
                    if (!disc) {
                        completeOnce(gatt, null)
                    }
                }

                override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                    if (gattSessionSeq.get() != myGattToken) {
                        completeOnce(gatt, null)
                        return
                    }
                    if (finished.get()) return
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        completeOnce(gatt, null)
                        return
                    }
                    val svc = gatt.getService(SERVICE_UUID)
                    if (svc == null) {
                        completeOnce(gatt, null)
                        return
                    }
                    val infoChar = svc.getCharacteristic(CHAR_INFO_UUID)
                    val readOk = if (infoChar != null) {
                        try {
                            gatt.readCharacteristic(infoChar)
                        } catch (_: SecurityException) {
                            false
                        }
                    } else {
                        false
                    }
                    if (!readOk) {
                        writeLinkPayload(gatt, svc.getCharacteristic(CHAR_LINK_UUID))
                    }
                }

                @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
                override fun onCharacteristicRead(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    status: Int,
                ) {
                    val value = characteristic.value ?: ByteArray(0)
                    handleInfoRead(gatt, value, status)
                }

                override fun onCharacteristicRead(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    value: ByteArray,
                    status: Int,
                ) {
                    handleInfoRead(gatt, value, status)
                }

                private fun handleInfoRead(gatt: BluetoothGatt, value: ByteArray, status: Int) {
                    if (gattSessionSeq.get() != myGattToken) {
                        completeOnce(gatt, null)
                        return
                    }
                    if (finished.get()) return
                    if (status == BluetoothGatt.GATT_SUCCESS && value.isNotEmpty()) {
                        try {
                            remoteInfo = JSONObject(String(value, Charsets.UTF_8))
                        } catch (_: Throwable) {}
                    }
                    val linkChar = gatt.getService(SERVICE_UUID)?.getCharacteristic(CHAR_LINK_UUID)
                    writeLinkPayload(gatt, linkChar)
                }

                private fun writeLinkPayload(gatt: BluetoothGatt, linkChar: BluetoothGattCharacteristic?) {
                    if (linkChar == null) {
                        completeOnce(gatt, null)
                        return
                    }
                    val writeStarted = try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            gatt.writeCharacteristic(
                                linkChar,
                                jsonBytes,
                                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                            ) == BluetoothStatusCodes.SUCCESS
                        } else {
                            @Suppress("DEPRECATION")
                            linkChar.value = jsonBytes
                            @Suppress("DEPRECATION")
                            linkChar.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                            @Suppress("DEPRECATION")
                            gatt.writeCharacteristic(linkChar)
                        }
                    } catch (_: SecurityException) {
                        false
                    } catch (_: Throwable) {
                        false
                    }
                    if (!writeStarted) {
                        completeOnce(gatt, null)
                    }
                }

                override fun onCharacteristicWrite(
                    gatt: BluetoothGatt,
                    characteristic: BluetoothGattCharacteristic,
                    status: Int,
                ) {
                    if (gattSessionSeq.get() != myGattToken) {
                        completeOnce(gatt, null)
                        return
                    }
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        completeOnce(gatt, null)
                        return
                    }
                    val out = mutableMapOf<String, Any?>("ok" to true)
                    remoteInfo?.let { info ->
                        out["peerId"] = info.optString("peerId", "")
                        out["name"] = info.optString("name", "")
                        out["fp"] = info.optString("fp", "")
                        out["port"] = info.optInt("port", 62004)
                        out["platform"] = info.optString("platform", "unknown")
                    }
                    try {
                        gatt.disconnect()
                    } catch (_: SecurityException) {}
                    completeOnce(gatt, out)
                }
            }

            sessionGatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, callback, BluetoothDevice.TRANSPORT_LE)
            } else {
                device.connectGatt(appContext, false, callback)
            }
            if (sessionGatt == null) {
                completeOnce(null, null)
                return
            }
            synchronized(gattClientLock) {
                if (!finished.get() && gattSessionSeq.get() == myGattToken) {
                    activeClientGatt = sessionGatt
                } else {
                    try {
                        sessionGatt?.close()
                    } catch (_: Throwable) {}
                }
            }
        } catch (_: SecurityException) {
            completeOnce(sessionGatt, null)
        } catch (_: Throwable) {
            completeOnce(sessionGatt, null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleStartDirectHost(call: MethodCall, result: MethodChannel.Result) {
        if (p2pChannel == null) initP2pChannel()
        val mgr = wifiP2pManager
        val ch = p2pChannel
        if (mgr == null || ch == null || !hasNearbyWifiPermission()) {
            result.success(null)
            return
        }

        val prefer5Ghz = call.argument<Boolean>("prefer5Ghz") ?: true
        val done = AtomicBoolean(false)
        val myHostToken = hostSessionSeq.incrementAndGet()

        val timeoutRunnable = object : Runnable {
            override fun run() {
                if (hostSessionSeq.get() != myHostToken) {
                    if (done.compareAndSet(false, true)) {
                        mainHandler.post { result.success(null) }
                    }
                    return
                }
                if (done.compareAndSet(false, true)) {
                    try {
                        if (hasNearbyWifiPermission()) {
                            mgr.removeGroup(ch, null)
                        }
                    } catch (_: Throwable) {}
                    mainHandler.post { result.success(null) }
                }
            }
        }

        fun finish(res: Map<String, Any>?) {
            mainHandler.removeCallbacks(timeoutRunnable)
            if (done.compareAndSet(false, true)) {
                mainHandler.post { result.success(res) }
            }
        }

        mainHandler.postDelayed(timeoutRunnable, 12000)

        fun fetchGroupDetails() {
            var retries = 0
            fun poll() {
                if (hostSessionSeq.get() != myHostToken) {
                    finish(null)
                    return
                }
                if (done.get()) return
                mgr.requestGroupInfo(ch) { group: WifiP2pGroup? ->
                    if (hostSessionSeq.get() != myHostToken) {
                        finish(null)
                        return@requestGroupInfo
                    }
                    if (done.get()) return@requestGroupInfo
                    if (group != null && !group.networkName.isNullOrBlank() && !group.passphrase.isNullOrBlank()) {
                        val resolvedIp = resolveP2pInterfaceIp()
                        if (resolvedIp == null && retries < 4 && !done.get()) {
                            retries++
                            mainHandler.postDelayed({ poll() }, 250)
                            return@requestGroupInfo
                        }
                        val hostIp = resolvedIp ?: "192.168.49.1"
                        val freq = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            group.frequency.takeIf { it > 0 } ?: (if (prefer5Ghz) 5180 else 2437)
                        } else {
                            2437
                        }
                        val info = mapOf(
                            "ssid" to group.networkName,
                            "psk" to group.passphrase,
                            "hostIp" to hostIp,
                            "frequencyMhz" to freq,
                        )
                        emitEvent(
                            mapOf(
                                "type" to "p2pState",
                                "state" to "hostReady",
                                "ssid" to group.networkName,
                                "psk" to group.passphrase,
                                "localIp" to hostIp,
                            ),
                        )
                        finish(info)
                    } else if (retries < 16 && !done.get()) {
                        retries++
                        mainHandler.postDelayed({ poll() }, 250)
                    } else {
                        finish(null)
                    }
                }
            }
            mainHandler.postDelayed({ poll() }, 300)
        }

        fun createGroupWithFallback(attempt: Int) {
            if (hostSessionSeq.get() != myHostToken) {
                finish(null)
                return
            }
            if (done.get()) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    val suffix = randomAlnum(4)
                    val psk = randomPassphrase(12)
                    val band = if (prefer5Ghz) {
                        WifiP2pConfig.GROUP_OWNER_BAND_5GHZ
                    } else {
                        WifiP2pConfig.GROUP_OWNER_BAND_AUTO
                    }
                    val config = WifiP2pConfig.Builder()
                        .setNetworkName("DIRECT-DQ-$suffix")
                        .setPassphrase(psk)
                        .setGroupOperatingBand(band)
                        .build()
                    mgr.createGroup(ch, config, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() = fetchGroupDetails()
                        override fun onFailure(reason: Int) {
                            if (hostSessionSeq.get() != myHostToken) {
                                finish(null)
                                return
                            }
                            if (done.get()) return
                            if (reason == WifiP2pManager.BUSY && attempt < 2) {
                                mainHandler.postDelayed({ createGroupWithFallback(attempt + 1) }, 350)
                                return
                            }
                            mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
                                override fun onSuccess() = fetchGroupDetails()
                                override fun onFailure(r2: Int) {
                                    if (hostSessionSeq.get() != myHostToken) {
                                        finish(null)
                                        return
                                    }
                                    if (done.get()) return
                                    if (r2 == WifiP2pManager.BUSY && attempt < 2) {
                                        mainHandler.postDelayed({ createGroupWithFallback(attempt + 1) }, 350)
                                    } else {
                                        finish(null)
                                    }
                                }
                            })
                        }
                    })
                    return
                } catch (_: Throwable) {}
            }

            mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = fetchGroupDetails()
                override fun onFailure(reason: Int) {
                    if (hostSessionSeq.get() != myHostToken) {
                        finish(null)
                        return
                    }
                    if (done.get()) return
                    if (reason == WifiP2pManager.BUSY && attempt < 2) {
                        mainHandler.postDelayed({ createGroupWithFallback(attempt + 1) }, 350)
                    } else {
                        finish(null)
                    }
                }
            })
        }

        try {
            mgr.requestGroupInfo(ch) { existingGroup ->
                if (hostSessionSeq.get() != myHostToken) {
                    finish(null)
                    return@requestGroupInfo
                }
                if (done.get()) return@requestGroupInfo
                if (existingGroup != null) {
                    mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() {
                            if (hostSessionSeq.get() != myHostToken) {
                                finish(null)
                                return
                            }
                            mainHandler.postDelayed({ createGroupWithFallback(0) }, 250)
                        }
                        override fun onFailure(reason: Int) {
                            if (hostSessionSeq.get() != myHostToken) {
                                finish(null)
                                return
                            }
                            mainHandler.postDelayed({ createGroupWithFallback(0) }, 250)
                        }
                    })
                } else {
                    createGroupWithFallback(0)
                }
            }
        } catch (_: SecurityException) {
            finish(null)
        } catch (_: Throwable) {
            finish(null)
        }
    }

    private fun handleConnectDirectClient(call: MethodCall, result: MethodChannel.Result) {
        val cm = connectivityManager
        val ssid = call.argument<String>("ssid")
        val psk = call.argument<String>("psk")
        val expectedGateway = call.argument<String>("expectedGatewayIp") ?: "192.168.49.1"

        if (cm == null || ssid.isNullOrBlank() || psk.isNullOrBlank()) {
            result.success(null)
            return
        }

        unregisterActiveNetworkCallback()
        val mySessionId = synchronized(networkLock) {
            val next = networkSessionSeq.incrementAndGet()
            activeNetworkSessionId = next
            next
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            connectLegacyWifiClient(ssid, psk, expectedGateway, mySessionId, result)
            return
        }

        val done = AtomicBoolean(false)
        lateinit var timeoutRunnable: Runnable
        fun finish(res: Map<String, Any>?) {
            mainHandler.removeCallbacks(timeoutRunnable)
            if (done.compareAndSet(false, true)) {
                mainHandler.post { result.success(res) }
            }
        }

        timeoutRunnable = Runnable {
            synchronized(networkLock) {
                if (activeNetworkSessionId == mySessionId) {
                    unregisterActiveNetworkCallbackLocked()
                }
            }
            finish(null)
        }
        mainHandler.postDelayed(timeoutRunnable, 15500)

        try {
            val specifier = WifiNetworkSpecifier.Builder()
                .setSsid(ssid)
                .setWpa2Passphrase(psk)
                .build()

            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()

            val callback = object : ConnectivityManager.NetworkCallback() {
                private fun tryResolveFromLinkProps(props: LinkProperties?) {
                    if (activeNetworkSessionId != mySessionId || done.get()) return
                    val ipv4 = props?.linkAddresses
                        ?.map { it.address }
                        ?.filterIsInstance<Inet4Address>()
                        ?.firstOrNull { !it.isLinkLocalAddress && !it.isLoopbackAddress }
                        ?.hostAddress
                    if (ipv4.isNullOrEmpty()) return
                    val gwIp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        props.dhcpServerAddress?.hostAddress ?: expectedGateway
                    } else {
                        expectedGateway
                    }
                    emitEvent(
                        mapOf(
                            "type" to "p2pState",
                            "state" to "connected",
                            "ssid" to ssid,
                            "localIp" to ipv4,
                            "gatewayIp" to gwIp,
                        ),
                    )
                    finish(mapOf("localIp" to ipv4, "gatewayIp" to gwIp))
                }

                override fun onAvailable(network: Network) {
                    if (activeNetworkSessionId != mySessionId) return
                    cm.bindProcessToNetwork(network)
                    tryResolveFromLinkProps(cm.getLinkProperties(network))
                }

                override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
                    tryResolveFromLinkProps(linkProperties)
                }

                override fun onUnavailable() {
                    synchronized(networkLock) {
                        if (activeNetworkSessionId == mySessionId) {
                            cm.bindProcessToNetwork(null)
                        }
                    }
                    finish(null)
                }

                override fun onLost(network: Network) {
                    val isCurrent = synchronized(networkLock) {
                        activeNetworkCallback === this && activeNetworkSessionId == mySessionId
                    }
                    if (!isCurrent) return
                    cm.bindProcessToNetwork(null)
                    emitEvent(mapOf("type" to "p2pState", "state" to "disconnected"))
                    finish(null)
                }
            }

            synchronized(networkLock) {
                activeNetworkCallback = callback
            }
            cm.requestNetwork(request, callback, 15000)
        } catch (_: Throwable) {
            synchronized(networkLock) {
                if (activeNetworkSessionId == mySessionId) {
                    cm.bindProcessToNetwork(null)
                }
            }
            finish(null)
        }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun connectLegacyWifiClient(
        ssid: String,
        psk: String,
        expectedGateway: String,
        mySessionId: Long,
        result: MethodChannel.Result,
    ) {
        val wm = wifiManager
        if (wm == null || !hasNearbyWifiPermission()) {
            result.success(null)
            return
        }
        val conf = android.net.wifi.WifiConfiguration().apply {
            SSID = "\"$ssid\""
            preSharedKey = "\"$psk\""
            allowedKeyManagement.set(android.net.wifi.WifiConfiguration.KeyMgmt.WPA_PSK)
        }
        val netId = wm.addNetwork(conf)
        if (netId == -1 || !wm.enableNetwork(netId, true) || !wm.reconnect()) {
            if (netId != -1) wm.removeNetwork(netId)
            result.success(null)
            return
        }
        legacyWifiNetId = netId
        val done = AtomicBoolean(false)
        lateinit var timeoutRunnable: Runnable
        fun finishLegacy(res: Map<String, String>?) {
            mainHandler.removeCallbacks(timeoutRunnable)
            if (done.compareAndSet(false, true)) {
                mainHandler.post { result.success(res) }
            }
        }
        timeoutRunnable = Runnable {
            wm.removeNetwork(netId)
            if (legacyWifiNetId == netId) legacyWifiNetId = -1
            finishLegacy(null)
        }
        mainHandler.postDelayed(timeoutRunnable, 15500)

        var attempts = 0
        fun pollLegacy() {
            if (activeNetworkSessionId != mySessionId) {
                wm.removeNetwork(netId)
                if (legacyWifiNetId == netId) legacyWifiNetId = -1
                finishLegacy(null)
                return
            }
            if (done.get()) return
            val info = wm.connectionInfo
            val dhcp = wm.dhcpInfo
            val ipInt = dhcp?.ipAddress ?: 0
            if (info?.ssid == "\"$ssid\"" && ipInt != 0) {
                val localIp = formatIpv4Int(ipInt)
                val gwIp = formatIpv4Int(dhcp.gateway).ifEmpty { expectedGateway }
                emitEvent(
                    mapOf(
                        "type" to "p2pState",
                        "state" to "connected",
                        "ssid" to ssid,
                        "localIp" to localIp,
                        "gatewayIp" to gwIp,
                    ),
                )
                finishLegacy(mapOf("localIp" to localIp, "gatewayIp" to gwIp))
            } else if (attempts < 30 && !done.get()) {
                attempts++
                mainHandler.postDelayed({ pollLegacy() }, 400)
            } else {
                wm.removeNetwork(netId)
                if (legacyWifiNetId == netId) legacyWifiNetId = -1
                finishLegacy(null)
            }
        }
        mainHandler.postDelayed({ pollLegacy() }, 400)
    }

    private fun formatIpv4Int(addr: Int): String {
        if (addr == 0) return ""
        return "${addr and 0xff}.${addr shr 8 and 0xff}.${addr shr 16 and 0xff}.${addr shr 24 and 0xff}"
    }

    private fun unregisterActiveNetworkCallback() {
        synchronized(networkLock) {
            unregisterActiveNetworkCallbackLocked()
        }
    }

    @Suppress("DEPRECATION")
    private fun unregisterActiveNetworkCallbackLocked() {
        try {
            connectivityManager?.bindProcessToNetwork(null)
        } catch (_: Throwable) {}
        activeNetworkCallback?.let { cb ->
            try {
                connectivityManager?.unregisterNetworkCallback(cb)
            } catch (_: Throwable) {}
        }
        activeNetworkCallback = null
        val oldLegacy = legacyWifiNetId
        if (oldLegacy != -1) {
            legacyWifiNetId = -1
            try {
                wifiManager?.removeNetwork(oldLegacy)
            } catch (_: Throwable) {}
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopDirectSessionInternal() {
        hostSessionSeq.incrementAndGet()
        synchronized(networkLock) {
            activeNetworkSessionId = networkSessionSeq.incrementAndGet()
            unregisterActiveNetworkCallbackLocked()
        }
        try {
            if (hasNearbyWifiPermission()) {
                p2pChannel?.let { ch ->
                    wifiP2pManager?.removeGroup(ch, null)
                }
            }
        } catch (_: SecurityException) {
        } catch (_: Throwable) {}
    }

    fun destroy() {
        stopBle()
        stopDirectSessionInternal()
        synchronized(gattClientLock) {
            gattSessionSeq.incrementAndGet()
            try {
                activeClientGatt?.close()
            } catch (_: Throwable) {}
            activeClientGatt = null
        }
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    private fun resolveP2pInterfaceIp(): String? {
        return try {
            val ifaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { it.isUp && !it.isLoopback }
            fun firstIpv4(list: List<NetworkInterface>): String? = list
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                ?.hostAddress

            val p2pIfaces = ifaces.filter { it.name.lowercase().contains("p2p") }
            firstIpv4(p2pIfaces)?.let { return it }

            val softApIfaces = ifaces.filter {
                val n = it.name.lowercase()
                n.contains("swlan") || n.contains("softap") ||
                    n.startsWith("ap") || n.contains("ap0")
            }
            firstIpv4(softApIfaces)
        } catch (_: Throwable) {
            null
        }
    }

    private fun randomAlnum(length: Int): String {
        val chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val rng = SecureRandom()
        return buildString(length) {
            repeat(length) { append(chars[rng.nextInt(chars.length)]) }
        }
    }

    private fun randomPassphrase(length: Int): String {
        val chars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val rng = SecureRandom()
        return buildString(length) {
            repeat(length) { append(chars[rng.nextInt(chars.length)]) }
        }
    }
}
