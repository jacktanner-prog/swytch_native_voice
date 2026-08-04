package com.swytchhub.nativevoice;

import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import com.twilio.voice.CallException;
import com.twilio.voice.CallInvite;
import com.twilio.voice.CancelledCallInvite;
import com.twilio.voice.MessageListener;
import com.twilio.voice.Voice;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;

public final class SwytchVoiceMessagingService extends FirebaseMessagingService
        implements MessageListener {

    private final Handler voiceHandler = new Handler(Looper.getMainLooper());

    @Override
    public void onMessageReceived(@NonNull RemoteMessage remoteMessage) {
        if (!remoteMessage.getData().isEmpty()) {
            // Twilio requires register, handleMessage, connect, accept and all
            // other Voice SDK calls to originate from the same Looper thread.
            // Firebase invokes this service on a worker thread, while Flutter
            // plugin calls and Android Service callbacks run on the main Looper.
            Map<String, String> voicePayload =
                    new HashMap<>(remoteMessage.getData());
            voiceHandler.post(() -> Voice.handleMessage(
                    getApplicationContext(), voicePayload, this));
        }
    }

    @Override
    public void onNewToken(@NonNull String token) {
        // Preserve FlutterFire's token refresh stream after replacing its no-op service.
        try {
            Class<?> liveData = Class.forName(
                    "io.flutter.plugins.firebase.messaging.FlutterFirebaseTokenLiveData");
            Object instance = liveData.getMethod("getInstance").invoke(null);
            Method postToken = liveData.getMethod("postToken", String.class);
            postToken.invoke(instance, token);
        } catch (Exception ignored) {
            // FirebaseMessaging.instance.getToken() still returns the latest token on next launch.
        }
    }

    @Override
    public void onCallInvite(@NonNull CallInvite callInvite) {
        Intent intent = new Intent(this, SwytchVoiceService.class);
        intent.setAction(SwytchVoiceService.ACTION_INCOMING);
        intent.putExtra(SwytchVoiceService.EXTRA_CALL_INVITE, callInvite);
        ContextCompat.startForegroundService(this, intent);
    }

    @Override
    public void onCancelledCallInvite(
            @NonNull CancelledCallInvite cancelledCallInvite,
            @Nullable CallException callException) {
        Intent intent = new Intent(this, SwytchVoiceService.class);
        intent.setAction(SwytchVoiceService.ACTION_CANCELLED);
        intent.putExtra(
                SwytchVoiceService.EXTRA_CANCELLED_INVITE,
                cancelledCallInvite);
        ContextCompat.startForegroundService(this, intent);
    }
}
