import AVFoundation
import CallKit
import Flutter
import PushKit
import TwilioVoice
import UIKit

public final class SwytchNativeVoicePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let tokenKey = "swytch.native.voice.deviceToken"
  private static let bindingDateKey = "swytch.native.voice.bindingDate"

  private let pushRegistry = PKPushRegistry(queue: .main)
  private let audioDevice = DefaultAudioDevice()
  private let callController = CXCallController()
  private let provider: CXProvider

  private var eventSink: FlutterEventSink?
  private var accessToken: String?
  private var deviceToken: Data?
  private var callInvite: CallInvite?
  private var activeCall: Call?
  private var activeCallSid: String?
  private var activeCallUUID: UUID?
  private var isOutgoingCall = false
  private var speakerEnabled = false
  private var pendingOutgoingToken: String?
  private var pendingOutgoingTo: String?
  private var pendingOutgoingParameters: [String: String] = [:]
  private var muted = false
  private var onHold = false

  override init() {
    let configuration = CXProviderConfiguration(localizedName: "Swytch Mobile")
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportsVideo = false
    configuration.supportedHandleTypes = [.phoneNumber, .generic]
    provider = CXProvider(configuration: configuration)
    super.init()

    provider.setDelegate(self, queue: .main)
    audioDevice.isEnabled = false
    TwilioVoiceSDK.audioDevice = audioDevice
    pushRegistry.delegate = self
    pushRegistry.desiredPushTypes = [.voIP]
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SwytchNativeVoicePlugin()
    let methodChannel = FlutterMethodChannel(
      name: "com.swytchhub.swytchmobile/native_voice",
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: "com.swytchhub.swytchmobile/native_voice_events",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    emitState()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "isSupported":
      result(true)
    case "register":
      guard let token = arguments?["accessToken"] as? String, !token.isEmpty else {
        result(FlutterError(code: "invalid_token", message: "Missing access token", details: nil))
        return
      }
      accessToken = token
      registerBinding(result: result)
    case "unregister":
      guard let token = arguments?["accessToken"] as? String,
            let deviceToken = deviceToken ?? UserDefaults.standard.data(forKey: Self.tokenKey) else {
        result(nil)
        return
      }
      TwilioVoiceSDK.unregister(accessToken: token, deviceToken: deviceToken) { error in
        if let error = error {
          result(FlutterError(code: "unregister_failed", message: error.localizedDescription, details: nil))
        } else {
          UserDefaults.standard.removeObject(forKey: Self.tokenKey)
          UserDefaults.standard.removeObject(forKey: Self.bindingDateKey)
          result(nil)
        }
      }
    case "call":
      guard let token = arguments?["accessToken"] as? String,
            let to = arguments?["to"] as? String,
            !token.isEmpty, !to.isEmpty else {
        result(FlutterError(code: "invalid_call", message: "Access token and destination are required", details: nil))
        return
      }
      guard activeCall == nil, callInvite == nil, activeCallUUID == nil else {
        result(FlutterError(code: "call_busy", message: "End the current call before starting another.", details: nil))
        return
      }
      pendingOutgoingToken = token
      pendingOutgoingTo = to
      pendingOutgoingParameters = arguments?["parameters"] as? [String: String] ?? [:]
      requestStartCall(to: to, result: result)
    case "answer":
      guard let invite = callInvite else {
        result(FlutterError(code: "no_invite", message: "There is no incoming call", details: nil))
        return
      }
      requestTransaction(CXAnswerCallAction(call: invite.uuid), result: result)
    case "reject":
      guard let invite = callInvite else { result(nil); return }
      requestTransaction(CXEndCallAction(call: invite.uuid), result: result)
    case "hangup":
      endCurrentCall(result: result)
    case "setMuted":
      guard let uuid = activeCall?.uuid, let value = arguments?["value"] as? Bool else {
        result(nil); return
      }
      requestTransaction(CXSetMutedCallAction(call: uuid, muted: value), result: result)
    case "setHold":
      guard let uuid = activeCall?.uuid, let value = arguments?["value"] as? Bool else {
        result(nil); return
      }
      requestTransaction(CXSetHeldCallAction(call: uuid, onHold: value), result: result)
    case "setSpeaker":
      guard let value = arguments?["value"] as? Bool else { result(nil); return }
      // Do not replace DefaultAudioDevice's configuration callback. It is
      // needed to prepare the next call, and must never retain FlutterResult.
      do {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(value ? .speaker : .none)
        speakerEnabled = value
        result(nil)
      } catch {
        result(FlutterError(code: "audio_route_failed", message: error.localizedDescription, details: nil))
      }
    case "sendDigits":
      if let digits = arguments?["digits"] as? String { activeCall?.sendDigits(digits) }
      result(nil)
    case "currentState":
      result(statePayload())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func registerBinding(result: @escaping FlutterResult) {
    guard let token = accessToken, let pushToken = deviceToken else {
      // PushKit can return its token just after the Dart registration call.
      result(nil)
      return
    }
    TwilioVoiceSDK.register(accessToken: token, deviceToken: pushToken) { error in
      if let error = error {
        self.emitState(type: "registrationFailed", message: error.localizedDescription)
        result(FlutterError(code: "registration_failed", message: error.localizedDescription, details: nil))
      } else {
        UserDefaults.standard.set(pushToken, forKey: Self.tokenKey)
        UserDefaults.standard.set(Date(), forKey: Self.bindingDateKey)
        self.emitState(type: "registered")
        result(nil)
      }
    }
  }

  private func requestStartCall(to: String, result: @escaping FlutterResult) {
    let uuid = UUID()
    activeCallUUID = uuid
    isOutgoingCall = true
    let handle = CXHandle(type: .phoneNumber, value: to)
    let action = CXStartCallAction(call: uuid, handle: handle)
    callController.request(CXTransaction(action: action)) { error in
      DispatchQueue.main.async {
        if let error = error {
          self.activeCallUUID = nil
          self.pendingOutgoingToken = nil
          self.pendingOutgoingTo = nil
          result(FlutterError(code: "callkit_failed", message: error.localizedDescription, details: nil))
        } else {
          let update = CXCallUpdate()
          update.remoteHandle = handle
          update.supportsDTMF = true
          update.supportsHolding = true
          update.hasVideo = false
          self.provider.reportCall(with: uuid, updated: update)
          result(nil)
        }
      }
    }
  }

  private func endCurrentCall(result: @escaping FlutterResult) {
    guard let uuid = activeCall?.uuid ?? callInvite?.uuid ?? activeCallUUID else {
      // Recover stale UI while still disconnecting a call lacking a CallKit UUID.
      if let call = activeCall { call.disconnect() }
      else { emit(type: "disconnected", state: "disconnected") }
      result(nil)
      return
    }
    callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
      DispatchQueue.main.async {
        if error != nil {
          // CallKit can lose its transaction while Twilio still owns the call.
          self.disconnectCall(uuid: uuid)
        }
        result(nil)
      }
    }
  }

  private func disconnectCall(uuid: UUID) {
    if let invite = callInvite, invite.uuid == uuid {
      invite.reject()
      callInvite = nil
      activeCallUUID = nil
      activeCallSid = nil
      provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
      emit(type: "disconnected", state: "disconnected")
    } else if let call = activeCall, call.uuid == uuid || activeCallUUID == uuid {
      call.disconnect()
      provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    } else if activeCallUUID == uuid {
      activeCallUUID = nil
      pendingOutgoingToken = nil
      pendingOutgoingTo = nil
      provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
      emit(type: "disconnected", state: "disconnected")
    }
  }

  private func prepareCallAudio() {
    // CallKit activates audio after the start/answer transaction is fulfilled.
    audioDevice.isEnabled = false
    speakerEnabled = false
    audioDevice.block()
  }

  private func requestTransaction(_ action: CXAction, result: @escaping FlutterResult) {
    callController.request(CXTransaction(action: action)) { error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(code: "callkit_failed", message: error.localizedDescription, details: nil))
        } else {
          result(nil)
        }
      }
    }
  }

  private func emitState(type: String = "state", state: String? = nil, message: String? = nil) {
    var payload = statePayload()
    payload["type"] = type
    if let state = state { payload["state"] = state }
    if let message = message { payload["message"] = message }
    DispatchQueue.main.async { self.eventSink?(payload) }
  }

  private func emit(type: String, state: String, message: String? = nil) {
    emitState(type: type, state: state, message: message)
  }

  private func statePayload() -> [String: Any] {
    var payload: [String: Any] = [
      "state": activeCall == nil ? (callInvite == nil ? "idle" : "incoming") : "connected",
      "muted": muted,
      "onHold": onHold,
    ]
    if let sid = activeCall?.sid ?? activeCallSid ?? callInvite?.callSid {
      payload["callSid"] = sid
    }
    if let from = callInvite?.from { payload["from"] = from.replacingOccurrences(of: "client:", with: "") }
    if let to = pendingOutgoingTo ?? callInvite?.customParameters?["CalledNumber"] {
      payload["to"] = to
    }
    if let callerName = callInvite?.customParameters?["CallerName"], !callerName.isEmpty {
      payload["callerName"] = callerName
    }
    if let lineName = callInvite?.customParameters?["CalledLineName"], !lineName.isEmpty {
      payload["lineName"] = lineName
    }
    return payload
  }
}

