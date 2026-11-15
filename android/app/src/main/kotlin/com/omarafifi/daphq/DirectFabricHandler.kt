package com.omarafifi.daphq

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

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
    private val locationManager: LocationManager? =
        appContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    @Volatile
    private var p2pChannel: WifiP2pManager.Channel? = null
    @Volatile
    private var radioReceiverRegistered: Boolean = false
    private val direct5gHostUnsupported = AtomicBoolean(false)
    private val directPrefs: SharedPreferences by lazy {
        appContext.getSharedPreferences("daphq_direct_prefs", Context.MODE_PRIVATE)
    }

    private fun direct5gPrefKey(): String {
        val iso = try {
            val tm = appContext.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            val netCountry = tm?.networkCountryIso?.trim()?.uppercase(Locale.US)?.takeIf { it.length == 2 }
            val simCountry = tm?.simCountryIso?.trim()?.uppercase(Locale.US)?.takeIf { it.length == 2 }
            val localeCountry = Locale.getDefault().country.trim().uppercase(Locale.US).takeIf { it.length == 2 }
            netCountry ?: simCountry ?: localeCountry ?: "ZZ"
        } catch (_: Throwable) {
            "ZZ"
        }
        return "direct5g_unsupported_api${Build.VERSION.SDK_INT}_$iso"
    }

    private fun markDirect5gHostUnsupported() {
        try {
            directPrefs.edit().putBoolean(direct5gPrefKey(), true).apply()
        } catch (_: Throwable) {}
        if (direct5gHostUnsupported.compareAndSet(false, true)) {
            val radioEvent = HashMap<String, Any?>()
            radioEvent["type"] = "radioState"
            radioEvent.putAll(buildCapabilities())
            emitEvent(radioEvent)
        }
    }

    private val radioStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val event = HashMap<String, Any?>()
            event["type"] = "radioState"
            event.putAll(buildCapabilities())
            emitEvent(event)
        }
    }

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
    private val lohsLock = Any()
    private var activeLohsReservation: WifiManager.LocalOnlyHotspotReservation? = null

    init {
        try {
            if (directPrefs.getBoolean(direct5gPrefKey(), false)) {
                direct5gHostUnsupported.set(true)
            }
        } catch (_: Throwable) {}
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        initP2pChannel()
        registerRadioReceiver()
    }

    private fun registerRadioReceiver() {
        if (radioReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(WifiManager.WIFI_STATE_CHANGED_ACTION)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(LocationManager.MODE_CHANGED_ACTION)
        }
        try {
            ContextCompat.registerReceiver(
                appContext,
                radioStateReceiver,
                filter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            radioReceiverRegistered = true
        } catch (_: Throwable) {}
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
            "getDirectHostClients" -> result.success(emptyList<String>())
            "stopDirectSession" -> {
                stopDirectSessionInternal()
                result.success(null)
            }
            "setTransferPowerLock" -> {
                val enabled = when (val raw = call.arguments) {
                    is Boolean -> raw
                    is Map<*, *> -> raw["enabled"] as? Boolean ?: false
                    else -> false
                }
                if (enabled) acquireTransferLocks() else releaseTransferLocks()
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

    private fun isOsLocationEnabled(): Boolean {
        val lm = locationManager ?: return false
        return try {
            LocationManagerCompat.isLocationEnabled(lm)
        } catch (_: Throwable) {
            false
        }
    }

    private fun buildCapabilities(): Map<String, Any> {
        val adapter = bluetoothManager?.adapter
        val hasBleFeature =
            appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val hasWifiHardware = wifiManager != null ||
            appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI)
        val hasP2pFeature =
            appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)

        val wifiEnabled = try {
            wifiManager?.isWifiEnabled == true
        } catch (_: Throwable) {
            false
        }
        val bluetoothHardware = hasBleFeature && adapter != null
        val bluetoothEnabled = try {
            bluetoothHardware && (adapter?.isEnabled == true)
        } catch (_: Throwable) {
            false
        }

        val missingWifiPerm = !hasNearbyWifiPermission()
        val missingBlePerm = !(hasBleScanPermission() &&
            hasBleAdvertisePermission() &&
            hasBleConnectPermission())

        val osLocationEnabled = isOsLocationEnabled()
        val wifiLocationOk =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU || osLocationEnabled
        val bleLocationOk =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S || osLocationEnabled

        val effectiveHasWifi = wifiEnabled && !missingWifiPerm && wifiLocationOk
        val effectiveHasBle = bluetoothEnabled && !missingBlePerm && bleLocationOk
        val canHost5g = effectiveHasWifi && resolveCanHostDirect5g(hasP2pFeature)

        return mapOf(
            "hasWifi" to effectiveHasWifi,
            "hasBle" to effectiveHasBle,
            "canHostDirect5g" to canHost5g,
            "wifiHardwarePresent" to hasWifiHardware,
            "bluetoothHardwarePresent" to bluetoothHardware,
            "wifiEnabled" to wifiEnabled,
            "bluetoothEnabled" to bluetoothEnabled,
            "missingWifiPermission" to missingWifiPerm,
            "missingBlePermission" to missingBlePerm,
            "locationServiceEnabled" to wifiLocationOk,
        )
    }

    private fun resolveCanHostDirect5g(hasP2pFeature: Boolean): Boolean {
        val wm = wifiManager ?: return false
        if (!hasP2pFeature || direct5gHostUnsupported.get()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && !wm.is5GHzBandSupported) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && hasNearbyWifiPermission()) {
            try {
                val sapUsable = wm.getUsableChannels(
                    2,
                    android.net.wifi.WifiAvailableChannel.OP_MODE_SAP,
                )
                val goUsable = wm.getUsableChannels(
                    2,
                    android.net.wifi.WifiAvailableChannel.OP_MODE_WIFI_DIRECT_GO,
                )
                val hasSap5g = sapUsable.any { it.frequencyMhz >= 4900 }
                val hasGo5g = goUsable.any { it.frequencyMhz >= 4900 }
                if (!hasSap5g && !hasGo5g) return false
            } catch (_: SecurityException) {
            } catch (_: Throwable) {}
        }
        return true
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

        val transferPort =
            ((payload[18].toInt() and 0xFF) shl 8) or (payload[19].toInt() and 0xFF)
        val effectivePort = if (transferPort in 1..65535) transferPort else 62004

        localInfoJson = JSONObject().apply {
            put("peerId", peerId)
            put("name", peerName)
            put("fp", fingerprint)
            put("port", effectivePort)
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
                            val event = HashMap<String, Any?>()
                            event["type"] = "radioState"
                            event.putAll(buildCapabilities())
                            event["hasBle"] = adapter.isEnabled
                            event["bleAdvertising"] = (advertiser != null)
                            event["bleScanning"] = false
                            emitEvent(event)
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
        val allow24GhzFallback = call.argument<Boolean>("allow24GhzFallback") ?: true
        val rawStableTag = call.argument<String>("stableTag")
        val cleanTag = sanitizeStableDirectTag(rawStableTag)
        if (prefer5Ghz && !allow24GhzFallback && direct5gHostUnsupported.get()) {
            result.success(null)
            return
        }
        acquireTransferLocks()
        closeActiveLohsReservation()
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
                    closeActiveLohsReservation()
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

        mainHandler.postDelayed(timeoutRunnable, 18000L)

        fun isStaleOrDone(): Boolean {
            if (hostSessionSeq.get() != myHostToken) {
                finish(null)
                return true
            }
            return done.get()
        }

        fun removeGroupThen(delayMs: Long = 250L, next: () -> Unit) {
            try {
                if (!hasNearbyWifiPermission()) {
                    finish(null)
                    return
                }
                mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        if (isStaleOrDone()) return
                        mainHandler.postDelayed(next, delayMs)
                    }

                    override fun onFailure(reason: Int) {
                        if (isStaleOrDone()) return
                        mainHandler.postDelayed(next, delayMs)
                    }
                })
            } catch (_: Throwable) {
                if (!isStaleOrDone()) {
                    mainHandler.postDelayed(next, delayMs)
                }
            }
        }

        fun emitReadyAndFinish(ssid: String, psk: String, hostIp: String, freqMhz: Int) {
            if (prefer5Ghz && freqMhz in 1..4899) {
                markDirect5gHostUnsupported()
            }
            emitEvent(
                mapOf(
                    "type" to "p2pState",
                    "state" to "hostReady",
                    "ssid" to ssid,
                    "psk" to psk,
                    "localIp" to hostIp,
                ),
            )
            finish(
                mapOf(
                    "ssid" to ssid,
                    "psk" to psk,
                    "hostIp" to hostIp,
                    "frequencyMhz" to freqMhz,
                ),
            )
        }

        val wm = wifiManager
        val staApConcurrent = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            wm?.isStaApConcurrencySupported == true
        val hasBleActive = (advertiser != null && advertiseCallback != null) ||
            (scanner != null && scanCallback != null)
        val canReplaceSlowP2pWithHotspot = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            wm != null &&
            (staApConcurrent || hasBleActive)
        val canTrySoftAp5Ghz = Build.VERSION.SDK_INT >= 36 &&
            wm != null &&
            wm.is5GHzBandSupported &&
            (staApConcurrent || hasBleActive)

        // Android 16 (API 36+) SoftAP with explicit BAND_5GHZ comes first in
        // handleStartDirectHost; for P2P stages iterate 5GHz band + usable UNII-1/3 channels.
        fun buildP2pConfig(mode: Int, explicitFreqMhz: Int = 0): WifiP2pConfig? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
            val suffix = if (cleanTag.length >= 2) cleanTag else randomAlnum(4)
            val psk = randomPassphrase(12)
            val builder = WifiP2pConfig.Builder()
                .setNetworkName("DIRECT-DQ-$suffix")
                .setPassphrase(psk)
            when {
                explicitFreqMhz > 0 -> builder.setGroupOperatingFrequency(explicitFreqMhz)
                mode == 0 -> builder.setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_5GHZ)
                mode == 1 -> builder.setGroupOperatingFrequency(5180)
                mode == 2 -> builder.setGroupOperatingFrequency(5745)
                else -> builder.setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.enablePersistentMode(false)
            }
            return builder.build()
        }

        fun runP2pMode(
            mode: Int,
            attempt: Int,
            reject24Ghz: Boolean,
            onRejectOrFail: () -> Unit,
            explicitFreqMhz: Int = 0,
        ) {
            if (isStaleOrDone()) return

            fun fetchGroupDetails() {
                var retries = 0
                fun poll() {
                    if (isStaleOrDone()) return
                    mgr.requestGroupInfo(ch) { group: WifiP2pGroup? ->
                        if (isStaleOrDone()) return@requestGroupInfo
                        if (group != null && !group.networkName.isNullOrBlank() && !group.passphrase.isNullOrBlank()) {
                            val freq = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                group.frequency.takeIf { it > 0 } ?: 0
                            } else {
                                0
                            }
                            if (reject24Ghz && freq in 1..4899) {
                                removeGroupThen(250L, onRejectOrFail)
                                return@requestGroupInfo
                            }
                            val resolvedIp = resolveP2pInterfaceIp()
                            if (resolvedIp == null && retries < 4 && !done.get()) {
                                retries++
                                mainHandler.postDelayed({ poll() }, 250)
                                return@requestGroupInfo
                            }
                            val hostIp = resolvedIp ?: "192.168.49.1"
                            emitReadyAndFinish(group.networkName, group.passphrase, hostIp, freq)
                        } else if (retries < 16 && !done.get()) {
                            retries++
                            mainHandler.postDelayed({ poll() }, 250)
                        } else {
                            onRejectOrFail()
                        }
                    }
                }
                mainHandler.postDelayed({ poll() }, 300)
            }

            val listener = object : WifiP2pManager.ActionListener {
                override fun onSuccess() = fetchGroupDetails()
                override fun onFailure(reason: Int) {
                    if (isStaleOrDone()) return
                    if (reason == WifiP2pManager.BUSY && attempt < 3) {
                        mainHandler.postDelayed(
                            {
                                runP2pMode(
                                    mode,
                                    attempt + 1,
                                    reject24Ghz,
                                    onRejectOrFail,
                                    explicitFreqMhz,
                                )
                            },
                            350,
                        )
                    } else {
                        onRejectOrFail()
                    }
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    val config = buildP2pConfig(mode, explicitFreqMhz)
                    if (config != null) {
                        mgr.createGroup(ch, config, listener)
                        return
                    }
                } catch (_: Throwable) {
                    onRejectOrFail()
                    return
                }
            }

            if (mode == 2) {
                mgr.createGroup(ch, listener)
            } else {
                onRejectOrFail()
            }
        }

        fun runStageAutoFallback() {
            runP2pMode(
                mode = 3,
                attempt = 0,
                reject24Ghz = false,
                onRejectOrFail = { finish(null) },
            )
        }

        fun runStageLocalOnlyHotspot(
            band5Only: Boolean = false,
            onFailNext: () -> Unit = { runStageAutoFallback() },
        ) {
            if (isStaleOrDone()) return
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || wm == null || !hasNearbyWifiPermission()) {
                onFailNext()
                return
            }
            val ipsBefore = snapshotActiveIpv4s()
            val stageDone = AtomicBoolean(false)
            val stageReservation =
                java.util.concurrent.atomic.AtomicReference<WifiManager.LocalOnlyHotspotReservation?>(null)
            val pollRunnableRef = java.util.concurrent.atomic.AtomicReference<Runnable?>(null)

            fun cancelStagePoll() {
                pollRunnableRef.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
            }

            fun closeOwnReservation() {
                val owned = stageReservation.getAndSet(null) ?: return
                synchronized(lohsLock) {
                    if (activeLohsReservation === owned) {
                        activeLohsReservation = null
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    try {
                        owned.close()
                    } catch (_: Throwable) {}
                }
            }

            fun failStageOnce() {
                cancelStagePoll()
                closeOwnReservation()
                if (stageDone.compareAndSet(false, true) && !isStaleOrDone()) {
                    onFailNext()
                }
            }

            val lohsCallback = object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation?) {
                    if (reservation == null) {
                        failStageOnce()
                        return
                    }
                    var accepted = false
                    synchronized(lohsLock) {
                        if (hostSessionSeq.get() == myHostToken && !done.get() && !stageDone.get()) {
                            activeLohsReservation?.let { prev ->
                                if (prev !== reservation) {
                                    try {
                                        prev.close()
                                    } catch (_: Throwable) {}
                                }
                            }
                            activeLohsReservation = reservation
                            stageReservation.set(reservation)
                            accepted = true
                        }
                    }
                    if (!accepted) {
                        try {
                            reservation.close()
                        } catch (_: Throwable) {}
                        return
                    }

                    val ssid: String?
                    val psk: String?
                    var lohsFreqMhz = 0
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val softCfg: android.net.wifi.SoftApConfiguration? =
                            reservation.softApConfiguration
                        val rawWifiSsid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            softCfg?.wifiSsid?.bytes?.let { String(it, Charsets.UTF_8) }
                        } else {
                            null
                        }
                        @Suppress("DEPRECATION")
                        ssid = rawWifiSsid?.takeIf { it.isNotBlank() } ?: softCfg?.ssid
                        psk = softCfg?.passphrase
                        if (Build.VERSION.SDK_INT >= 36) {
                            val chans = softCfg?.channels
                            val idx5 = chans?.indexOfKey(android.net.wifi.SoftApConfiguration.BAND_5GHZ) ?: -1
                            val idx2 = chans?.indexOfKey(android.net.wifi.SoftApConfiguration.BAND_2GHZ) ?: -1
                            if (band5Only && (chans == null || chans.size() == 0 || idx5 < 0)) {
                                failStageOnce()
                                return
                            }
                            if (idx5 >= 0 && chans != null) {
                                lohsFreqMhz = resolveChannelFrequencyMhz(2, chans.valueAt(idx5))
                            } else if (idx2 >= 0 && chans != null) {
                                lohsFreqMhz = resolveChannelFrequencyMhz(1, chans.valueAt(idx2))
                            }
                        }
                    } else {
                        @Suppress("DEPRECATION")
                        val wifiCfg = reservation.wifiConfiguration
                        @Suppress("DEPRECATION")
                        ssid = wifiCfg?.SSID?.removeSurrounding("\"")
                        @Suppress("DEPRECATION")
                        psk = wifiCfg?.preSharedKey?.removeSurrounding("\"")
                    }

                    if (ssid.isNullOrBlank() || psk.isNullOrBlank()) {
                        failStageOnce()
                        return
                    }

                    var ipRetries = 0
                    val pollTask = object : Runnable {
                        override fun run() {
                            if (stageDone.get() || isStaleOrDone()) return
                            val hostIp = resolveApHostIp(ipsBefore)
                            if (hostIp != null || ipRetries >= 12) {
                                cancelStagePoll()
                                if (stageDone.compareAndSet(false, true)) {
                                    emitReadyAndFinish(ssid, psk, hostIp ?: "192.168.43.1", lohsFreqMhz)
                                }
                            } else {
                                ipRetries++
                                mainHandler.postDelayed(this, 200)
                            }
                        }
                    }
                    pollRunnableRef.set(pollTask)
                    mainHandler.postDelayed(pollTask, 250)
                }

                override fun onStopped() {
                    failStageOnce()
                }

                override fun onFailed(reason: Int) {
                    failStageOnce()
                }
            }
            try {
                if (band5Only && Build.VERSION.SDK_INT >= 36) {
                    val channels = android.util.SparseIntArray().apply {
                        put(android.net.wifi.SoftApConfiguration.BAND_5GHZ, 0)
                    }
                    val softConfig = android.net.wifi.SoftApConfiguration.Builder()
                        .setChannels(channels)
                        .build()
                    // Null SSID is explicitly permitted for LocalOnlyHotspot configs so the OS
                    // assigns credentials while honoring the requested 5GHz band; calling
                    // validateSoftApConfiguration() here rejects null SSIDs before LOHS runs.
                    wm.startLocalOnlyHotspotWithConfiguration(
                        softConfig,
                        java.util.concurrent.Executor { runnable -> mainHandler.post(runnable) },
                        lohsCallback,
                    )
                } else {
                    wm.startLocalOnlyHotspot(lohsCallback, mainHandler)
                }
            } catch (_: SecurityException) {
                onFailNext()
            } catch (_: Throwable) {
                onFailNext()
            }
        }

        fun startStages() {
            if (isStaleOrDone()) return
            if (prefer5Ghz && !allow24GhzFallback && direct5gHostUnsupported.get()) {
                finish(null)
                return
            }
            if (!prefer5Ghz || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                runStageAutoFallback()
                return
            }

            fun runP2p5GhzStages(canTryLegacyHotspot: Boolean) {
                val p2pFreqs = discoverPreferred5GhzP2pFrequencies()
                fun nextStepAfterChannels() {
                    if (prefer5Ghz && !allow24GhzFallback) {
                        markDirect5gHostUnsupported()
                        finish(null)
                    } else if (canTryLegacyHotspot) {
                        runStageLocalOnlyHotspot(
                            band5Only = false,
                            onFailNext = { runStageAutoFallback() },
                        )
                    } else {
                        runStageAutoFallback()
                    }
                }
                fun tryP2pFreqIndex(idx: Int) {
                    if (idx >= p2pFreqs.size) {
                        nextStepAfterChannels()
                        return
                    }
                    runP2pMode(
                        mode = 1,
                        attempt = 0,
                        reject24Ghz = !allow24GhzFallback || canTryLegacyHotspot || idx < p2pFreqs.lastIndex,
                        explicitFreqMhz = p2pFreqs[idx],
                        onRejectOrFail = { tryP2pFreqIndex(idx + 1) },
                    )
                }
                // Stage 1: Deterministic P2P 5GHz band -> usable UNII-1/UNII-3 channels
                runP2pMode(
                    mode = 0,
                    attempt = 0,
                    reject24Ghz = true,
                    onRejectOrFail = { tryP2pFreqIndex(0) },
                )
            }

            // Android 16 (API 36+): try explicit BAND_5GHZ LocalOnlyHotspot SoftAP first
            // for full 80 MHz 5 GHz throughput (~1s startup, zero Wi-Fi picker prompt),
            // cascading cleanly to multi-channel P2P 5GHz if SoftAP is unavailable.
            if (Build.VERSION.SDK_INT >= 36 && canTrySoftAp5Ghz) {
                runStageLocalOnlyHotspot(
                    band5Only = true,
                    onFailNext = { runP2p5GhzStages(canTryLegacyHotspot = false) },
                )
                return
            }

            runP2p5GhzStages(canTryLegacyHotspot = allow24GhzFallback && canReplaceSlowP2pWithHotspot)
        }

        try {
            mgr.requestGroupInfo(ch) { existingGroup ->
                if (isStaleOrDone()) return@requestGroupInfo
                if (existingGroup != null) {
                    removeGroupThen(250L) { startStages() }
                } else {
                    startStages()
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

        acquireTransferLocks()
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
        val pendingNoFreqFinish = AtomicReference<Runnable?>(null)
        lateinit var timeoutRunnable: Runnable
        fun finish(res: Map<String, Any>?) {
            pendingNoFreqFinish.getAndSet(null)?.let { mainHandler.removeCallbacks(it) }
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
        mainHandler.postDelayed(timeoutRunnable, 25000)

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

            val latestCaps = AtomicReference<NetworkCapabilities?>(null)
            val latestFreqMhz = AtomicInteger(0)
            val latestLinkState = AtomicReference<Pair<Network, LinkProperties>?>(null)
            var callbackRef: ConnectivityManager.NetworkCallback? = null

            fun commitConnected(ipv4: String, gwIp: String, freqMhz: Int?) {
                val eventMap = HashMap<String, Any?>().apply {
                    put("type", "p2pState")
                    put("state", "connected")
                    put("ssid", ssid)
                    put("localIp", ipv4)
                    put("gatewayIp", gwIp)
                    if (freqMhz != null && freqMhz > 0) {
                        put("frequencyMhz", freqMhz)
                    }
                }
                emitEvent(eventMap)
                val resMap = HashMap<String, Any>().apply {
                    put("localIp", ipv4)
                    put("gatewayIp", gwIp)
                    if (freqMhz != null && freqMhz > 0) {
                        put("frequencyMhz", freqMhz)
                    }
                }
                finish(resMap)
            }

            fun resolveAddresses(props: LinkProperties?): Pair<String, String>? {
                if (props == null) return null
                val ipv4 = props.linkAddresses
                    .map { it.address }
                    .filterIsInstance<Inet4Address>()
                    .firstOrNull { !it.isLinkLocalAddress && !it.isLoopbackAddress }
                    ?.hostAddress
                if (ipv4.isNullOrEmpty()) return null
                val gwIp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    props.dhcpServerAddress?.hostAddress ?: expectedGateway
                } else {
                    expectedGateway
                }
                return ipv4 to gwIp
            }

            fun tryResolveFromLinkProps(network: Network, props: LinkProperties?) {
                if (activeNetworkSessionId != mySessionId || done.get()) return
                val addrs = resolveAddresses(props) ?: return
                val (ipv4, gwIp) = addrs
                val capsForFreq = latestCaps.get() ?: cm.getNetworkCapabilities(network)
                val resolvedFreq = extractWifiFrequencyMhz(network, capsForFreq, ssid)
                    ?: latestFreqMhz.get()
                if (resolvedFreq > 0) {
                    commitConnected(ipv4, gwIp, resolvedFreq)
                    return
                }
                if (props != null) {
                    latestLinkState.set(network to props)
                }
                // Wait briefly for onCapabilitiesChanged (FLAG_INCLUDE_LOCATION_INFO)
                // when DHCP finishes first so measured 5 GHz center frequency isn't lost.
                val delayed = Runnable {
                    if (activeNetworkSessionId != mySessionId || done.get()) return@Runnable
                    val statePair = latestLinkState.get()
                    val fallbackNet = statePair?.first ?: network
                    val fallbackCaps = latestCaps.get() ?: cm.getNetworkCapabilities(fallbackNet)
                    val fallbackFreq = extractWifiFrequencyMhz(fallbackNet, fallbackCaps, ssid)
                        ?: latestFreqMhz.get()
                    commitConnected(ipv4, gwIp, if (fallbackFreq > 0) fallbackFreq else null)
                }
                if (pendingNoFreqFinish.compareAndSet(null, delayed)) {
                    mainHandler.postDelayed(delayed, 450)
                }
            }

            fun onNetAvailable(network: Network) {
                if (activeNetworkSessionId != mySessionId) return
                cm.bindProcessToNetwork(network)
                tryResolveFromLinkProps(network, cm.getLinkProperties(network))
            }

            fun onNetCapabilities(network: Network, nc: NetworkCapabilities) {
                if (activeNetworkSessionId != mySessionId) return
                latestCaps.set(nc)
                val freq = extractWifiFrequencyMhz(network, nc, ssid)
                if (freq != null && freq > 0) {
                    latestFreqMhz.set(freq)
                    val pendingLp = latestLinkState.get()
                    if (pendingLp != null && pendingLp.first == network && !done.get()) {
                        tryResolveFromLinkProps(pendingLp.first, pendingLp.second)
                    }
                }
            }

            fun onNetUnavailable() {
                synchronized(networkLock) {
                    if (activeNetworkSessionId == mySessionId) {
                        cm.bindProcessToNetwork(null)
                    }
                }
                finish(null)
            }

            fun onNetLost() {
                val isCurrent = synchronized(networkLock) {
                    activeNetworkCallback === callbackRef && activeNetworkSessionId == mySessionId
                }
                if (!isCurrent) return
                cm.bindProcessToNetwork(null)
                emitEvent(mapOf("type" to "p2pState", "state" to "disconnected"))
                finish(null)
            }

            fun createCallback(includeLocationInfo: Boolean): ConnectivityManager.NetworkCallback {
                return if (includeLocationInfo && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    object : ConnectivityManager.NetworkCallback(
                        ConnectivityManager.NetworkCallback.FLAG_INCLUDE_LOCATION_INFO,
                    ) {
                        override fun onAvailable(network: Network) = onNetAvailable(network)
                        override fun onCapabilitiesChanged(network: Network, nc: NetworkCapabilities) =
                            onNetCapabilities(network, nc)
                        override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) =
                            tryResolveFromLinkProps(network, lp)
                        override fun onUnavailable() = onNetUnavailable()
                        override fun onLost(network: Network) = onNetLost()
                    }
                } else {
                    object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) = onNetAvailable(network)
                        override fun onCapabilitiesChanged(network: Network, nc: NetworkCapabilities) =
                            onNetCapabilities(network, nc)
                        override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) =
                            tryResolveFromLinkProps(network, lp)
                        override fun onUnavailable() = onNetUnavailable()
                        override fun onLost(network: Network) = onNetLost()
                    }
                }
            }

            val useLocationCallback = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            var callback = createCallback(includeLocationInfo = useLocationCallback)
            callbackRef = callback
            synchronized(networkLock) {
                activeNetworkCallback = callback
            }
            try {
                cm.requestNetwork(request, callback, 24000)
            } catch (sec: SecurityException) {
                if (!useLocationCallback) throw sec
                synchronized(networkLock) {
                    if (activeNetworkCallback === callback) {
                        unregisterActiveNetworkCallbackLocked()
                    }
                }
                callback = createCallback(includeLocationInfo = false)
                callbackRef = callback
                synchronized(networkLock) {
                    activeNetworkCallback = callback
                }
                cm.requestNetwork(request, callback, 24000)
            }
        } catch (_: Throwable) {
            synchronized(networkLock) {
                if (activeNetworkSessionId == mySessionId) {
                    cm.bindProcessToNetwork(null)
                }
            }
            finish(null)
        }
    }

    private fun resolveChannelFrequencyMhz(band: Int, channelNumber: Int): Int {
        if (channelNumber <= 0) return 0
        if (band == 2 /* BAND_5GHZ */ && channelNumber >= 32) {
            return 5000 + channelNumber * 5
        }
        if (band == 1 /* BAND_2GHZ */) {
            if (channelNumber in 1..13) return 2407 + channelNumber * 5
            if (channelNumber == 14) return 2484
        }
        return 0
    }

    private fun discoverPreferred5GhzP2pFrequencies(): List<Int> {
        val preferredOrder = listOf(5180, 5200, 5220, 5240, 5745, 5785, 5805, 5825)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && hasNearbyWifiPermission()) {
            try {
                val usable = wifiManager?.getUsableChannels(
                    2, // WIFI_BAND_5_GHZ / SoftApConfiguration.BAND_5GHZ
                    android.net.wifi.WifiAvailableChannel.OP_MODE_WIFI_DIRECT_GO,
                )
                if (!usable.isNullOrEmpty()) {
                    val usableFreqs = usable.map { it.frequencyMhz }.filter { it >= 4900 }.toSet()
                    if (usableFreqs.isNotEmpty()) {
                        val ordered = preferredOrder.filter { it in usableFreqs } +
                            usableFreqs.filter { it !in preferredOrder }
                        return ordered.distinct().take(4)
                    }
                }
            } catch (_: SecurityException) {
            } catch (_: Throwable) {}
        }
        return listOf(5180, 5200, 5220, 5240)
    }

    private fun normalizeSsid(raw: String?): String? {
        if (raw == null) return null
        val trimmed = raw.trim().removeSurrounding("\"")
        if (trimmed.isEmpty() || trimmed == "<unknown ssid>") return null
        return trimmed
    }

    private fun extractWifiFrequencyMhz(
        network: Network,
        caps: NetworkCapabilities? = null,
        targetSsid: String? = null,
    ): Int? {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val resolvedCaps = caps ?: connectivityManager?.getNetworkCapabilities(network)
                val transportInfo = resolvedCaps?.transportInfo
                if (transportInfo is WifiInfo && transportInfo.frequency > 0) {
                    val infoSsid = normalizeSsid(transportInfo.ssid)
                    if (targetSsid == null || infoSsid == null || infoSsid == targetSsid) {
                        return transportInfo.frequency
                    }
                }
            }
        } catch (_: Throwable) {}
        return null
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
        mainHandler.postDelayed(timeoutRunnable, 25000)

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

    private val transferLockSync = Any()
    private var activeWifiLock: WifiManager.WifiLock? = null
    private var activeWakeLock: PowerManager.WakeLock? = null

    private fun sanitizeStableDirectTag(raw: String?): String {
        if (raw.isNullOrBlank()) return ""
        val sb = StringBuilder(10)
        for (ch in raw) {
            if (ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9') {
                sb.append(ch.uppercaseChar())
                if (sb.length >= 10) break
            }
        }
        return sb.toString()
    }

    private fun acquireTransferLocks() {
        synchronized(transferLockSync) {
            try {
                if (activeWifiLock == null) {
                    val wm = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                    } else {
                        @Suppress("DEPRECATION")
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF
                    }
                    activeWifiLock = wm?.createWifiLock(mode, "daphq:DirectTransferWifiLock")?.apply {
                        setReferenceCounted(false)
                    }
                }
                activeWifiLock?.let { if (!it.isHeld) it.acquire() }
            } catch (_: Throwable) {}

            try {
                if (activeWakeLock == null) {
                    val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                    activeWakeLock = pm?.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "daphq:DirectTransferWakeLock",
                    )?.apply {
                        setReferenceCounted(false)
                    }
                }
                activeWakeLock?.let { if (!it.isHeld) it.acquire(30 * 60 * 1000L) }
            } catch (_: Throwable) {}
        }
    }

    private fun releaseTransferLocks() {
        synchronized(transferLockSync) {
            try {
                activeWifiLock?.let { if (it.isHeld) it.release() }
            } catch (_: Throwable) {}
            try {
                activeWakeLock?.let { if (it.isHeld) it.release() }
            } catch (_: Throwable) {}
        }
    }

    private fun closeActiveLohsReservation() {
        val resToClose = synchronized(lohsLock) {
            val prev = activeLohsReservation
            activeLohsReservation = null
            prev
        }
        if (resToClose != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                resToClose.close()
            } catch (_: Throwable) {}
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopDirectSessionInternal() {
        releaseTransferLocks()
        hostSessionSeq.incrementAndGet()
        closeActiveLohsReservation()
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
        if (radioReceiverRegistered) {
            try {
                appContext.unregisterReceiver(radioStateReceiver)
            } catch (_: Throwable) {}
            radioReceiverRegistered = false
        }
        stopBle()
        stopDirectSessionInternal()
        synchronized(gattClientLock) {
            gattSessionSeq.incrementAndGet()
            try {
                activeClientGatt?.close()
            } catch (_: SecurityException) {
            } catch (_: Throwable) {}
            activeClientGatt = null
        }
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    private fun isCellularOrTunnelInterface(rawName: String): Boolean {
        val n = rawName.lowercase()
        return n.contains("rmnet") ||
            n.contains("ccmni") ||
            n.contains("tun") ||
            n.contains("ppp") ||
            n.contains("dummy") ||
            n.contains("v4-rmnet")
    }

    private fun snapshotActiveIpv4s(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { it.isUp && !it.isLoopback }
            for (iface in ifaces) {
                if (isCellularOrTunnelInterface(iface.name)) continue
                for (addr in iface.inetAddresses.toList()) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        val ip = addr.hostAddress
                        if (!ip.isNullOrBlank()) {
                            out[iface.name] = ip
                        }
                    }
                }
            }
        } catch (_: Throwable) {}
        return out
    }

    private fun resolveApHostIp(ipsBefore: Map<String, String>): String? {
        return try {
            val now = snapshotActiveIpv4s()
            for ((name, ip) in now) {
                val n = name.lowercase()
                if (n.contains("p2p")) continue
                if (n.contains("swlan") || n.contains("softap") ||
                    n.startsWith("ap") || n.contains("ap0") || n.contains("sap")
                ) {
                    return ip
                }
            }
            for ((name, ip) in now) {
                val n = name.lowercase()
                if (n.contains("p2p")) continue
                if (ipsBefore[name] != ip &&
                    (n.startsWith("wlan") || n.contains("wifi") || n.contains("wl"))
                ) {
                    return ip
                }
            }
            for ((name, ip) in now) {
                val n = name.lowercase()
                if (n == "wlan1" || n == "wlan2" || n.startsWith("wlan1:") || n.startsWith("wlan2:")) {
                    return ip
                }
            }
            null
        } catch (_: Throwable) {
            null
        }
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
