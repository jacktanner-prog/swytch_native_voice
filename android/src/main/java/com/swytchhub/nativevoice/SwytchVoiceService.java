package com.swytchhub.nativevoice;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;

import com.twilio.voice.Call;
import com.twilio.voice.CallException;
import com.twilio.voice.CallInvite;
import com.twilio.voice.CancelledCallInvite;
import com.twilio.voice.ConnectOptions;
import com.twilio.voice.DefaultAudioDevice;
import com.twilio.voice.AcceptOptions;
import com.twilio.voice.AudioOptions;
import com.twilio.voice.Voice;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

public final class SwytchVoiceService extends Service {
    private static final String TAG = "SwytchVoiceService";
    static final String ACTION_INCOMING = "swytch.voice.INCOMING";
    static final String ACTION_CANCELLED = "swytch.voice.CANCELLED";
    static final String ACTION_CALL = "swytch.voice.CALL";
    static final String ACTION_ANSWER = "swytch.voice.ANSWER";
    static final String ACTION_REJECT = "swytch.voice.REJECT";
    static final String ACTION_HANGUP = "swytch.voice.HANGUP";
    static final String ACTION_MUTE = "swytch.voice.MUTE";
    static final String ACTION_HOLD = "swytch.voice.HOLD";
    static final String ACTION_SPEAKER = "swytch.voice.SPEAKER";
    static final String ACTION_DIGITS = "swytch.voice.DIGITS";

    static final String EXTRA_CALL_INVITE = "callInvite";
    static final String EXTRA_CANCELLED_INVITE = "cancelledInvite";
    static final String EXTRA_ACCESS_TOKEN = "accessToken";
    static final String EXTRA_TO = "to";
    static final String EXTRA_PARAMETERS = "parameters";
    static final String EXTRA_VALUE = "value";
    static final String EXTRA_DIGITS = "digits";

    private static final String CHANNEL_INCOMING = "swytch_native_voice_incoming";
    private static final String CHANNEL_ACTIVE = "swytch_native_voice_active";
    private static final int NOTIFICATION_ID = 7801;

    private static final Map<String, Object> STATE = new HashMap<>();

    private CallInvite pendingInvite;
    private Call activeCall;
    private boolean muted;
    private boolean onHold;
    private String lastTo;

    static {
        STATE.put("state", "idle");
        STATE.put("muted", false);
        STATE.put("onHold", false);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createChannels();
        // Some Android vendors expose broken hardware AEC/NS implementations
        // that crash inside the native WebRTC audio stack. Twilio supports
        // explicitly selecting its software processing before any call starts.
        DefaultAudioDevice audioDevice = new DefaultAudioDevice();
        audioDevice.setUseHardwareAcousticEchoCanceler(false);
        audioDevice.setUseHardwareNoiseSuppressor(false);
        Voice.setAudioDevice(audioDevice);
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || intent.getAction() == null) return START_NOT_STICKY;

