//
//  ippi_SoftphoneApp.swift
//  ippi Softphone
//
//  Created by Guillaume Lacroix on 16/02/2026.
//

import SwiftUI
import SwiftData
import UserNotifications
#if os(iOS)
import UIKit
import FirebaseCore
#endif

// MARK: - App Delegate for APNs Token

#if os(iOS)
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            AppEnvironment.shared.pushKitManager.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            AppEnvironment.shared.pushKitManager.didFailToRegisterForRemoteNotifications(error: error)
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // FirebaseApp.configure() is called in ippi_SoftphoneApp.init() (before AppEnvironment)
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when user taps on a notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // If the notification has a "from" field, it's a missed call
        if let sipFrom = userInfo["from"] as? String {
            Task { @MainActor in
                let env = AppEnvironment.shared
                // Tapping removes the notification from delivered list,
                // so processMissedCallNotifications() won't see it — save it here
                _ = await env.callHistoryService.addMissedCallFromNotification(
                    remoteAddress: sipFrom,
                    date: response.notification.date
                )
                env.pendingNavigation = .history
                completionHandler()
            }
        } else {
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            AppEnvironment.shared.syncBadgeFromSharedStorage()
        }
        completionHandler([.banner, .sound, .badge])
    }
}
#endif

@main
struct ippi_SoftphoneApp: App {
    // MARK: - Properties
    
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    private let environment = AppEnvironment.shared
    
    // SwiftData container
    private let modelContainer: ModelContainer
    
    #if os(iOS)
    // Scene phase for detecting app lifecycle
    @Environment(\.scenePhase) private var scenePhase
    #endif
    
    // Track if app has finished initial launch to avoid spurious scenePhase events
    @State private var hasCompletedInitialLaunch = false
    
    // MARK: - Initialization
    
    init() {
        // FirebaseApp.configure() is called in AppEnvironment.init()
        // before CrashReportingService initialization

        // Configure SwiftData with file protection
        let schema = Schema([
            CallHistoryEntry.self,
            StoredAccount.self
        ])
        
        // Use custom store URL with complete file protection for sensitive call history data
        let storeURL = URL.applicationSupportDirectory
            .appending(path: "ippi_softphone.sqlite")
        
        let modelConfiguration = ModelConfiguration(
            "CallHistory",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        
        modelContainer = Self.createModelContainer(schema: schema, configuration: modelConfiguration)
        
        // Apply file protection to the database file
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: storeURL.path()
        )
        #endif
        
        // Inject model context into call history service
        let context = modelContainer.mainContext
        environment.callHistoryService.setModelContext(context)
        
        Log.general.success("App initialized with SwiftData")

        // Migrate keychain accessibility for existing users (one-time)
        KeychainService.shared.migrateAccessibilityIfNeeded()

        // Mark initial launch as complete after a delay
        // This prevents scenePhase changes during launch from interfering
        // Session restore is handled by ContentView's .task modifier

        // Register for push notifications on iOS
        #if os(iOS)
        let pushEnabled = UserDefaults.standard.bool(forKey: "pushNotificationsEnabled")
        if pushEnabled {
            AppEnvironment.shared.pushKitManager.registerForVoIPPushes()
            // Also register for APNs to get standard notification token
            Task { @MainActor in
                _ = await AppEnvironment.shared.pushKitManager.registerForAPNs()
            }
        }
        #endif
        
        // Register for app termination notification
        let terminationNotification: Notification.Name
        #if os(macOS)
        terminationNotification = NSApplication.willTerminateNotification
        #else
        terminationNotification = UIApplication.willTerminateNotification
        #endif

        NotificationCenter.default.addObserver(
            forName: terminationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.handleAppTermination()
            }
        }
    }
    
    // MARK: - Body
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appEnvironment, environment)
                .modelContainer(modelContainer)
                #if os(iOS)
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    handleScenePhaseChange(from: oldPhase, to: newPhase)
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(600))
                    hasCompletedInitialLaunch = true
                    Log.general.call("Initial launch completed - scenePhase handling now active")
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        #endif
    }
    
    // MARK: - Static Helpers

    private static func createModelContainer(schema: Schema, configuration: ModelConfiguration) -> ModelContainer {
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return container
        }
        Log.general.failure("Failed to create persistent ModelContainer, using in-memory fallback")
        let fallbackConfig = ModelConfiguration("CallHistoryFallback", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [fallbackConfig]) {
            Log.general.call("Using in-memory SwiftData store - call history will not persist")
            return container
        }
        Log.general.failure("Failed to create in-memory ModelContainer, using default")
        // Last resort: fatal if even this fails
        guard let container = try? ModelContainer(for: schema) else {
            fatalError("Failed to create any ModelContainer")
        }
        return container
    }

    @MainActor
    private static func handleAppTermination() {
        if let activeCall = AppEnvironment.shared.activeCall {
            try? AppEnvironment.shared.sipManager.hangup(call: activeCall)
        }
        AppEnvironment.shared.sipManager.shutdown()
    }

    // MARK: - Lifecycle Handling
    
    #if os(iOS)
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        Log.general.call("scenePhase changed: \(oldPhase) -> \(newPhase), hasCompletedInitialLaunch=\(hasCompletedInitialLaunch)")
        
        // Ignore scenePhase changes during initial app launch
        // This prevents the app from unregistering immediately after restoreSession() registers
        guard hasCompletedInitialLaunch else {
            Log.general.call("Ignoring scenePhase change during initial launch")
            return
        }
        
        switch newPhase {
        case .background:
            // App is going to background
            if environment.sipManager.hasActiveCall {
                // Keep SIP active during call (polling at 20ms for responsiveness)
                environment.sipManager.enterBackground()
                Log.general.call("App entering background - keeping SIP active (call in progress)")
            } else {
                // No active call - shut down SIP stack entirely
                // Push will handle incoming calls, no need for polling
                Log.general.call("App entering background - shutting down SIP (push will handle incoming)")
                environment.sipManager.shutdown()
            }
            
        case .active:
            environment.sipManager.enterForeground()

            Task {
                await environment.processPendingNotifications()
            }

            // Check if debug logging mode has expired
            if LogFileManager.shared.checkDebugModeExpiry() {
                Log.general.call("Debug logging mode expired")
            }

            // App is becoming active - re-register if we have an account
            Log.general.call("App becoming active")
            if environment.sipManager.hasActiveCall {
                // Don't re-register during an active call - it would clear accounts/auth
                Log.general.call("Active call in progress - skipping re-register")
            } else if environment.isLoggedIn {
                Task { await environment.restoreSession() }
            }
            
        case .inactive:
            // Transitional state, don't do anything
            break
            
        @unknown default:
            break
        }
    }
    #endif
}
