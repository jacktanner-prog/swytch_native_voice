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
      guard let uuid = activeCall?.uuid else { result(nil); return }
      requestTransaction(CXEndCallAction(call: uuid), result: result)
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
      audioDevice.block = {
        do {
          try AVAudioSession.sharedInstance().overrideOutputAudioPort(value ? .speaker : .none)
          result(nil)
        } catch {
          result(FlutterError(code: "audio_route_failed", message: error.localizedDescription, details: nil))
        }
      }
      audioDevice.block()
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
        self.emit(type: "registrationFailed", state: "idle", message: error.localizedDescription)
        result(FlutterError(code: "registration_failed", message: error.localizedDescription, details: nil))
      } else {
        UserDefaults.standard.set(pushToken, forKey: Self.tokenKey)
        UserDefaults.standard.set(Date(), forKey: Self.bindingDateKey)
        self.emit(type: "registered", state: "idle")
        result(nil)
      }
    }
  }

  private func requestStartCall(to: String, result: @escaping FlutterResult) {
    let uuid = UUID()
    let handle = CXHandle(type: .phoneNumber, value: to)
    let action = CXStartCallAction(call: uuid, handle: handle)
    callController.request(CXTransaction(action: action)) { error in
      DispatchQueue.main.async {
        if let error = error {
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
    if let sid = activeCall?.callSid ?? activeCallSid ?? callInvite?.callSid {
      payload["callSid"] = sid
    }
    if let from = callInvite?.from { payload["from"] = from.replacingOccurrences(of: "client:", with: "") }
    if let to = pendingOutgoingTo { payload["to"] = to }
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
        self.emit(type: "registrationFailed", state: "idle", message: error.localizedDescription)
      } else {
        UserDefaults.standard.set(pushCredentials.token, forKey: Self.tokenKey)
        UserDefaults.standard.set(Date(), forKey: Self.bindingDateKey)
        self.emit(type: "registered", state: "idle")
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
    self.callInvite = callInvite
    activeCallSid = callInvite.callSid
    UserDefaults.standard.set(Date(), forKey: Self.bindingDateKey)

    let from = (callInvite.from ?? "Swytch caller").replacingOccurrences(of: "client:", with: "")
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: from)
    update.supportsDTMF = true
    update.supportsHolding = true
    update.hasVideo = false
    provider.reportNewIncomingCall(with: callInvite.uuid, update: update) { error in
      if let error = error {
        callInvite.reject()
        self.callInvite = nil
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
    emit(type: "cancelled", state: "disconnected", message: error.localizedDescription)
  }
}

extension SwytchNativeVoicePlugin: CXProviderDelegate {
  public func providerDidReset(_ provider: CXProvider) {
    audioDevice.isEnabled = false
    callInvite = nil
    activeCall = nil
    activeCallSid = nil
    emit(type: "reset", state: "idle")
  }

  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    audioDevice.isEnabled = true
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    audioDevice.isEnabled = false
  }

  public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    guard let token = pendingOutgoingToken, let to = pendingOutgoingTo else {
      action.fail(); return
    }
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
    let options = AcceptOptions(callInvite: invite) { builder in builder.uuid = invite.uuid }
    activeCall = invite.accept(options: options, delegate: self)
    callInvite = nil
    emit(type: "connecting", state: "connecting")
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let invite = callInvite, invite.uuid == action.callUUID {
      invite.reject()
      callInvite = nil
    } else if let call = activeCall, call.uuid == action.callUUID {
      call.disconnect()
    }
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
    activeCallSid = call.callSid
    emit(type: "ringing", state: "ringing")
  }

  public func callDidConnect(call: Call) {
    activeCallSid = call.callSid
    if let uuid = call.uuid { provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }
    emit(type: "connected", state: "connected")
  }

  public func callIsReconnecting(call: Call, error: Error) {
    emit(type: "reconnecting", state: "reconnecting", message: error.localizedDescription)
  }

  public func callDidReconnect(call: Call) {
    emit(type: "connected", state: "connected")
  }

  public func callDidFailToConnect(call: Call, error: Error) {
    if let uuid = call.uuid { provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
    activeCall = nil
    emit(type: "failed", state: "failed", message: error.localizedDescription)
    activeCallSid = nil
  }

  public func callDidDisconnect(call: Call, error: Error?) {
    if let uuid = call.uuid {
      provider.reportCall(with: uuid, endedAt: Date(), reason: error == nil ? .remoteEnded : .failed)
    }
    activeCall = nil
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
