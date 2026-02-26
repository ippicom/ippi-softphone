//
//  CrashReportingService.swift
//  ippi Softphone
//
//  Created by ippi on 21/02/2026.
//

#if os(iOS)
import Foundation
import FirebaseCrashlytics
import Network

@MainActor
final class CrashReportingService {
    static let shared = CrashReportingService()

    private let crashlytics = Crashlytics.crashlytics()
    private var networkMonitor: NWPathMonitor?

    private init() {
        startNetworkMonitoring()
    }

    // MARK: - Context Updates

    func updateSIPState(_ state: SIPRegistrationState) {
        crashlytics.setCustomValue(state.rawValue, forKey: "sip_state")
    }

    func updateCallState(_ call: VoIPCall?) {
        if let call {
            crashlytics.setCustomValue(call.state.rawValue, forKey: "call_state")
            crashlytics.setCustomValue(call.direction.rawValue, forKey: "call_direction")
        } else {
            crashlytics.setCustomValue("idle", forKey: "call_state")
            crashlytics.setCustomValue("none", forKey: "call_direction")
        }
    }

    func updateCallCount(_ count: Int) {
        crashlytics.setCustomValue(count, forKey: "call_count")
    }

    func updateAudioRoute(_ route: AudioRoute) {
        crashlytics.setCustomValue(route.rawValue, forKey: "audio_route")
    }

    func updateDebugMode(_ enabled: Bool) {
        crashlytics.setCustomValue(enabled, forKey: "is_debug_mode")
    }

    func setUser(_ username: String?) {
        crashlytics.setUserID(username ?? "")
    }

    // MARK: - Non-Fatal Errors

    func recordSIPError(_ error: Error, context: String) {
        crashlytics.setCustomValue(context, forKey: "sip_error_context")
        crashlytics.record(error: error)
        Log.general.call("Crashlytics recorded SIP error: \(context)")
    }

    func recordCallError(_ error: Error, callUUID: UUID) {
        crashlytics.setCustomValue(callUUID.uuidString, forKey: "failed_call_uuid")
        crashlytics.record(error: error)
        Log.general.call("Crashlytics recorded call error: \(callUUID)")
    }

    func recordError(_ error: Error) {
        crashlytics.record(error: error)
    }

    // MARK: - Breadcrumbs

    func log(_ message: String) {
        crashlytics.log(message)
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            let networkType: String
            if path.usesInterfaceType(.wifi) {
                networkType = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                networkType = "cellular"
            } else if path.status == .satisfied {
                networkType = "other"
            } else {
                networkType = "none"
            }
            Task { @MainActor [weak self] in
                self?.crashlytics.setCustomValue(networkType, forKey: "network_type")
            }
        }
        networkMonitor?.start(queue: DispatchQueue.global(qos: .utility))
    }
}
#endif
