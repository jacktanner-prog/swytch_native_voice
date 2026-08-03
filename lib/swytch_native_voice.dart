import 'dart:async';

import 'package:flutter/services.dart';

enum SwytchVoiceCallState {
  idle,
  incoming,
  connecting,
  ringing,
  connected,
  reconnecting,
  disconnected,
  failed,
}

class SwytchVoiceEvent {
  const SwytchVoiceEvent({
    required this.type,
    this.callState = SwytchVoiceCallState.idle,
    this.callSid,
    this.from,
    this.to,
    this.message,
    this.muted = false,
    this.onHold = false,
  });

  final String type;
  final SwytchVoiceCallState callState;
  final String? callSid;
  final String? from;
  final String? to;
  final String? message;
  final bool muted;
  final bool onHold;

  factory SwytchVoiceEvent.fromMap(Map<dynamic, dynamic> map) {
    final stateName = (map['state'] ?? 'idle').toString();
    final state = SwytchVoiceCallState.values.firstWhere(
      (value) => value.name == stateName,
      orElse: () => SwytchVoiceCallState.idle,
    );
    return SwytchVoiceEvent(
      type: (map['type'] ?? 'state').toString(),
      callState: state,
      callSid: map['callSid']?.toString(),
      from: map['from']?.toString(),
      to: map['to']?.toString(),
      message: map['message']?.toString(),
      muted: map['muted'] == true,
      onHold: map['onHold'] == true,
    );
  }
}

class SwytchNativeVoice {
  SwytchNativeVoice._();

  static const MethodChannel _methods = MethodChannel(
    'com.swytchhub.swytchmobile/native_voice',
  );
  static const EventChannel _events = EventChannel(
    'com.swytchhub.swytchmobile/native_voice_events',
  );

  static Stream<SwytchVoiceEvent>? _eventStream;

  static Stream<SwytchVoiceEvent> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => SwytchVoiceEvent.fromMap(event as Map))
      .asBroadcastStream();

  static Future<bool> isSupported() async =>
      await _methods.invokeMethod<bool>('isSupported') ?? false;

  static Future<void> register({required String accessToken}) =>
      _methods.invokeMethod<void>('register', {'accessToken': accessToken});

  static Future<void> unregister({required String accessToken}) =>
      _methods.invokeMethod<void>('unregister', {'accessToken': accessToken});

  static Future<void> call({
    required String accessToken,
    required String to,
    Map<String, String> parameters = const {},
  }) => _methods.invokeMethod<void>('call', {
    'accessToken': accessToken,
    'to': to,
    'parameters': parameters,
  });

  static Future<void> answer() => _methods.invokeMethod<void>('answer');
  static Future<void> reject() => _methods.invokeMethod<void>('reject');
  static Future<void> hangup() => _methods.invokeMethod<void>('hangup');
  static Future<void> setMuted(bool value) =>
      _methods.invokeMethod<void>('setMuted', {'value': value});
  static Future<void> setHold(bool value) =>
      _methods.invokeMethod<void>('setHold', {'value': value});
  static Future<void> setSpeaker(bool value) =>
      _methods.invokeMethod<void>('setSpeaker', {'value': value});
  static Future<void> sendDigits(String digits) =>
      _methods.invokeMethod<void>('sendDigits', {'digits': digits});

  static Future<Map<String, dynamic>> currentState() async {
    final value = await _methods.invokeMapMethod<String, dynamic>(
      'currentState',
    );
    return value ?? const <String, dynamic>{};
  }
}
