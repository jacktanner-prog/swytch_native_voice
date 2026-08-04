package com.swytchhub.nativevoice;

import android.content.Intent;

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

public final class SwytchVoiceMessagingService extends FirebaseMessagingService
        implements MessageListener {

    @Override
    public void onMessageReceived(@NonNull RemoteMessage remoteMessage) {
        if (!remoteMessage.getData().isEmpty()) {
            Voice.handleMessage(this, remoteMessage.getData(), this);
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
        intent.putExtra(SwytchVoiceService.EXTRA_CANCELLED_INVITE, cancelledCallInvite);
        ContextCompat.startForegroundService(this, intent);
    }
}
