package com.example.loracord

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val bleChannel = "loracord/meshtastic_ble"
    private val bleEvents = "loracord/meshtastic_ble/events"
    private val storageChannel = "loracord/storage"
    private val notificationChannel = "loracord/notifications"
    private val permissionRequestCode = 41
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var gatt: BluetoothGatt? = null
    private var toRadio: BluetoothGattCharacteristic? = null
    private var fromRadio: BluetoothGattCharacteristic? = null
    private var fromNum: BluetoothGattCharacteristic? = null
    private var pendingBondDevice: BluetoothDevice? = null
    private val devices = linkedMapOf<String, Map<String, Any?>>()

    private val meshServiceUuid = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    private val fromRadioUuid = UUID.fromString("2c55e69e-4993-11ed-b878-0242ac120002")
    private val toRadioUuid = UUID.fromString("f75c76d2-129e-4dad-a1dd-7866124401e7")
    private val fromNumUuid = UUID.fromString("ed9da18c-a800-4f66-a670-aa7547e34453")
    private val clientConfigUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureNotificationChannel()
        registerPairingReceiver()
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(pairingReceiver)
        } catch (_: IllegalArgumentException) {
            // Receiver was not registered or was already unregistered.
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, bleEvents).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, bleChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermissions" -> {
                    requestBlePermissions(result)
                }
                "scan" -> scan(call.argument<Int>("timeoutMs") ?: 6000, result)
                "connect" -> {
                    val id = call.argument<String>("id")
                    if (id == null) result.error("bad_args", "Missing device id", null) else connect(id, result)
                }
                "submitPairingPin" -> {
                    val id = call.argument<String>("id")
                    val pin = call.argument<String>("pin")
                    if (id == null || pin == null) {
                        result.error("bad_args", "Missing device id or PIN", null)
                    } else {
                        submitPairingPin(id, pin, result)
                    }
                }
                "disconnect" -> {
                    gatt?.disconnect()
                    gatt?.close()
                    gatt = null
                    result.success(null)
                }
                "write" -> {
                    val bytes = call.arguments as? ByteArray
                    if (bytes == null) result.error("bad_args", "Missing bytes", null) else write(bytes, result)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannel).setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("loracord", Context.MODE_PRIVATE)
            when (call.method) {
                "read" -> result.success(prefs.getString(call.argument<String>("key"), null))
                "write" -> {
                    prefs.edit()
                        .putString(call.argument<String>("key"), call.argument<String>("value"))
                        .apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notificationChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "message" -> {
                    notifyMessage(
                        call.argument<String>("title") ?: "Loracord",
                        call.argument<String>("body") ?: ""
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun scan(timeoutMs: Int, result: MethodChannel.Result) {
        if (!ensureBlePermissions(result, "scan")) return
        val adapter = bluetoothAdapter()
        if (adapter?.isEnabled != true) {
            result.error("ble_disabled", "Bluetooth is disabled", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            result.error("ble_unavailable", "Bluetooth LE scanner unavailable", null)
            return
        }
        devices.clear()
        addBondedDevices(adapter)
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scanResult: ScanResult) {
                val device = scanResult.device ?: return
                val item = deviceMap(device, scanResult.rssi)
                devices[device.address] = item
                emit(mapOf("type" to "device", "device" to item))
            }

            override fun onScanFailed(errorCode: Int) {
                emit(mapOf("type" to "error", "message" to "BLE scan failed: $errorCode"))
            }
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        try {
            scanner.startScan(null, settings, callback)
        } catch (error: SecurityException) {
            result.error("permission_denied", "Bluetooth permission denied: ${error.message}", null)
            return
        }
        mainHandler.postDelayed({
            try {
                scanner.stopScan(callback)
            } catch (_: SecurityException) {
                // Permission may have been revoked while scanning; keep collected results.
            }
            result.success(devices.values.toList())
        }, timeoutMs.toLong())
    }

    private fun connect(id: String, result: MethodChannel.Result) {
        if (!ensureBlePermissions(result, "connect")) return
        val adapter = bluetoothAdapter()
        if (adapter == null) {
            result.error("ble_unavailable", "Bluetooth adapter unavailable", null)
            return
        }
        val device = adapter.getRemoteDevice(id)
        val name = safeDeviceName(device) ?: id
        emit(mapOf("type" to "log", "message" to "Connecting to $name"))
        try {
            if (device.bondState != BluetoothDevice.BOND_BONDED) {
                pendingBondDevice = device
                emit(mapOf("type" to "log", "message" to "Starting Android Bluetooth pairing for $name"))
                if (!device.createBond()) {
                    emit(mapOf("type" to "error", "message" to "Could not start Bluetooth pairing"))
                }
                result.success(null)
                return
            }
            openGatt(device)
            result.success(null)
        } catch (error: SecurityException) {
            result.error("permission_denied", "Bluetooth permission denied: ${error.message}", null)
        }
    }

    private fun submitPairingPin(id: String, pin: String, result: MethodChannel.Result) {
        if (!ensureBlePermissions(result, "pair")) return
        val adapter = bluetoothAdapter()
        if (adapter == null) {
            result.error("ble_unavailable", "Bluetooth adapter unavailable", null)
            return
        }
        val cleanPin = pin.trim().ifEmpty { "123456" }
        if (!Regex("^[0-9]{4,16}$").matches(cleanPin)) {
            result.error("bad_pin", "PIN must contain 4 to 16 digits", null)
            return
        }
        val device = pendingBondDevice?.takeIf { it.address == id } ?: adapter.getRemoteDevice(id)
        try {
            @Suppress("DEPRECATION")
            val accepted = device.setPin(cleanPin.toByteArray(Charsets.UTF_8))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                device.setPairingConfirmation(true)
            }
            if (device.bondState == BluetoothDevice.BOND_NONE) device.createBond()
            if (accepted) {
                pendingBondDevice = device
                emit(mapOf("type" to "log", "message" to "Bluetooth PIN sent, waiting for pairing..."))
                result.success(null)
            } else {
                result.error("pin_rejected", "Android refused the Bluetooth PIN", null)
            }
        } catch (error: SecurityException) {
            result.error(
                "permission_denied",
                "Android blocked in-app Bluetooth PIN entry. Pair the node from Android Bluetooth settings, then scan again.",
                null
            )
        }
    }

    private fun openGatt(device: BluetoothDevice) {
        if (!hasBleConnectPermission()) {
            emit(mapOf("type" to "error", "message" to "Bluetooth connect permission is required"))
            return
        }
        try {
            gatt?.close()
            gatt = device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (error: SecurityException) {
            emit(mapOf("type" to "error", "message" to "Bluetooth permission denied: ${error.message}"))
        }
    }

    private val pairingReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val action = intent?.action ?: return
            val device = bluetoothDeviceFromIntent(intent) ?: pendingBondDevice ?: return
            when (action) {
                BluetoothDevice.ACTION_PAIRING_REQUEST -> {
                    if (!hasBleConnectPermission()) {
                        emit(mapOf("type" to "error", "message" to "Bluetooth connect permission is required for pairing"))
                        return
                    }
                    pendingBondDevice = device
                    val variant = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, -1)
                    val pairingKey = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_KEY, -1)
                    val message = when (variant) {
                        BluetoothDevice.PAIRING_VARIANT_PASSKEY_CONFIRMATION ->
                            if (pairingKey >= 0) "Confirm Bluetooth code $pairingKey" else "Bluetooth confirmation required"
                        BluetoothDevice.PAIRING_VARIANT_PIN ->
                            "Enter the Bluetooth PIN shown by the Meshtastic node"
                        else -> "Bluetooth pairing required"
                    }
                    emitPairingRequest(device, message)
                }
                BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
                    when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)) {
                        BluetoothDevice.BOND_BONDED -> {
                            if (pendingBondDevice?.address == device.address) {
                                emit(mapOf("type" to "log", "message" to "Bluetooth pairing complete"))
                                pendingBondDevice = null
                                openGatt(device)
                            }
                        }
                        BluetoothDevice.BOND_NONE -> {
                            if (pendingBondDevice?.address == device.address) {
                                pendingBondDevice = null
                                emit(mapOf("type" to "error", "message" to "Bluetooth pairing canceled or PIN invalid"))
                            }
                        }
                    }
                }
            }
        }
    }

    private fun registerPairingReceiver() {
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_PAIRING_REQUEST)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pairingReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(pairingReceiver, filter)
        }
    }

    private fun bluetoothDeviceFromIntent(intent: Intent): BluetoothDevice? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }
    }

    private fun emitPairingRequest(device: BluetoothDevice, message: String) {
        emit(mapOf("type" to "pairing", "device" to deviceMap(device), "message" to message))
    }

    private fun write(bytes: ByteArray, result: MethodChannel.Result) {
        if (!ensureBlePermissions(result, "write")) return
        val characteristic = toRadio
        val activeGatt = gatt
        if (characteristic == null || activeGatt == null) {
            result.error("not_connected", "ToRadio characteristic unavailable", null)
            return
        }
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val status = activeGatt.writeCharacteristic(characteristic, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                if (status == BluetoothGatt.GATT_SUCCESS) result.success(null) else result.error("write_failed", "GATT status $status", null)
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = bytes
                @Suppress("DEPRECATION")
                if (activeGatt.writeCharacteristic(characteristic)) result.success(null) else result.error("write_failed", "GATT write refused", null)
            }
        } catch (error: SecurityException) {
            result.error("permission_denied", "Bluetooth permission denied: ${error.message}", null)
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                emit(mapOf("type" to "connected", "message" to "BLE connected, discovering GATT..."))
                try {
                    gatt.discoverServices()
                } catch (error: SecurityException) {
                    emit(mapOf("type" to "error", "message" to "Bluetooth permission denied: ${error.message}"))
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                emit(mapOf("type" to "disconnected", "message" to "BLE node disconnected"))
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val service: BluetoothGattService? = gatt.getService(meshServiceUuid)
            toRadio = service?.getCharacteristic(toRadioUuid)
            fromRadio = service?.getCharacteristic(fromRadioUuid)
            fromNum = service?.getCharacteristic(fromNumUuid)
            if (toRadio == null || fromRadio == null) {
                emit(mapOf("type" to "error", "message" to "Meshtastic characteristics not found"))
                return
            }
            fromNum?.let { enableNotification(gatt, it) }
            readFromRadio(gatt)
            emit(mapOf("type" to "connected", "message" to "Meshtastic node ready"))
        }

        @Deprecated("Deprecated by Android API")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (characteristic.uuid == fromRadioUuid) {
                emit(mapOf("type" to "data", "bytes" to characteristic.value))
                readFromRadio(gatt)
            } else if (characteristic.uuid == fromNumUuid) {
                readFromRadio(gatt)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid == fromRadioUuid) {
                emit(mapOf("type" to "data", "bytes" to value))
                readFromRadio(gatt)
            } else if (characteristic.uuid == fromNumUuid) {
                readFromRadio(gatt)
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS && characteristic.uuid == fromRadioUuid && value.isNotEmpty()) {
                emit(mapOf("type" to "data", "bytes" to value))
                readFromRadio(gatt)
            }
        }
    }

    private fun enableNotification(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        try {
            gatt.setCharacteristicNotification(characteristic, true)
            val descriptor = characteristic.getDescriptor(clientConfigUuid) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else {
                @Suppress("DEPRECATION")
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                gatt.writeDescriptor(descriptor)
            }
        } catch (error: SecurityException) {
            emit(mapOf("type" to "error", "message" to "Bluetooth permission denied: ${error.message}"))
        }
    }

    private fun readFromRadio(gatt: BluetoothGatt) {
        try {
            fromRadio?.let { gatt.readCharacteristic(it) }
        } catch (error: SecurityException) {
            emit(mapOf("type" to "error", "message" to "Bluetooth permission denied: ${error.message}"))
        }
    }

    private fun bluetoothAdapter(): BluetoothAdapter? {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        return manager.adapter
    }

    private fun safeDeviceName(device: BluetoothDevice): String? {
        return try {
            device.name
        } catch (_: SecurityException) {
            null
        }
    }

    private fun deviceMap(device: BluetoothDevice, rssi: Int? = null): Map<String, Any?> {
        return mapOf(
            "id" to device.address,
            "name" to (safeDeviceName(device) ?: "Meshtastic"),
            "rssi" to rssi,
            "paired" to isBonded(device)
        )
    }

    private fun isBonded(device: BluetoothDevice): Boolean {
        return try {
            device.bondState == BluetoothDevice.BOND_BONDED
        } catch (_: SecurityException) {
            false
        }
    }

    private fun addBondedDevices(adapter: BluetoothAdapter) {
        try {
            for (device in adapter.bondedDevices ?: emptySet()) {
                val item = deviceMap(device)
                devices[device.address] = item
                emit(mapOf("type" to "device", "device" to item))
            }
        } catch (error: SecurityException) {
            emit(mapOf("type" to "error", "message" to "Bluetooth permission denied: ${error.message}"))
        }
    }

    private fun requiredBlePermissions(): List<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT
            )
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    private fun requestBlePermissions(result: MethodChannel.Result) {
        val required = requiredBlePermissions()
        val optional = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            emptyList()
        }
        val permissions = (required + optional)
            .distinct()
            .filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (permissions.isEmpty()) {
            result.success(null)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_pending", "Bluetooth permission request already pending", null)
            return
        }
        pendingPermissionResult = result
        requestPermissions(permissions.toTypedArray(), permissionRequestCode)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) return
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        val denied = missingRequiredBlePermissions()
        if (denied.isEmpty()) {
            result.success(null)
        } else {
            result.error("permission_denied", "Bluetooth permissions denied: ${denied.joinToString()}", null)
        }
    }

    private fun missingRequiredBlePermissions(): List<String> {
        return requiredBlePermissions()
            .filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
    }

    private fun hasBleConnectPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    }

    private fun ensureBlePermissions(result: MethodChannel.Result, action: String): Boolean {
        val denied = missingRequiredBlePermissions()
        if (denied.isEmpty()) return true
        result.error(
            "permission_denied",
            "Bluetooth permissions are required to $action: ${denied.joinToString()}",
            null
        )
        return false
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("loracord_mesh", "Loracord mesh", NotificationManager.IMPORTANCE_DEFAULT)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun notifyMessage(title: String, body: String) {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, "loracord_mesh")
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .build()
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(System.currentTimeMillis().toInt(), notification)
        } catch (_: SecurityException) {
            // Android 13+ may deny notification permission; messages still land in the app.
        }
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }
}