extension SwytchNativeVoicePlugin: PKPushRegistryDelegate {
  public func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    deviceToken = pushCredentials.token
    guard let token = accessToken else { return }
    TwilioVoiceSDK.register(accessToken: token, deviceToken: pushCredentials.token) { error in
      if let error = error {
        self.emitState(type: "registrationFailed", message: error.localizedDescription)
      } else {
        UserDefaults.standard.set(pushCredentials.token, forKey: Self.tokenKey)
        UserDefaults.standard.set(Date(), forKey: Self.bindingDateKey)
        self.emitState(type: "registered")
      }
    }
  }

  public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    deviceToken = nil
    UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    UserDefaults.standard.removeObject(forKey: Self.bindingDateKey)
  }

  public func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: .main)
    completion()
  }
}

extension SwytchNativeVoicePlugin: NotificationDelegate {
  public func callInviteReceived(callInvite: CallInvite) {
    if activeCall != nil {
      callInvite.reject()
      emit(
        type: "incomingBusy",
        state: "connected",
        message: "Another incoming call was declined while your current call continues."
      )
      return
    }
    if self.callInvite != nil {
      callInvite.reject()
      emit(
        type: "incomingBusy",
        state: "incoming",
        message: "Another incoming call was declined."
      )
      return
    }
    self.callInvite = callInvite
    activeCallUUID = callInvite.uuid
    isOutgoingCall = false
    activeCallSid = callInvite.callSid
    UserDefaults.standard.set(Date(), forKey: Self.bindingDateKey)

    let from = (callInvite.from ?? "Swytch caller").replacingOccurrences(of: "client:", with: "")
    let callerName = callInvite.customParameters?["CallerName"] ?? ""
    let calledNumber = callInvite.customParameters?["CalledNumber"] ?? ""
    let lineName = callInvite.customParameters?["CalledLineName"] ?? ""
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: from)
    let callerLabel = callerName.isEmpty ? from : callerName
    let lineLabel = lineName.isEmpty ? calledNumber : lineName
    update.localizedCallerName = lineLabel.isEmpty
      ? callerLabel
      : "\(callerLabel) • to \(lineLabel)"
    update.supportsDTMF = true
    update.supportsHolding = true
    update.hasVideo = false
    provider.reportNewIncomingCall(with: callInvite.uuid, update: update) { error in
      if let error = error {
        callInvite.reject()
        self.callInvite = nil
        self.activeCallUUID = nil
        self.activeCallSid = nil
        self.emit(type: "failed", state: "failed", message: error.localizedDescription)
      } else {
        self.emit(type: "incoming", state: "incoming")
      }
    }
  }

  public func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
    guard let invite = callInvite, invite.callSid == cancelledCallInvite.callSid else { return }
    provider.reportCall(with: invite.uuid, endedAt: Date(), reason: .remoteEnded)
    callInvite = nil
    activeCallUUID = nil
    activeCallSid = nil
    emit(type: "cancelled", state: "disconnected", message: error.localizedDescription)
  }
}

