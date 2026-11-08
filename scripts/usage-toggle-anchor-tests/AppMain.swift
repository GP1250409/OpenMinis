import Foundation
import UIKit

@main
final class UsageToggleAnchorApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        // Start from a run-loop timer (not a dispatch block) so the window and
        // the layout are already attached when the fixture builds its list.
        let start = Timer(timeInterval: 0.5, repeats: false) { _ in
            let suite = UsageToggleAnchorTests()
            suite.run()
            print("USAGE_TOGGLE_ANCHOR_UIKIT_CHECKS \(CheckLog.passed)")
            if CheckLog.failed > 0 {
                print("USAGE_TOGGLE_ANCHOR_UIKIT_FAIL \(CheckLog.failed)")
                fflush(stdout)
                exit(2)
            }
            print("USAGE_TOGGLE_ANCHOR_UIKIT_PASS checks=\(CheckLog.passed)")
            fflush(stdout)
            exit(0)
        }
        RunLoop.main.add(start, forMode: .common)
        return true
    }
}
