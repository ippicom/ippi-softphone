//
//  SIPManager.swift
//  ippi Softphone
//
//  Created by ippi on 16/02/2026.
//

import Foundation
import linphone
import linphonesw
import Network

// Note: We use VoIPCall (defined in Models/Call.swift) for our app's call model
// to avoid conflicts with linphonesw.Call from the SDK.
// Similarly, we use SIPRegistrationState for our registration states
// to avoid conflict with linphonesw.RegistrationState.

// Type aliases to avoid conflicts between linphonesw types and our app types
private typealias LPCall = Call
private typealias LPRegistrationState = RegistrationState
private typealias LPCallState = Call.State

// MARK: - SIP Manager Protocol

protocol SIPManagerProtocol: AnyObject {
    var registrationState: SIPRegistrationState { get }
    var isInitialized: Bool { get }
    var currentCall: VoIPCall? { get }

    func initialize() throws
    func register(username: String, password: String, domain: String) throws
    func unregister()
    func makeCall(to address: String, uuid: UUID?) throws -> VoIPCall
    func answer(call: VoIPCall) throws
    func hangup(call: VoIPCall) throws
    func setMute(_ muted: Bool, for call: VoIPCall)
    func setHold(_ held: Bool, for call: VoIPCall) throws
    func sendDTMF(_ digit: Character, for call: VoIPCall)
    func transfer(call: VoIPCall, to address: String) throws
    func activateAudioSession(_ activated: Bool)
    func configureAudioSession()
}

// MARK: - Linphone Call Wrapper

/// Wrapper class to hold linphone Call reference (class type for dictionary key)
private class LinphoneCallWrapper {
    let lpCall: LPCall
    init(_ call: LPCall) {
        self.lpCall = call
    }
}

// MARK: - SIP Manager

@MainActor
final class SIPManager: SIPManagerProtocol {
    // MARK: - Constants

    private static let validDTMFChars = CharacterSet(charactersIn: "0123456789*#ABCDabcd")
    private static let dangerousSIPChars = CharacterSet(charactersIn: "<>\"'\\`|;")
    // linphonesw.LogLevel bitmask: Debug=1, Trace=2, Message=4, Warning=8, Error=16, Fatal=32
    private nonisolated static let traceLogMask: UInt = 62   // Message + Warning + Error + Fatal + Trace
    private nonisolated static let errorLogMask: UInt = 48    // Error + Fatal

    // MARK: - Properties

    private(set) var registrationState: SIPRegistrationState = .none
    private(set) var currentCall: VoIPCall?
    
    /// Last registration error info (code + reason) when registration fails
    private(set) var lastRegistrationError: (code: Int, reason: String)?
    
    // Callbacks
    var onRegistrationStateChanged: ((SIPRegistrationState) -> Void)?
    var onCallStateChanged: ((VoIPCall) -> Void)?
    var onIncomingCall: ((VoIPCall) -> Void)?
    
    // Linphone Core
    private var core: Core?
    private var coreDelegate: CoreDelegateStub?
    private var iterateTask: Task<Void, Never>?
    
    // Call mapping (UUID to linphone Call wrapper)
    private var calls: [UUID: LinphoneCallWrapper] = [:]

    // Track active VoIPCalls by UUID for resolving calls without external dependencies
    private var activeCalls: [UUID: VoIPCall] = [:]

    // SIP Call-ID → app UUID mapping for PushKit reconciliation.
    // When SIP INVITE arrives before VoIP push, PushKit can look up the existing UUID.
    private var sipCallIdToUUID: [String: UUID] = [:]

    // Pending incoming call from PushKit/CallKit (to sync via callId)
    private var pendingIncomingCallUUID: UUID?
    private var pendingIncomingCallId: String?
    private var pendingIncomingCallTimestamp: Date?
    private let pendingCallTTL: TimeInterval = 30
    
    private(set) var isInitialized = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    
    // Polling control - only iterate when in foreground or during active call
    private var isInForeground = true

    // DTMF rate limiting - prevent rapid-fire DTMF spam
    private var lastDTMFTime: Date?
    private let dtmfMinInterval: TimeInterval = 0.15 // 150ms between DTMF tones
    
    // Registration retry
    private var registrationRetryCount = 0
    private let maxRegistrationRetries = 3
    private var registrationRetryTask: Task<Void, Never>?
    
    // Network monitoring
    private var networkMonitor: NWPathMonitor?
    private var isNetworkAvailable = true
    private var lastNetworkStatus: NWPath.Status?
    
    // Liblinphone logging bridge — keep a strong ref to the LoggingService
    // singleton wrapper so getSwiftObject(cObject:) returns the cached instance
    // instead of creating temporary wrappers that crash on dealloc (retain cycle)
    nonisolated(unsafe) private var loggingServiceRef: LoggingService?
    private var loggingDelegate: LoggingServiceDelegateStub?
    private var debugModeObserver: NSObjectProtocol?
    
    // MARK: - Initialization
    
    init() {
        Log.sip.success("SIPManager created")
        setupDebugModeObserver()
    }
    
    // MARK: - Core Lifecycle
    