extension SwytchNativeVoicePlugin: CXProviderDelegate {
  public func providerDidReset(_ provider: CXProvider) {
    audioDevice.isEnabled = false
    callInvite?.reject()
    activeCall?.disconnect()
    callInvite = nil
    activeCall = nil
    activeCallUUID = nil
    pendingOutgoingToken = nil
    pendingOutgoingTo = nil
    activeCallSid = nil
    emit(type: "reset", state: "idle")
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    audioDevice.isEnabled = true
    if speakerEnabled {
      try? audioSession.overrideOutputAudioPort(.speaker)
    }
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    audioDevice.isEnabled = false
  }

  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    guard let token = pendingOutgoingToken, let to = pendingOutgoingTo else {
      action.fail(); return
    }
    activeCallUUID = action.callUUID
    isOutgoingCall = true
    prepareCallAudio()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    let options = ConnectOptions(accessToken: token) { builder in
      var parameters = self.pendingOutgoingParameters
      parameters["To"] = to
      builder.params = parameters
      builder.uuid = action.callUUID
    }
    activeCall = TwilioVoiceSDK.connect(options: options, delegate: self)
    emit(type: "connecting", state: "connecting")
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard let invite = callInvite else { action.fail(); return }
    activeCallSid = invite.callSid
    activeCallUUID = invite.uuid
    isOutgoingCall = false
    prepareCallAudio()
    let options = AcceptOptions(callInvite: invite) { builder in builder.uuid = invite.uuid }
    activeCall = invite.accept(options: options, delegate: self)
    callInvite = nil
    emit(type: "connecting", state: "connecting")
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    disconnectCall(uuid: action.callUUID)
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    guard let call = activeCall else { action.fail(); return }
    call.isMuted = action.isMuted
    muted = action.isMuted
    emitState()
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
    guard let call = activeCall else { action.fail(); return }
    call.isOnHold = action.isOnHold
    onHold = action.isOnHold
    if !action.isOnHold { audioDevice.isEnabled = true }
    emitState()
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    activeCall?.sendDigits(action.digits)
    action.fulfill()
  }
}

