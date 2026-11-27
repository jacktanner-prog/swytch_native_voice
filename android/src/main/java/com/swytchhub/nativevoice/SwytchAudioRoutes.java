package com.swytchhub.nativevoice;

import android.content.Context;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Opt-in route chooser. It never starts a service, activates audio, or changes a call. */
final class SwytchAudioRoutes {
    private static boolean ownsSelection;
    private static AudioManager manager(Context context) {
        AudioManager audio=(AudioManager)context.getSystemService(Context.AUDIO_SERVICE);
        if(audio==null)throw new IllegalStateException("Audio outputs are unavailable.");
        return audio;
    }
    private static boolean active() {
        Object state=SwytchVoiceService.snapshot().get("state");
        return "connected".equals(state)||"reconnecting".equals(state);
    }
    private static Map<String,Object> route(String id,String name,String kind,boolean selected) {
        Map<String,Object> row=new HashMap<>();row.put("id",id);row.put("name",name);row.put("kind",kind);row.put("selected",selected);return row;
    }
    static Map<String,Object> snapshot(Context context) {
        AudioManager audio=manager(context);List<Map<String,Object>> rows=new ArrayList<>();
        boolean explicit=Build.VERSION.SDK_INT>=31;
        try { if(Build.VERSION.SDK_INT>=31) {
            AudioDeviceInfo current=audio.getCommunicationDevice();
            for(AudioDeviceInfo d:audio.getAvailableCommunicationDevices()) {
                String kind=kind(d.getType());
                String name=kind.equals("speaker")?"Speaker":kind.equals("handset")?"Handset":String.valueOf(d.getProductName());
                if(name.trim().isEmpty())name=kind.equals("bluetooth")?"Bluetooth headset":"Headset";
                rows.add(route("device:"+d.getId(),name,kind,current!=null&&current.getId()==d.getId()));
            }
        } } catch(SecurityException denied) { explicit=false;rows.clear(); }
        if(!explicit) {
            // Before API31 Android exposes no equivalent explicit communication-device picker.
            // Do not advertise a headset merely because it is paired or a media-only A2DP sink.
            rows.add(route("system","System default","system",!audio.isSpeakerphoneOn()));
            rows.add(route("speaker","Speaker","speaker",audio.isSpeakerphoneOn()));
        }
        Map<String,Object> result=new HashMap<>();result.put("active",active());result.put("routes",rows);
        result.put("explicitDeviceSelection",explicit);
        if(Build.VERSION.SDK_INT>=31&&!explicit)result.put("message","Allow Nearby devices/Bluetooth in Android app settings for the full output list. Speaker and system default remain available.");
        return result;
    }
    static Map<String,Object> select(Context context,String id,String callSid) {
        if(!active())throw new IllegalStateException("Connect a call before choosing its audio output.");
        if(callSid==null||callSid.isEmpty()||!callSid.equals(SwytchVoiceService.snapshot().get("callSid")))throw new IllegalStateException("This call changed. Close and reopen audio outputs.");
        AudioManager audio=manager(context);
        if("speaker".equals(id)||"system".equals(id)) {
            clearOwnedSelection(context);
            audio.setSpeakerphoneOn("speaker".equals(id));
        } else if(Build.VERSION.SDK_INT>=31) {
            AudioDeviceInfo target=null;
            for(AudioDeviceInfo d:audio.getAvailableCommunicationDevices())if(("device:"+d.getId()).equals(id))target=d;
            if(target==null)throw new IllegalArgumentException("That audio output disconnected. Refresh the list.");
            if(!audio.setCommunicationDevice(target))throw new IllegalStateException("Android could not select that output.");
            ownsSelection=true;
        } else throw new IllegalArgumentException("This Android version uses the system headset controls.");
        return snapshot(context);
    }
    static void clearOwnedSelection(Context context) {
        if(!ownsSelection)return;
        ownsSelection=false;
        if(Build.VERSION.SDK_INT>=31)try {manager(context).clearCommunicationDevice();}catch(RuntimeException ignored){}
    }
    private static String kind(int type) {
        switch(type) {
            case AudioDeviceInfo.TYPE_BUILTIN_SPEAKER:return "speaker";
            case AudioDeviceInfo.TYPE_BUILTIN_EARPIECE:return "handset";
            case AudioDeviceInfo.TYPE_BLUETOOTH_SCO:return "bluetooth";
            case 26: // TYPE_BLE_HEADSET (API31); never enumerate A2DP-only media devices.
            case 27:return "bluetooth";
            default:return "headset";
        }
    }
}
