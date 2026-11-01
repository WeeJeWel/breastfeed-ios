import CloudKit
import SwiftUI
import UIKit

@main
struct BreastFeedApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = FeedingStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TimelineView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .task { await store.restoreLiveActivity() }
                .onChange(of: store.running) { _, _ in Task { await store.syncLiveActivity() } }
                .onChange(of: store.runningEvent?.journal?.name) { _, _ in Task { await store.syncLiveActivity() } }
                .onChange(of: store.runningEvent?.sideRaw) { _, _ in Task { await store.syncLiveActivity() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.refresh()
                        Task { await store.restoreLiveActivity() }
                    }
                }
                .alert("Something needs attention", isPresented: Binding(
                    get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
                )) { Button("OK", role: .cancel) { store.errorMessage = nil } }
                message: { Text(store.errorMessage ?? "") }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShareSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in FeedingStore.shared.acceptShare(cloudKitShareMetadata) }
    }
}

final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            FeedingStore.shared.acceptShare(metadata)
        }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        FeedingStore.shared.acceptShare(cloudKitShareMetadata)
    }
}