extension SwytchNativeVoicePlugin: CallDelegate {
  public func callDidStartRinging(call: Call) {
    activeCallSid = call.sid
    emit(type: "ringing", state: "ringing")
  }

  public func callDidConnect(call: Call) {
    activeCallSid = call.sid
    if isOutgoingCall, let uuid = call.uuid {
      provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }
    emit(type: "connected", state: "connected")
  }

  public func callIsReconnecting(call: Call, error: Error) {
    emit(type: "reconnecting", state: "reconnecting", message: error.localizedDescription)
  }

  public func callDidReconnect(call: Call) {
    emit(type: "connected", state: "connected")
  }

  public func callDidFailToConnect(call: Call, error: Error) {
    guard activeCall === call else { return }
    if let uuid = call.uuid { provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
    activeCall = nil
    activeCallUUID = nil
    pendingOutgoingToken = nil
    pendingOutgoingTo = nil
    emit(type: "failed", state: "failed", message: error.localizedDescription)
    activeCallSid = nil
  }

  public func callDidDisconnect(call: Call, error: Error?) {
    guard activeCall === call else { return }
    if let uuid = call.uuid {
      provider.reportCall(with: uuid, endedAt: Date(), reason: error == nil ? .remoteEnded : .failed)
    }
    activeCall = nil
    activeCallUUID = nil
    pendingOutgoingToken = nil
    pendingOutgoingTo = nil
    speakerEnabled = false
    muted = false
    onHold = false
    emit(type: "disconnected", state: "disconnected", message: error?.localizedDescription)
    activeCallSid = nil
  }

  public func callDidReceiveQualityWarnings(
    call: Call,
    currentWarnings: Set<NSNumber>,
    previousWarnings: Set<NSNumber>
  ) {}
}
