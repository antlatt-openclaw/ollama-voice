package com.openclaw.ollamavoice

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), SensorEventListener {
    private lateinit var audioManager: AudioManager
    private lateinit var sensorManager: SensorManager
    private var proximitySensor: Sensor? = null
    private var proximityEventSink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        proximitySensor = sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY)

        // ── Audio Mode Channel ──────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.openclaw.voice/audio")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setVoiceCommunicationMode" -> {
                        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                        audioManager.requestAudioFocus(
                            android.media.AudioFocusRequest.Builder(
                                android.media.AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
                            ).setOnAudioFocusChangeListener { /* no-op */ }.build()
                        )
                        result.success(true)
                    }
                    "resetAudioMode" -> {
                        audioManager.mode = AudioManager.MODE_NORMAL
                        audioManager.abandonAudioFocus(null)
                        result.success(true)
                    }
                    "startBluetoothSco" -> {
                        try {
                            if (audioManager.isBluetoothScoAvailableOffCall) {
                                audioManager.startBluetoothSco()
                                audioManager.isBluetoothScoOn = true
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopBluetoothSco" -> {
                        try {
                            audioManager.stopBluetoothSco()
                            audioManager.isBluetoothScoOn = false
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "setSpeakerRoute" -> {
                        audioManager.isSpeakerphoneOn = true
                        audioManager.isBluetoothScoOn = false
                        result.success(true)
                    }
                    "setEarpieceRoute" -> {
                        audioManager.isSpeakerphoneOn = false
                        audioManager.isBluetoothScoOn = false
                        result.success(true)
                    }
                    "setBluetoothRoute" -> {
                        audioManager.isSpeakerphoneOn = false
                        if (audioManager.isBluetoothScoAvailableOffCall) {
                            audioManager.startBluetoothSco()
                            audioManager.isBluetoothScoOn = true
                        }
                        result.success(true)
                    }
                    "startForegroundService" -> {
                        try {
                            val serviceIntent = Intent(this, ForegroundAudioService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(serviceIntent)
                            } else {
                                startService(serviceIntent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopForegroundService" -> {
                        try {
                            val serviceIntent = Intent(this, ForegroundAudioService::class.java)
                            stopService(serviceIntent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Proximity Event Channel ─────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.openclaw.voice/proximity")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    proximityEventSink = events
                    proximitySensor?.let { sensor ->
                        sensorManager.registerListener(
                            this@MainActivity, sensor, SensorManager.SENSOR_DELAY_NORMAL
                        )
                    }
                }
                override fun onCancel(arguments: Any?) {
                    proximityEventSink = null
                    sensorManager.unregisterListener(this@MainActivity)
                }
            })
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type == Sensor.TYPE_PROXIMITY) {
            val isNear = event.values[0] < event.sensor.maximumRange
            handler.post {
                proximityEventSink?.success(isNear)
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // No-op
    }

    override fun onDestroy() {
        sensorManager.unregisterListener(this)
        super.onDestroy()
    }
}