    func initialize() throws {
        guard !isInitialized else {
            Log.sip.call("SIP stack already initialized")
            return
        }

        Log.sip.call("Initializing SIP stack with liblinphone")

        // Configure liblinphone logging BEFORE creating Core
        configureLinphoneLogging()

        let factory = Factory.Instance

        // Create the Core
        guard let newCore = try? factory.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil) else {
            throw SIPError.notInitialized
        }
        core = newCore
        let core = newCore
        
        // Configure transports - TLS only for secure communication
        let transports = try factory.createTransports()
        transports.udpPort = Constants.SIP.udpPort  // 0 = disabled
        transports.tcpPort = Constants.SIP.tcpPort  // 0 = disabled
        transports.tlsPort = Constants.SIP.tlsPort  // -1 = random port for TLS
        try core.setTransports(newValue: transports)
        
        Log.sip.call("Transports configured: TLS=\(transports.tlsPort) (UDP/TCP disabled)")
        
        // Set user agent
        core.setUserAgent(name: Constants.App.userAgent, version: "1.0")
        
        // Audio configuration
        core.echoCancellationEnabled = true

        // CallKit integration — tell linphone we use CallKit so it waits
        // for audio session activation before starting the AudioUnit.
        #if os(iOS)
        if let cCore = core.getCobject {
            linphone_core_enable_callkit(cCore, 1)
        }
        #endif

        // Allow multiple simultaneous calls (call-waiting / hold + active)
        core.maxCalls = Constants.CallKit.maximumCallsPerCallGroup

        // CallKit handles ringing — tell linphone NOT to play its own ringtone
        // or early media audio. Without this, linphone tries to activate audio
        // when INVITE arrives, before CallKit grants audio priority, causing
        // !pri errors that can destroy the call before the user answers.
        core.nativeRingingEnabled = true
        core.ring = ""
        core.ringDuringIncomingEarlyMedia = false
        
        // Configure DTMF
        core.useRfc2833ForDtmf = true  // Send DTMF via RTP (RFC 2833)
        core.useInfoForDtmf = false    // Don't use SIP INFO for DTMF
        
        // Configure ringback tone from linphone framework resources
        configureRingbackTone(core: core)
        
        // Log configured sound paths for debugging
        Log.sip.debug("Ring sound: \(core.ring ?? "default")")
        Log.sip.debug("Ringback sound: \(core.ringback ?? "not configured")")
        
        // Configure NAT policy with STUN if enabled
        configureNATPolicy(core: core)
        
