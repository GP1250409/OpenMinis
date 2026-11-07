import UIKit

// The regression app: a UIApplication (not a bare CLI binary) so UIKit's
// display link is live and `setContentOffset(animated:)` really animates.
final class ScrollBottomAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let host = UIViewController()
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        // Let the first commit run so the display link is live before measuring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            ScrollBottomRunner().run()
        }
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                  NSStringFromClass(ScrollBottomAppDelegate.self))