        try {
            handleAction(intent);
        } catch (RuntimeException exception) {
            Log.e(TAG, "Native voice action failed: " + intent.getAction(), exception);
            activeCall = null;
            pendingInvite = null;
            updateState("failed", "failed",
                    exception.getMessage() == null ? "Android could not start the call" : exception.getMessage());
            stopVoiceService();
        }
        return START_NOT_STICKY;
    }

    private void handleAction(Intent intent) {
        switch (intent.getAction()) {
            case ACTION_INCOMING: {
                CallInvite incomingInvite = intent.getParcelableExtra(EXTRA_CALL_INVITE);
                if (incomingInvite != null && (activeCall != null || pendingInvite != null)) {
                    incomingInvite.reject(this);
                    if (activeCall != null) {
                        updateState("incomingBusy", "connected",
                                "Another incoming call was declined while your current call continues.");
                        startForegroundCompat(buildActiveNotification("Active call"), true);
                    } else {
                        updateState("incomingBusy", "incoming",
                                "Another incoming call was declined.");
                    }
                    break;
                }
                pendingInvite = incomingInvite;
                if (pendingInvite != null) {
                    updateState("incoming", "incoming", null);
                    showIncomingNotification();
                }
                break;
            }
            case ACTION_CANCELLED:
                // A cancellation can wake a stopped app. Satisfy Android's
                // foreground-service deadline before processing it.
                startForegroundCompat(buildActiveNotification("Updating incoming call"), false);
                CancelledCallInvite cancelled = intent.getParcelableExtra(EXTRA_CANCELLED_INVITE);
                if (cancelled != null && pendingInvite != null
                        && cancelled.getCallSid().equals(pendingInvite.getCallSid())) {
                    pendingInvite = null;
                    updateState("cancelled", "disconnected", null);
                    stopVoiceService();
                } else if (activeCall == null) {
                    stopVoiceService();
                } else {
                    updateState("state", "connected", null);
                }
                break;
            case ACTION_CALL:
                // startForegroundService() must be promoted immediately on
                // Android O+, before Twilio initializes its media stack.
                startForegroundCompat(buildActiveNotification("Preparing call"), false);
                connect(
                        intent.getStringExtra(EXTRA_ACCESS_TOKEN),
                        intent.getStringExtra(EXTRA_TO),
                        intent.getSerializableExtra(EXTRA_PARAMETERS));
                break;
            case ACTION_ANSWER:
                answer();
                break;
            case ACTION_REJECT:
                reject();
                break;
            case ACTION_HANGUP:
                if (activeCall != null) activeCall.disconnect();
                break;
            case ACTION_MUTE:
                muted = intent.getBooleanExtra(EXTRA_VALUE, false);
                if (activeCall != null) activeCall.mute(muted);
                updateState("state", activeCall == null ? "idle" : "connected", null);
                break;
            case ACTION_HOLD:
                onHold = intent.getBooleanExtra(EXTRA_VALUE, false);
                if (activeCall != null) activeCall.hold(onHold);
                updateState("state", activeCall == null ? "idle" : "connected", null);
                break;
            case ACTION_SPEAKER:
                setSpeaker(intent.getBooleanExtra(EXTRA_VALUE, false));
                break;
            case ACTION_DIGITS:
                if (activeCall != null) activeCall.sendDigits(intent.getStringExtra(EXTRA_DIGITS));
                break;
            default:
                break;
        }
    }

    @SuppressWarnings("unchecked")
    private void connect(String accessToken, String to, Object rawParameters) {
        if (accessToken == null || accessToken.isEmpty() || to == null || to.isEmpty()) {
            updateState("failed", "failed", "Access token and destination are required");
            return;
        }
        if (!hasMicrophonePermission()) {
            updateState("failed", "failed", "Microphone permission is required to place a call");
            stopVoiceService();
            return;
        }
        lastTo = to;
        Map<String, String> params = rawParameters instanceof Map
                ? new HashMap<>((Map<String, String>) rawParameters)
                : new HashMap<>();
        params.put("To", to);
        // The legacy community plugin crashed on specific MediaTek devices in
        // AudioMTKGainController. Disable WebRTC automatic gain control for the
        // isolated native module so that hardware path is not requested.
        AudioOptions audioOptions = new AudioOptions.Builder()
                .autoGainControl(false)
                .build();
        ConnectOptions options = new ConnectOptions.Builder(accessToken)
                .params(params)
                .audioOptions(audioOptions)
                .build();
        updateState("connecting", "connecting", null);
        startForegroundCompat(buildActiveNotification("Calling " + to), true);
        activeCall = Voice.connect(this, options, callListener);
    }

    private void answer() {
        if (pendingInvite == null) return;
        if (!hasMicrophonePermission()) {
            pendingInvite.reject(this);
            pendingInvite = null;
            updateState("failed", "failed", "Microphone permission is required to answer a call");
            stopVoiceService();
            return;
        }
        AudioOptions audioOptions = new AudioOptions.Builder()
                .autoGainControl(false)
                .build();
        AcceptOptions acceptOptions = new AcceptOptions.Builder()
                .audioOptions(audioOptions)
                .build();
        updateState("connecting", "connecting", null);
        startForegroundCompat(buildActiveNotification("Connecting call"), true);
        activeCall = pendingInvite.accept(this, acceptOptions, callListener);
        pendingInvite = null;
    }

    private void reject() {
        if (pendingInvite != null) pendingInvite.reject(this);
        pendingInvite = null;
        updateState("rejected", "disconnected", null);
        stopVoiceService();
    }

    private void setSpeaker(boolean enabled) {
        AudioManager audio = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        audio.setMode(AudioManager.MODE_IN_COMMUNICATION);
        audio.setSpeakerphoneOn(enabled);
    }

    private void showIncomingNotification() {
        String caller = pendingInvite == null || pendingInvite.getFrom() == null
                ? "Swytch caller"
                : pendingInvite.getFrom().replace("client:", "");
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch == null) launch = new Intent();
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent openApp = PendingIntent.getActivity(
                this, 101, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        PendingIntent answer = servicePendingIntent(ACTION_ANSWER, 102);
        PendingIntent decline = servicePendingIntent(ACTION_REJECT, 103);

        Notification notification = new NotificationCompat.Builder(this, CHANNEL_INCOMING)
                .setSmallIcon(R.drawable.swytch_ic_call)
                .setContentTitle("Incoming Swytch call")
                .setContentText(caller)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setOngoing(true)
                .setFullScreenIntent(openApp, true)
                .setContentIntent(openApp)
                .addAction(0, "Decline", decline)
                .addAction(0, "Answer", answer)
                .build();
        // Incoming FCM messages arrive while the application may be fully
        // backgrounded. Run as a non-microphone foreground service until the
        // user explicitly answers the call.
        startForegroundCompat(notification, false);
    }

    private Notification buildActiveNotification(String text) {
        PendingIntent hangup = servicePendingIntent(ACTION_HANGUP, 104);
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent openApp = launch == null ? null : PendingIntent.getActivity(
                this, 105, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new NotificationCompat.Builder(this, CHANNEL_ACTIVE)
                .setSmallIcon(R.drawable.swytch_ic_call)
                .setContentTitle("Swytch Mobile")
                .setContentText(text)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setOngoing(true)
                .setContentIntent(openApp)
                .addAction(0, "Hang up", hangup)
                .build();
    }

    private PendingIntent servicePendingIntent(String action, int requestCode) {
        Intent intent = new Intent(this, SwytchVoiceService.class);
        intent.setAction(action);
        return PendingIntent.getService(
                this, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private void startForegroundCompat(Notification notification, boolean microphone) {
        int type = 0;
        if (microphone && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            type = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                    | ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE;
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Keep an incoming invitation alive without attempting background
            // microphone access. MANAGE_OWN_CALLS satisfies this type.
            type = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL;
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type);
    }

    private boolean hasMicrophonePermission() {
        return ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }

    private void createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel incoming = new NotificationChannel(
                CHANNEL_INCOMING, "Incoming Swytch calls", NotificationManager.IMPORTANCE_HIGH);
        incoming.setDescription("Incoming calls to your Swytch number");
        incoming.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
        NotificationChannel active = new NotificationChannel(
                CHANNEL_ACTIVE, "Active Swytch calls", NotificationManager.IMPORTANCE_LOW);
        manager.createNotificationChannel(incoming);
        manager.createNotificationChannel(active);
    }

    private void stopVoiceService() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.cancel(NOTIFICATION_ID);
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void updateState(String type, String state, String message) {
        synchronized (STATE) {
            STATE.put("type", type);
            STATE.put("state", state);
            STATE.put("muted", muted);
            STATE.put("onHold", onHold);
            if (message != null) STATE.put("message", message); else STATE.remove("message");
            if (lastTo != null) STATE.put("to", lastTo);
            if (pendingInvite != null) {
                STATE.put("callSid", pendingInvite.getCallSid());
                STATE.put("from", pendingInvite.getFrom());
            } else if (activeCall != null && activeCall.getSid() != null) {
                STATE.put("callSid", activeCall.getSid());
            }
        }
        SwytchNativeVoicePlugin.emitFromNative(snapshot());
    }

    static Map<String, Object> snapshot() {
        synchronized (STATE) {
            return new HashMap<>(STATE);
        }
    }

    private final Call.Listener callListener = new Call.Listener() {
        @Override
        public void onRinging(@NonNull Call call) {
            updateState("ringing", "ringing", null);
        }

        @Override
        public void onConnectFailure(@NonNull Call call, @NonNull CallException exception) {
            activeCall = null;
            updateState("failed", "failed", exception.getMessage());
            stopVoiceService();
        }

        @Override
        public void onConnected(@NonNull Call call) {
            activeCall = call;
            updateState("connected", "connected", null);
            startForegroundCompat(buildActiveNotification("Active call"), true);
        }

        @Override
        public void onReconnecting(@NonNull Call call, @NonNull CallException exception) {
            updateState("reconnecting", "reconnecting", exception.getMessage());
        }

        @Override
        public void onReconnected(@NonNull Call call) {
            updateState("connected", "connected", null);
        }

        @Override
        public void onDisconnected(@NonNull Call call, @Nullable CallException exception) {
            activeCall = null;
            muted = false;
            onHold = false;
            updateState("disconnected", "disconnected", exception == null ? null : exception.getMessage());
            stopVoiceService();
        }

        @Override
        public void onCallQualityWarningsChanged(
                @NonNull Call call,
                @NonNull Set<Call.CallQualityWarning> currentWarnings,
                @NonNull Set<Call.CallQualityWarning> previousWarnings) {
            // State remains connected; Voice Insights receives the detailed telemetry.
        }
    };
}