        // Configure media encryption based on user preference
        let srtpEnabled = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.srtpEnabled)
        try core.setMediaencryption(newValue: srtpEnabled ? .SRTP : .None)
        Log.sip.call("Media encryption configured: \(srtpEnabled ? "SRTP" : "none")")
        
        // Setup delegate for callbacks
        coreDelegate = CoreDelegateStub(
            onGlobalStateChanged: { [weak self] (lc: Core, state: GlobalState, message: String) in
                Task { @MainActor in
                    self?.handleGlobalStateChanged(state)
                }
            },
            onRegistrationStateChanged: { [weak self] (lc: Core, cfg: ProxyConfig, state: LPRegistrationState, message: String) in
                Task { @MainActor in
                    self?.handleRegistrationStateChanged(state, proxyConfig: cfg, message: message)
                }
            },
            onCallStateChanged: { [weak self] (lc: Core, lpCall: LPCall, state: LPCallState, message: String) in
                Task { @MainActor in
                    self?.handleCallStateChanged(lpCall, state: state)
                }
            }
        )
        
        if let delegate = coreDelegate {
            core.addDelegate(delegate: delegate)
        }
        
        // Start the Core
        try core.start()
        
        // Start iterate task (required for liblinphone)
        startIterateTask()
        
        // Start network monitoring
        startNetworkMonitoring()
        
        isInitialized = true
        Log.sip.success("SIP stack initialized successfully")
    }
    
    func shutdown() {
        Log.sip.call("Shutting down SIP stack")

        // Remove logging delegate BEFORE stopping core to avoid retain-cycle crash.
        // Keep loggingServiceRef alive — dropping it triggers the dealloc crash.
        if let delegate = loggingDelegate, let svc = loggingServiceRef {
            svc.removeDelegate(delegate: delegate)
            loggingDelegate = nil
        }

        // Send UNREGISTER before stopping (REGISTER with Expires: 0)
        disableRegistrationOnAllAccounts()
        // Give liblinphone a few iterations to build and send the UNREGISTER.
        // Critical for background shutdown where the app may suspend shortly after.
        for _ in 0..<3 {
            core?.iterate()
        }

        stopNetworkMonitoring()
        registrationRetryTask?.cancel()
        registrationRetryTask = nil

        // stopAsync requires GlobalState.On — skip if already off or shutting down
        guard core?.globalState == .On else {
            finishShutdown()
            return
        }

        // Use stopAsync to avoid blocking the main thread with synchronous I/O.
        // The iterate loop keeps running so the core can finish async tasks;
        // cleanup happens in handleGlobalStateChanged(.Off).
        core?.stopAsync()
    }

    /// Called by onGlobalStateChanged when the core reaches Off after stopAsync()
    private func finishShutdown() {
        iterateTask?.cancel()
        iterateTask = nil

        core = nil

        // Clear call state (Released callback won't fire after core shutdown)
        calls.removeAll()
        activeCalls.removeAll()
        sipCallIdToUUID.removeAll()
        currentCall = nil

        registrationState = .cleared
        isInitialized = false

        // Resume anyone waiting on shutdownAsync()
        shutdownContinuation?.resume()
        shutdownContinuation = nil

        Log.sip.call("SIP stack shutdown complete")
    }

    /// Async version of shutdown — waits for the core to reach GlobalState.Off
    func shutdownAsync() async {
        guard isInitialized else { return }
        await withCheckedContinuation { continuation in
            shutdownContinuation = continuation
            shutdown()
        }
    }

    private func handleGlobalStateChanged(_ state: GlobalState) {
        Log.sip.call("Global state changed: \(state.rawValue)")
        if state == .Off {
            finishShutdown()
        }
    }
    
    // MARK: - Registration
    
    func register(username: String, password: String, domain: String) throws {
        guard isInitialized, let core = core else {
            throw SIPError.notInitialized
        }

        Log.sip.call("Registering \(username)@\(domain)")

        // Clear existing accounts and auth info before adding new ones
        // This prevents accumulating multiple registrations
        core.clearAccounts()
        core.clearAllAuthInfo()
        
        // Create auth info
        let authInfo = try Factory.Instance.createAuthInfo(
            username: username,
            userid: nil,
            passwd: password,
            ha1: nil,
            realm: nil,
            domain: domain
        )
        core.addAuthInfo(info: authInfo)
        
        // Create account params (replaces ProxyConfig)
        let accountParams = try core.createAccountParams()
        
        // Set identity address
        let identity = try Factory.Instance.createAddress(addr: "sip:\(username)@\(domain)")
        try accountParams.setIdentityaddress(newValue: identity)
        
        // Set server address (proxy) using TLS transport
        let serverAddress = try Factory.Instance.createAddress(addr: "sip:\(domain);transport=tls")
        try accountParams.setServeraddress(newValue: serverAddress)
        
        // Set outbound proxy route - ensures all calls route through our proxy
        // Use setRoutesaddresses method instead of direct assignment
        let routesAddress = try Factory.Instance.createAddress(addr: "sip:\(domain);transport=tls")
        try accountParams.setRoutesaddresses(newValue: [routesAddress])
        
        // Configure registration with expiry
        accountParams.registerEnabled = true
        accountParams.expires = Int(Constants.SIP.registrationExpiry)

        // Create account with params and add to core
        let account = try core.createAccount(params: accountParams)

        // Add custom header with VoIP push token to REGISTER requests
        // voipTokenString may be nil after push wake-up (token callback is async),
        // so fall back to the persisted token in UserDefaults.
        #if os(iOS)
        if let voipToken = AppEnvironment.shared.pushKitManager.voipTokenString
            ?? UserDefaults.standard.string(forKey: "lastVoipToken") {
            account.setCustomHeader(headerName: "X-APP", headerValue: voipToken)
        }
        #endif

        try core.addAccount(account: account)
        core.defaultAccount = account
        
        registrationState = .progress
        onRegistrationStateChanged?(.progress)
    }
    
    func unregister() {
        Log.sip.call("Unregistering")

        guard core != nil else {
            registrationState = .cleared
            onRegistrationStateChanged?(.cleared)
            return
        }

        disableRegistrationOnAllAccounts()

        // Give a moment for unregister to be sent, then clear
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, let core = self.core else { return }
            core.clearAccounts()
            core.clearAllAuthInfo()
            self.sipCallIdToUUID.removeAll()

            self.registrationState = .cleared
            self.onRegistrationStateChanged?(.cleared)
            Log.sip.success("Unregistered successfully")
        }
    }

    /// Send SIP UNREGISTER and wait for completion.
    /// Unlike `unregister()`, does not clear accounts afterwards — caller is
    /// expected to call `register()` next, which handles cleanup itself.
    func unregisterAndWait() async {
        Log.sip.call("Unregistering (wait)")

        guard core != nil else { return }

        disableRegistrationOnAllAccounts()

        // Wait for the SIP response (max 2s) — no lock during polling
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let state = registrationState
            if state == .cleared || state == .none {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        if registrationState != .cleared && registrationState != .none {
            Log.sip.warning("unregisterAndWait: deadline expired without reaching cleared state (current: \(registrationState.rawValue))")
        } else {
            Log.sip.success("Unregistered (wait) completed")
        }
    }
    
    // MARK: - Calls
    
    func makeCall(to address: String, uuid: UUID? = nil) throws -> VoIPCall {
        guard isInitialized, let core = core else {
            throw SIPError.notInitialized
        }

        guard registrationState == .registered else {
            throw SIPError.notRegistered
        }

        // Sanitize and validate address
        let sanitizedAddress = sanitizeSIPAddress(address)
        guard !sanitizedAddress.isEmpty else {
            throw SIPError.invalidAddress
        }
        
        Log.sip.call("Making call to: \(sanitizedAddress)")
        
        // Format SIP address
        let sipAddress: String
        if sanitizedAddress.contains("@") {
            sipAddress = sanitizedAddress.hasPrefix("sip:") ? sanitizedAddress : "sip:\(sanitizedAddress)"
        } else {
            sipAddress = "sip:\(sanitizedAddress)@\(Constants.SIP.effectiveDomain)"
        }
        
        // Create call params
        let callParams = try core.createCallParams(call: nil)
        callParams.audioEnabled = true
        callParams.videoEnabled = false
        
        // Make the call
        let addressObj = try Factory.Instance.createAddress(addr: sipAddress)
        guard let linphoneCall = core.inviteAddressWithParams(addr: addressObj, params: callParams) else {
            throw SIPError.callFailed
        }
        
        // Create our VoIPCall model - use provided UUID or generate new one
        let callUUID = uuid ?? UUID()
        let call = VoIPCall(
            uuid: callUUID,
            remoteAddress: address,
            direction: .outgoing,
            state: .outgoingInit
        )
        
        // Store mapping
        calls[callUUID] = LinphoneCallWrapper(linphoneCall)
        activeCalls[callUUID] = call

        currentCall = call
        onCallStateChanged?(call)
        
        return call
    }
    
    func answer(call: VoIPCall) throws {
        Log.sip.call("Answering call: \(call.uuid)")

        guard let wrapper = calls[call.uuid] else {
            throw SIPError.callNotFound
        }

        try wrapper.lpCall.accept()
    }

    func hangup(call: VoIPCall) throws {
        Log.sip.call("Hanging up call: \(call.uuid)")

        guard let wrapper = calls[call.uuid] else {
            throw SIPError.callNotFound
        }

        try wrapper.lpCall.terminate()
    }

    func setMute(_ muted: Bool, for call: VoIPCall) {
        Log.sip.call("Setting mute \(muted) for call: \(call.uuid)")

        core?.micEnabled = !muted
        
        if var updatedCall = currentCall, updatedCall.uuid == call.uuid {
            updatedCall.isMuted = muted
            currentCall = updatedCall
            onCallStateChanged?(updatedCall)
        }
    }
    
    func setHold(_ held: Bool, for call: VoIPCall) throws {
        Log.sip.call("Setting hold \(held) for call: \(call.uuid)")

        guard let wrapper = calls[call.uuid] else {
            throw SIPError.callNotFound
        }

        if held {
            try wrapper.lpCall.pause()
        } else {
            try wrapper.lpCall.resume()
        }
    }
    
    func sendDTMF(_ digit: Character, for call: VoIPCall) {
        // Rate limiting - prevent DTMF spam
        if let lastTime = lastDTMFTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < dtmfMinInterval {
                Log.sip.call("DTMF rate limited, ignoring \(digit)")
                return
            }
        }
        lastDTMFTime = Date()
        
        Log.sip.call("Sending DTMF \(digit) for call: \(call.uuid)")
        
        guard let wrapper = calls[call.uuid] else { return }
        
        // Validate DTMF digit (0-9, *, #, A-D)
        guard let scalar = digit.unicodeScalars.first, Self.validDTMFChars.contains(scalar) else {
            Log.sip.failure("Invalid DTMF digit: \(digit)")
            return
        }
        
        guard let asciiValue = digit.asciiValue else {
            Log.sip.failure("No ASCII value for DTMF digit: \(digit)")
            return
        }
        do {
            try wrapper.lpCall.sendDtmf(dtmf: CChar(bitPattern: asciiValue))
        } catch {
            Log.sip.failure("Failed to send DTMF", error: error)
        }
    }
    
    func transfer(call: VoIPCall, to address: String) throws {
        Log.sip.call("Transferring call \(call.uuid) to \(address)")
        
        guard let wrapper = calls[call.uuid] else {
            throw SIPError.callNotFound
        }
        
        let sipAddress = "sip:\(address)@\(Constants.SIP.effectiveDomain)"
        let referToAddress = try Factory.Instance.createAddress(addr: sipAddress)
        try wrapper.lpCall.transferTo(referTo: referToAddress)
    }
    
    // MARK: - CallKit Audio Session

    /// Notify linphone that CallKit has activated or deactivated the audio session.
    /// Must be called from CXProvider's didActivate/didDeactivate callbacks.
    func activateAudioSession(_ activated: Bool) {
        #if os(iOS)
        guard let cCore = core?.getCobject else {
            Log.sip.failure("Cannot \(activated ? "activate" : "deactivate") linphone audio session: core not available")
            return
        }
        linphone_core_activate_audio_session(cCore, activated ? 1 : 0)
        Log.sip.call("Linphone audio session \(activated ? "activated" : "deactivated")")
        #endif
    }

    /// Tell linphone to configure its audio session for a call.
    /// Must be called when answering or starting a call.
    func configureAudioSession() {
        #if os(iOS)
        guard let cCore = core?.getCobject else {
            Log.sip.failure("Cannot configure linphone audio session: core not available")
            return
        }
        linphone_core_configure_audio_session(cCore)
        Log.sip.call("Linphone audio session configured")
        #endif
    }

    // MARK: - Wake Up (for PushKit)
    
    func wakeUp() {
        Log.sip.call("Waking up SIP stack")
        core?.refreshRegisters()
    }

    // MARK: - Pending Call UUID (for CallKit sync)
    
    /// Set pending incoming call from PushKit/CallKit (UUID + SIP callId for matching)
    func setPendingIncomingCall(uuid: UUID, callId: String?) {
        Log.sip.call("Setting pending incoming call UUID: \(uuid), callId: \(callId ?? "nil")")
        pendingIncomingCallUUID = uuid
        pendingIncomingCallId = callId
        pendingIncomingCallTimestamp = Date()
    }

    /// Clear pending incoming call info
    func clearPendingIncomingCall() {
        pendingIncomingCallUUID = nil
        pendingIncomingCallId = nil
        pendingIncomingCallTimestamp = nil
    }

    /// Look up an existing call UUID by SIP Call-ID (used by PushKit for reconciliation)
    func existingUUID(forCallId callId: String?) -> UUID? {
        guard let callId else { return nil }
        return sipCallIdToUUID[callId]
    }

    /// Check if there's an active call
    var hasActiveCall: Bool {
        guard let state = currentCall?.state else { return false }
        return state != .ended && state != .error
    }
    
    // MARK: - Private Methods
    
    private func startIterateTask() {
        // liblinphone requires periodic iteration on the SAME thread as all other
        // Core access.  Running on MainActor guarantees single-threaded access —
        // no locks, no data races.  Task.sleep yields between iterations so UI
        // events, gestures, and other MainActor work process normally.
        //
        // Polling frequency:
        // - 20ms (~50Hz) during active call for responsiveness
        // - 100ms when idle in foreground for battery savings
        // - No polling in background (push handles incoming calls)
        iterateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let shouldIterate = self.isInForeground || self.hasActiveCall

                if shouldIterate {
                    self.core?.iterate()
                }

                let interval: Duration = self.hasActiveCall ? .milliseconds(20)
                    : shouldIterate ? .milliseconds(100) : .seconds(60)
                try? await Task.sleep(for: interval)
            }
        }
    }
    
    // MARK: - Foreground/Background Control
    
    /// Call when app enters foreground
    func enterForeground() {
        guard isInitialized else {
            Log.sip.call("SIP enterForeground called but core is not initialized, skipping")
            return
        }
        Log.sip.call("SIP entering foreground - resuming polling")
        isInForeground = true
    }

    /// Call when app enters background
    func enterBackground() {
        Log.sip.call("SIP entering background - reducing polling")
        isInForeground = false
    }
    
    // MARK: - Network Monitoring
    
    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleNetworkChange(path)
            }
        }
        networkMonitor?.start(queue: DispatchQueue.global(qos: .utility))
        Log.sip.call("Network monitoring started")
    }
    
    private func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
    }
    
    private func handleNetworkChange(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = (path.status == .satisfied)
        
        // Only act on actual changes
        guard lastNetworkStatus != path.status else { return }
        lastNetworkStatus = path.status
        
        Log.sip.call("Network status changed: \(path.status) (available: \(isNetworkAvailable))")
        
        if isNetworkAvailable && !wasAvailable {
            // Network became available - refresh registration
            Log.sip.call("Network restored - refreshing SIP registration")
            core?.refreshRegisters()
        } else if !isNetworkAvailable && wasAvailable {
            // Network lost - update state but don't try to unregister
            Log.sip.call("Network lost - SIP may become unavailable")
        }
        
        // Log interface type for debugging
        if path.usesInterfaceType(.wifi) {
            Log.sip.call("Using WiFi interface")
        } else if path.usesInterfaceType(.cellular) {
            Log.sip.call("Using Cellular interface")
        }
    }
    
    /// Disable registration on all accounts (triggers SIP UNREGISTER with Expires: 0)
    private func disableRegistrationOnAllAccounts() {
        guard let core else { return }
        for account in core.accountList {
            if let params = account.params?.clone() {
                params.registerEnabled = false
                account.params = params
            }
        }
    }

    // MARK: - Input Sanitization
    
    /// Sanitize SIP address to prevent injection attacks
    private func sanitizeSIPAddress(_ address: String) -> String {
        var sanitized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove any control characters
        sanitized = sanitized.components(separatedBy: CharacterSet.controlCharacters).joined()
        
        // Remove potentially dangerous characters for SIP URIs
        sanitized = sanitized.components(separatedBy: Self.dangerousSIPChars).joined()
        
        // Limit length to prevent buffer issues
        if sanitized.count > 256 {
            sanitized = String(sanitized.prefix(256))
        }
        
        return sanitized
    }
    
    // MARK: - Registration Retry Logic
    
    /// Schedule a retry for failed registration
    private func scheduleRegistrationRetry() {
        guard registrationRetryCount < maxRegistrationRetries else {
            Log.sip.failure("Max registration retries (\(maxRegistrationRetries)) reached")
            registrationRetryCount = 0
            return
        }
        
        registrationRetryCount += 1
        let delay = Double(registrationRetryCount) * 2.0 // Linear backoff: 2s, 4s, 6s
        
        Log.sip.call("Scheduling registration retry \(registrationRetryCount)/\(maxRegistrationRetries) in \(delay)s")
        
        registrationRetryTask?.cancel()
        registrationRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self?.retryRegistration()
            }
        }
    }
    
    /// Retry registration with stored credentials
    private func retryRegistration() {
        guard let core = core, isInitialized else { return }

        // Check if we have a default account to retry
        if let account = core.defaultAccount {
            Log.sip.call("Retrying registration...")
            // Clone params, enable registration, and apply back
            if let params = account.params?.clone() {
                params.registerEnabled = true
                account.params = params
            }
            core.refreshRegisters()
        }
    }
    
    /// Reset retry counter on successful registration
    private func resetRegistrationRetry() {
        registrationRetryCount = 0
        registrationRetryTask?.cancel()
        registrationRetryTask = nil
    }
    
    // MARK: - Audio/Tone Configuration
    
    private func configureRingbackTone(core: Core) {
        // Build candidate paths: main bundle, linphone framework bundles, direct framework path
        var candidates: [String] = []

        if let path = Bundle.main.path(forResource: "ringback", ofType: "wav") {
            candidates.append(path)
        }

        for bundle in Bundle.allFrameworks where bundle.bundleIdentifier?.contains("linphone") == true || bundle.bundlePath.contains("linphone") {
            if let path = bundle.path(forResource: "ringback", ofType: "wav") {
                candidates.append(path)
            }
        }

        if let frameworkPath = Bundle.allFrameworks.first(where: { $0.bundlePath.contains("linphone.framework") })?.bundlePath {
            candidates.append((frameworkPath as NSString).appendingPathComponent("ringback.wav"))
        }

        if let ringbackPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            core.ringback = ringbackPath
            Log.sip.success("Ringback tone configured: \(ringbackPath)")
        } else {
            Log.sip.call("Ringback tone file not found - remote ringback will be used if available")
        }
    }
    
    // MARK: - NAT/STUN Configuration
    
    private func configureNATPolicy(core: Core) {
        let stunEnabled = UserDefaults.standard.bool(forKey: Constants.UserDefaultsKeys.stunEnabled)
        
        guard stunEnabled else {
            Log.sip.call("STUN disabled by user preference")
            return
        }
        
        do {
            let natPolicy = try core.createNatPolicy()
            natPolicy.stunServer = Constants.NAT.stunServerURL
            natPolicy.stunEnabled = true
            natPolicy.iceEnabled = true  // ICE uses STUN for NAT traversal
            natPolicy.turnEnabled = false  // TURN not configured
            
            // Apply to core
            core.natPolicy = natPolicy
            
            Log.sip.success("STUN configured: \(Constants.NAT.stunServerURL)")
        } catch {
            Log.sip.failure("Failed to configure NAT policy", error: error)
        }
    }
    
    /// Update STUN configuration at runtime
    func updateSTUNEnabled(_ enabled: Bool) {
        guard let core = core else { return }

        if enabled {
            configureNATPolicy(core: core)
        } else {
            // Disable STUN
            if let natPolicy = core.natPolicy {
                natPolicy.stunEnabled = false
                natPolicy.iceEnabled = false
            }
            Log.sip.call("STUN disabled")
        }
    }

    /// Update media encryption (SRTP) at runtime
    func updateMediaEncryption(_ enabled: Bool) {
        guard let core = core else { return }
        do {
            try core.setMediaencryption(newValue: enabled ? .SRTP : .None)
            Log.sip.call("Media encryption updated: \(enabled ? "SRTP" : "none")")
        } catch {
            Log.sip.failure("Failed to update media encryption", error: error)
        }
    }

    private func handleRegistrationStateChanged(_ state: LPRegistrationState, proxyConfig: ProxyConfig, message: String) {
        let newState: SIPRegistrationState
        switch state {
        case .None:
            newState = .none
            lastRegistrationError = nil
            resetRegistrationRetry()
        case .Progress:
            newState = .progress
            lastRegistrationError = nil
        case .Ok:
            newState = .registered
            lastRegistrationError = nil
            resetRegistrationRetry()
        case .Failed:
            newState = .failed
            // Capture the SIP error code and reason from the message
            // liblinphone passes the SIP response in the message (e.g., "Unauthorized", "Not Found")
            // We can also get more details from the account's error info
            var errorCode = 0
            var errorReason = message.isEmpty ? "Connection failed" : message
            
            // Try to extract SIP response code from errorInfo via Account API
            if let account = core?.defaultAccount, let errorInfo = account.errorInfo {
                let sipCode = errorInfo.protocolCode
                if sipCode > 0 {
                    errorCode = Int(sipCode)
                }
                // Get the reason phrase if available
                if let phrase = errorInfo.phrase, !phrase.isEmpty {
                    errorReason = phrase
                }
            }
            
            lastRegistrationError = (code: errorCode, reason: errorReason)
            Log.sip.failure("Registration failed with code \(errorCode): \(errorReason)")
            
            // Schedule retry for transient errors (network issues, server unavailable)
            // Don't retry for auth errors (401, 403) as they require user action
            if errorCode == 0 || (errorCode >= 500 && errorCode < 600) || errorCode == 408 {
                scheduleRegistrationRetry()
            }
        case .Cleared:
            newState = .cleared
            lastRegistrationError = nil
        case .Refreshing:
            newState = .registered // Treat refreshing as still registered
        @unknown default:
            newState = .none
        }
        
        Log.sip.call("Registration state changed: \(newState.rawValue)")
        
        registrationState = newState
        onRegistrationStateChanged?(newState)
    }
    
    /// Create a VoIPCall from a linphone call
    private func makeVoIPCall(uuid: UUID, linphoneCall: LPCall, state: CallState = .idle) -> VoIPCall {
        let isOutgoing = linphoneCall.dir == .Outgoing
        return VoIPCall(
            uuid: uuid,
            remoteAddress: linphoneCall.remoteAddress?.asStringUriOnly() ?? "Unknown",
            displayName: linphoneCall.remoteAddress?.displayName,
            direction: isOutgoing ? .outgoing : .incoming,
            state: state
        )
    }

    /// Resolve or create a VoIPCall from a linphone call, preserving existing data when available
    private func resolveCall(for linphoneCall: LPCall) -> VoIPCall {
        // Match by callId, with fallback to object identity when callId is nil
        let incomingCallId = linphoneCall.callLog?.callId
        let existingEntry: (key: UUID, value: LinphoneCallWrapper)?
        if let incomingCallId {
            existingEntry = calls.first { $0.value.lpCall.callLog?.callId == incomingCallId }
        } else {
            // callId not yet available — match by lpCall object identity
            existingEntry = calls.first { $0.value.lpCall === linphoneCall }
        }

        if let entry = existingEntry {
            let uuid = entry.key
            // Preserve existing call data (direction, displayName, connectTime)
            if let existingCall = currentCall, existingCall.uuid == uuid {
                return existingCall
            } else if let existingCall = activeCalls[uuid] {
                return existingCall
            } else {
                return makeVoIPCall(uuid: uuid, linphoneCall: linphoneCall)
            }
        }

        // New call
        let isOutgoing = linphoneCall.dir == .Outgoing
        let sipCallId = linphoneCall.callLog?.callId

        let uuid: UUID
        if !isOutgoing, let pendingUUID = pendingIncomingCallUUID {
            let isExpired = pendingIncomingCallTimestamp.map { Date().timeIntervalSince($0) > pendingCallTTL } ?? true
            let age = pendingIncomingCallTimestamp.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "?"
            Log.sip.call("resolveCall: incoming call — pending UUID=\(pendingUUID), pendingCallId=\(pendingIncomingCallId ?? "nil"), sipCallId=\(sipCallId ?? "nil"), age=\(age)")

            if isExpired {
                // TTL expired — discard stale pending and create fresh UUID
                Log.sip.warning("Pending CallKit UUID expired (>\(Int(pendingCallTTL))s) — creating new UUID")
                clearPendingIncomingCall()
                uuid = UUID()
            } else if let pendingId = pendingIncomingCallId, let sipId = sipCallId, pendingId != sipId {
                // callId mismatch — do NOT consume pending UUID, create a new one
                Log.sip.failure("CallId mismatch (push=\(pendingId), sip=\(sipId)) — creating new UUID, keeping pending")
                uuid = UUID()
            } else {
                // Match: callId matches, or no callId available (timing-based fallback within TTL)
                let matchMethod = (pendingIncomingCallId != nil && sipCallId != nil)
                    ? "callId match (\(sipCallId!))"
                    : "timing (no callId, within \(Int(pendingCallTTL))s TTL)"
                Log.sip.call("Using pending CallKit UUID for incoming call: \(matchMethod)")
                uuid = pendingUUID
                clearPendingIncomingCall()
            }
        } else {
            uuid = UUID()
            if !isOutgoing {
                Log.sip.call("resolveCall: incoming call but NO pending UUID — sipCallId=\(sipCallId ?? "nil"), new UUID=\(uuid)")
            }
        }

        let initialState: CallState = isOutgoing ? .outgoingInit : .incoming
        let call = makeVoIPCall(uuid: uuid, linphoneCall: linphoneCall, state: initialState)
        calls[uuid] = LinphoneCallWrapper(linphoneCall)
        activeCalls[uuid] = call

        // Register SIP Call-ID → UUID mapping for PushKit reconciliation
        if let sipCallId = linphoneCall.callLog?.callId {
            sipCallIdToUUID[sipCallId] = uuid
        }

        return call
    }

    private func handleCallStateChanged(_ linphoneCall: LPCall, state: LPCallState) {
        var call = resolveCall(for: linphoneCall)
        let uuid = call.uuid
        Log.sip.call("handleCallStateChanged: uuid=\(uuid.uuidString.prefix(8))…, lpState=\(state), sipCallId=\(linphoneCall.callLog?.callId ?? "nil")")

        // Update state based on linphone state
        switch state {
        case .Idle:
            call.state = .idle
        case .OutgoingInit:
            call.state = .outgoingInit
        case .OutgoingProgress:
            call.state = .outgoingProgress
        case .OutgoingRinging:
            call.state = .outgoingRinging
        case .IncomingReceived, .PushIncomingReceived:
            call.state = .incoming
            onIncomingCall?(call)
        case .Connected, .StreamsRunning:
            call.state = .connected
            if call.connectTime == nil {
                call.connectTime = Date()
            }
        case .Paused, .Pausing:
            call.state = .paused
            call.isOnHold = true
        case .Resuming:
            call.state = .connected
            call.isOnHold = false
        case .PausedByRemote:
            call.state = .pausedByRemote
        case .Error:
            call.state = .error
            call.endTime = Date()
        case .End:
            call.state = .ended
            if call.endTime == nil {
                call.endTime = Date()
            }
            // Don't clean up yet - wait for Released
        case .Released:
            // Released comes after End - just clean up, don't notify again
            // to avoid duplicate history entries
            if let sipCallId = linphoneCall.callLog?.callId {
                sipCallIdToUUID.removeValue(forKey: sipCallId)
            }
            calls.removeValue(forKey: uuid)
            activeCalls.removeValue(forKey: uuid)
            if currentCall?.uuid == uuid {
                currentCall = nil
            }
            // Return early - don't call onCallStateChanged again
            return
        default:
            break
        }
        
        Log.sip.call("Call \(uuid) state: \(call.state.displayText)")

        activeCalls[uuid] = call

        if call.state != .ended {
            currentCall = call
        }

        onCallStateChanged?(call)
    }
    
    // MARK: - Liblinphone Logging Bridge
    
    /// Configure liblinphone logging to bridge SIP traces to our logging system
    private func configureLinphoneLogging() {
        // Hold a strong reference to the LoggingService Swift wrapper for the
        // lifetime of SIPManager. Without this, the C callback in
        // LoggingServiceDelegateManager calls getSwiftObject(cObject:) which
        // creates a *new* temporary Swift wrapper on every log line. These
        // temporary wrappers crash on dealloc with "non-zero retain count"
        // because the C callback still holds a reference.
        let loggingService = LoggingService.Instance
        loggingServiceRef = loggingService

        // Set log level based on debug mode
        updateLinphoneLogLevel()

        // Remove previous delegate if re-initializing to avoid duplicate callbacks
        if let existing = loggingDelegate {
            loggingService.removeDelegate(delegate: existing)
            loggingDelegate = nil
        }

        // Create delegate to receive log messages
        // The closure signature must match LoggingServiceDelegate.onLogMessageWritten
        loggingDelegate = LoggingServiceDelegateStub(
            onLogMessageWritten: { [weak self] (service, domain, level, message) in
                self?.handleLinphoneLog(domain: domain, levelRawValue: level.rawValue, message: message)
            }
        )

        if let delegate = loggingDelegate {
            loggingService.addDelegate(delegate: delegate)
        }

        Log.sip.call("Liblinphone logging bridge configured")
    }

    /// Update liblinphone log level based on debug mode state
    nonisolated private func updateLinphoneLogLevel() {
        guard let loggingService = loggingServiceRef else { return }

        if LogFileManager.shared.isDebugMode {
            loggingService.logLevelMask = Self.traceLogMask
            Log.sip.call("Liblinphone log level set to TRACE (debug mode)")
        } else {
            loggingService.logLevelMask = Self.errorLogMask
            Log.sip.call("Liblinphone log level set to ERROR (normal mode)")
        }
    }
    
    /// Handle log messages from liblinphone and forward to our logging system
    /// Using rawValue to avoid type conflicts between linphonesw.LogLevel and our LogLevel
    nonisolated private func handleLinphoneLog(domain: String, levelRawValue: Int, message: String) {
        // linphonesw.LogLevel bitmask: Debug=1, Trace=2, Message=4, Warning=8, Error=16, Fatal=32
        let ourLevel: LogLevel
        let logCategory = "SIP/\(domain)"
        
        // Check flags using bitmask operations
        if (levelRawValue & 32) != 0 || (levelRawValue & 16) != 0 {
            // Fatal or Error
            ourLevel = .error
        } else if (levelRawValue & 8) != 0 {
            // Warning
            ourLevel = .warning
        } else if (levelRawValue & 4) != 0 {
            // Message
            ourLevel = .notice
        } else if (levelRawValue & 2) != 0 {
            // Trace
            ourLevel = .info
        } else {
            // Debug or unknown
            ourLevel = .debug
        }
        
        // Write to our log file (respects debug mode filtering)
        LogFileManager.shared.write(message, category: logCategory, level: ourLevel)
    }
    
    /// Setup observer for debug mode changes
    private func setupDebugModeObserver() {
        debugModeObserver = NotificationCenter.default.addObserver(
            forName: .debugLoggingModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }
            Log.sip.call("Debug mode changed: \(enabled)")
            self?.updateLinphoneLogLevel()
        }
    }
    
    deinit {
        if let observer = debugModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - SIP Errors

enum SIPError: LocalizedError {
    case notInitialized
    case notRegistered
    case registrationFailed
    case invalidAddress
    case callFailed
    case callNotFound
    case transferFailed

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "SIP stack not initialized"
        case .notRegistered: return "Not registered to SIP server"
        case .registrationFailed: return String(localized: "login.error.registration")
        case .invalidAddress: return "Invalid SIP address"
        case .callFailed: return "Failed to initiate call"
        case .callNotFound: return "Call not found"
        case .transferFailed: return "Failed to transfer call"
        }
    }
}
