# Twilio Programmable Voice Android SDK 3.2.0+
# Required when the host application's release build enables R8/ProGuard.
-keep class com.twilio.** { *; }
-keep class tvo.webrtc.** { *; }
-dontwarn tvo.webrtc.**
-keep class com.twilio.voice.** { *; }
-keepattributes InnerClasses

# Preserve the Flutter plugin and Android service entry points.
-keep class com.swytchhub.nativevoice.** { *; }

# Accessed reflectively to preserve FlutterFire's token-refresh stream after
# the native Twilio messaging service replaces FlutterFire's no-op service.
-keep class io.flutter.plugins.firebase.messaging.FlutterFirebaseTokenLiveData { *; }

# Swytch Mobile uses the Latin ML Kit text recognizer for ID scanning. The
# Flutter ML Kit package references optional recognizers that are not bundled.
# These consumer rules are merged into the host app's R8 release configuration.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
