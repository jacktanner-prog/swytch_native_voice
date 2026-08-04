package com.swytchhub.nativevoice;

import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;

import com.google.firebase.messaging.FirebaseMessaging;
import com.twilio.voice.RegistrationException;
import com.twilio.voice.RegistrationListener;
import com.twilio.voice.UnregistrationListener;
import com.twilio.voice.Voice;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public final class SwytchNativeVoicePlugin implements
        FlutterPlugin,
        MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler {

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static EventChannel.EventSink eventSink;

    private Context context;
    private MethodChannel methodChannel;
    private EventChannel eventChannel;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        methodChannel = new MethodChannel(
                binding.getBinaryMessenger(),
                "com.swytchhub.swytchmobile/native_voice");
        eventChannel = new EventChannel(
                binding.getBinaryMessenger(),
                "com.swytchhub.swytchmobile/native_voice_events");
        methodChannel.setMethodCallHandler(this);
        eventChannel.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        methodChannel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
        eventSink = null;
        context = null;
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        eventSink = events;
        emitFromNative(SwytchVoiceService.snapshot());
    }

    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "isSupported":
                result.success(true);
                break;
            case "register":
                register(call.argument("accessToken"), result);
                break;
            case "unregister":
                unregister(call.argument("accessToken"), result);
                break;
            case "call":
                Intent outgoing = new Intent(context, SwytchVoiceService.class);
                outgoing.setAction(SwytchVoiceService.ACTION_CALL);
                outgoing.putExtra(SwytchVoiceService.EXTRA_ACCESS_TOKEN, (String) call.argument("accessToken"));
                outgoing.putExtra(SwytchVoiceService.EXTRA_TO, (String) call.argument("to"));
                Map<String, String> parameters = call.argument("parameters");
                if (parameters != null) {
                    outgoing.putExtra(SwytchVoiceService.EXTRA_PARAMETERS, new HashMap<>(parameters));
                }
                try {
                    startVoiceService(outgoing);
                    result.success(null);
                } catch (RuntimeException exception) {
                    result.error("service_start_failed", exception.getMessage(), null);
                }
                break;
            case "answer":
                sendAction(SwytchVoiceService.ACTION_ANSWER, null, null);
                result.success(null);
                break;
            case "reject":
                sendAction(SwytchVoiceService.ACTION_REJECT, null, null);
                result.success(null);
                break;
            case "hangup":
                sendAction(SwytchVoiceService.ACTION_HANGUP, null, null);
                result.success(null);
                break;
            case "setMuted":
                sendBooleanAction(SwytchVoiceService.ACTION_MUTE, Boolean.TRUE.equals(call.argument("value")));
                result.success(null);
                break;
            case "setHold":
                sendBooleanAction(SwytchVoiceService.ACTION_HOLD, Boolean.TRUE.equals(call.argument("value")));
                result.success(null);
                break;
            case "setSpeaker":
                sendBooleanAction(SwytchVoiceService.ACTION_SPEAKER, Boolean.TRUE.equals(call.argument("value")));
                result.success(null);
                break;
            case "sendDigits":
                Intent digits = new Intent(context, SwytchVoiceService.class);
                digits.setAction(SwytchVoiceService.ACTION_DIGITS);
                digits.putExtra(SwytchVoiceService.EXTRA_DIGITS, (String) call.argument("digits"));
                context.startService(digits);
                result.success(null);
                break;
            case "currentState":
                result.success(SwytchVoiceService.snapshot());
                break;
            default:
                result.notImplemented();
        }
    }

    private void register(String accessToken, MethodChannel.Result result) {
        if (accessToken == null || accessToken.isEmpty()) {
            result.error("invalid_token", "Missing access token", null);
            return;
        }
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (!task.isSuccessful() || task.getResult() == null) {
                result.error("fcm_token_failed", "Unable to obtain the FCM token", null);
                return;
            }
            String fcmToken = task.getResult();
            Voice.register(
                    accessToken,
                    Voice.RegistrationChannel.FCM,
                    fcmToken,
                    new RegistrationListener() {
                        @Override
                        public void onRegistered(@NonNull String token, @NonNull String registeredFcmToken) {
                            Map<String, Object> event = new HashMap<>();
                            event.put("type", "registered");
                            event.put("state", "idle");
                            emitFromNative(event);
                            result.success(null);
                        }

                        @Override
                        public void onError(
                                @NonNull RegistrationException exception,
                                @NonNull String token,
                                @NonNull String registeredFcmToken) {
                            result.error("registration_failed", exception.getMessage(), exception.getErrorCode());
                        }
                    });
        });
    }

    private void unregister(String accessToken, MethodChannel.Result result) {
        if (accessToken == null || accessToken.isEmpty()) {
            result.success(null);
            return;
        }
        FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
            if (!task.isSuccessful() || task.getResult() == null) {
                result.success(null);
                return;
            }
            Voice.unregister(
                    accessToken,
                    Voice.RegistrationChannel.FCM,
                    task.getResult(),
                    new UnregistrationListener() {
                        @Override
                        public void onUnregistered(String token, String registeredFcmToken) {
                            result.success(null);
                        }

                        @Override
                        public void onError(
                                RegistrationException exception,
                                String token,
                                String registeredFcmToken) {
                            result.error("unregister_failed", exception.getMessage(), exception.getErrorCode());
                        }
                    });
        });
    }

    private void sendAction(String action, String accessToken, String to) {
        Intent intent = new Intent(context, SwytchVoiceService.class);
        intent.setAction(action);
        if (accessToken != null) intent.putExtra(SwytchVoiceService.EXTRA_ACCESS_TOKEN, accessToken);
        if (to != null) intent.putExtra(SwytchVoiceService.EXTRA_TO, to);
        context.startService(intent);
    }

    private void sendBooleanAction(String action, boolean value) {
        Intent intent = new Intent(context, SwytchVoiceService.class);
        intent.setAction(action);
        intent.putExtra(SwytchVoiceService.EXTRA_VALUE, value);
        context.startService(intent);
    }

    private void startVoiceService(Intent intent) {
        if (context == null) throw new IllegalStateException("Native voice is not attached");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(context, intent);
        } else {
            context.startService(intent);
        }
    }

    static void emitFromNative(Map<String, Object> event) {
        if (event == null) event = Collections.emptyMap();
        final Map<String, Object> payload = event;
        MAIN.post(() -> {
            if (eventSink != null) eventSink.success(payload);
        });
    }
}
