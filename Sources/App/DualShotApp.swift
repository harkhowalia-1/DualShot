import SwiftUI

@main
struct DualShotApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
