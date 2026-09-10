package com.blindbus.guide

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private var locationBridge: LocationBridge? = null
    private var compassBridge: CompassBridge? = null
    private var beaconBridge: BeaconBridge? = null
    private val ttsChannelName = "blind_bus_guide/tts"
    private val speechChannelName = "blind_bus_guide/speech"
    private val audioRequestCode = 7001
    private val speechRequestCode = 7002

    private var textToSpeech: TextToSpeech? = null
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingSpeakText: String? = null
    private var pendingSpeakResult: MethodChannel.Result? = null
    private var currentUtteranceId: String? = null
    private var utteranceSequence = 0
    private var ready = false
    private var speechOwner: String? = null
    private var speechPrompt = "말씀해 주세요"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        locationBridge = LocationBridge(this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "blind_bus_guide/location"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "current" -> locationBridge!!.current(
                    result,
                    call.argument<Number>("maxAgeMs")?.toLong() ?: 15000L,
                    call.argument<String>("owner")
                )

                "cancel" -> {
                    locationBridge?.cancel(call.argument<String>("owner"))
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        locationBridge = LocationBridge(this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "blind_bus_guide/beacon"
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                "scan" -> {
                    beaconBridge!!.scan(
                        result,
                        call.argument<Number>("durationMs")
                            ?.toLong() ?: 5000L
                    )
                }

                "startMonitor" -> {
                    beaconBridge!!.startMonitor(result)
                }

                "latest" -> {
                    beaconBridge!!.latest(result)
                }

                "stop" -> {
                    beaconBridge?.stop()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        compassBridge = CompassBridge(this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "blind_bus_guide/compass"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "current" -> result.success(
                    compassBridge!!.current(
                        call.argument<Number>("latitude")?.toDouble() ?: 0.0,
                        call.argument<Number>("longitude")?.toDouble() ?: 0.0
                    )
                )

                "stop" -> {
                    compassBridge?.stop()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // 비콘 연결
        beaconBridge = BeaconBridge(this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "blind_bus_guide/beacon"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scan" -> {
                    beaconBridge!!.scan(
                        result,
                        call.argument<Number>("durationMs")?.toLong() ?: 5000L
                    )
                }

                "stop" -> {
                    beaconBridge?.stop()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        textToSpeech = TextToSpeech(this, this)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ttsChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "stop" -> {
                    if (call.argument<String>("owner") == speechOwner) {
                        textToSpeech?.stop()
                        pendingSpeakText = null

                        if (currentUtteranceId != null) {
                            finishSpeak(currentUtteranceId, null)
                        } else {
                            pendingSpeakResult?.success(null)
                            pendingSpeakResult = null
                        }
                    }

                    result.success(null)
                }

                "speak" -> {
                    speechOwner = call.argument<String>("owner")
                    val text = call.argument<String>("text").orEmpty()
                    speak(text, result)
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            speechChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listen" -> {
                    if (pendingSpeechResult != null) {
                        result.error(
                            "SPEECH_BUSY",
                            "음성 인식이 이미 진행 중입니다.",
                            null
                        )
                    } else {
                        speechPrompt =
                            call.argument<String>("prompt")
                                ?: "목적지를 말해주세요"

                        startSpeechRecognition(result)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            val languageResult = textToSpeech?.setLanguage(Locale.KOREAN)
            if (
                languageResult == TextToSpeech.LANG_MISSING_DATA ||
                languageResult == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                textToSpeech?.language = Locale.getDefault()
            }
            textToSpeech?.setSpeechRate(0.95f)
            textToSpeech?.setOnUtteranceProgressListener(
                object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) = Unit

                    override fun onDone(utteranceId: String?) {
                        finishSpeak(utteranceId, null)
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        finishSpeak(utteranceId, "TTS 재생 중 오류가 발생했습니다.")
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        finishSpeak(utteranceId, "TTS 재생 중 오류가 발생했습니다. 코드: $errorCode")
                    }
                }
            )

            pendingSpeakText?.let { text ->
                val result = pendingSpeakResult
                pendingSpeakText = null
                pendingSpeakResult = null

                if (result != null) {
                    speak(text, result)
                }
            }
        }
    }

    private fun speak(text: String, result: MethodChannel.Result) {
        if (text.isBlank()) {
            result.success(null)
            return
        }

        if (!ready) {
            pendingSpeakText = text
            pendingSpeakResult = result
            return
        }

        pendingSpeakResult?.success(null)
        pendingSpeakResult = result

        utteranceSequence += 1
        val utteranceId = "blind-bus-guide-$utteranceSequence"
        currentUtteranceId = utteranceId

        textToSpeech?.stop()
        val speakResult = textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)

        if (speakResult == TextToSpeech.ERROR) {
            finishSpeak(utteranceId, "TTS 재생을 시작하지 못했습니다.")
        }
    }

    private fun finishSpeak(utteranceId: String?, errorMessage: String?) {
        if (utteranceId == null || utteranceId != currentUtteranceId) {
            return
        }

        val result = pendingSpeakResult ?: return
        pendingSpeakResult = null
        currentUtteranceId = null

        runOnUiThread {
            if (errorMessage == null) {
                result.success(null)
            } else {
                result.error("TTS_ERROR", errorMessage, null)
            }
        }
    }

    private fun startSpeechRecognition(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("SPEECH_UNAVAILABLE", "이 기기에서 음성 인식을 사용할 수 없습니다.", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingSpeechResult = result
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), audioRequestCode)
            return
        }

        beginSpeechRecognitionWithIntent(result)
    }

    private fun beginSpeechRecognitionWithIntent(result: MethodChannel.Result) {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ko-KR")
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "ko-KR")
            putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, "ko-KR")
            putExtra(RecognizerIntent.EXTRA_PROMPT, speechPrompt)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 7000L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 3500L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 2500L)
        }

        pendingSpeechResult = result

        try {
            startActivityForResult(intent, speechRequestCode)
        } catch (error: ActivityNotFoundException) {
            pendingSpeechResult = null
            result.error("SPEECH_UNAVAILABLE", "음성 인식 앱을 찾을 수 없습니다.", null)
        }
    }

    private fun speechErrorMessage(error: Int): String {
        return when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "마이크 오디오 오류입니다."
            SpeechRecognizer.ERROR_CLIENT -> "음성 인식 클라이언트 오류입니다."
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "마이크 권한이 없습니다."
            SpeechRecognizer.ERROR_NETWORK -> "네트워크 오류입니다."
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "네트워크 시간이 초과되었습니다."
            SpeechRecognizer.ERROR_NO_MATCH -> "인식된 음성이 없습니다."
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "음성 인식기가 사용 중입니다."
            SpeechRecognizer.ERROR_SERVER -> "음성 인식 서버 오류입니다."
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "말소리를 감지하지 못했습니다."
            else -> "음성 인식 오류입니다."
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == 7010) { locationBridge?.permissionResult(); return }
        if (
            beaconBridge?.permissionResult(
                requestCode,
                grantResults
            ) == true
        ) {
            return
        }
        if (requestCode != audioRequestCode) {
            return
        }

        val result = pendingSpeechResult ?: return
        pendingSpeechResult = null

        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            beginSpeechRecognitionWithIntent(result)
        } else {
            result.error("PERMISSION_DENIED", "마이크 권한이 거부되었습니다.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != speechRequestCode) {
            return
        }

        val result = pendingSpeechResult ?: return
        pendingSpeechResult = null

        if (resultCode != Activity.RESULT_OK) {
            result.error("SPEECH_CANCELLED", "음성 인식이 취소되었거나 실패했습니다.", null)
            return
        }

        val matches = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
        val text = matches?.firstOrNull().orEmpty()

        if (text.isBlank()) {
            result.error("SPEECH_NO_MATCH", "인식된 음성이 없습니다.", null)
            return
        }

        result.success(text)
    }

    override fun onDestroy() {
        beaconBridge?.close()
        compassBridge?.stop()
        locationBridge?.close()

        pendingSpeechResult = null
        pendingSpeakText = null
        pendingSpeakResult = null
        currentUtteranceId = null

        textToSpeech?.stop()
        textToSpeech?.shutdown()

        super.onDestroy()
    }
}
