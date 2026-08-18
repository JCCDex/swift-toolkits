import SwiftUI

@main
struct WalletDemoApp: App {
    @StateObject private var wallet = WalletService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(self.wallet)
                .environmentObject(self.wallet.state)
        }
    }
}
