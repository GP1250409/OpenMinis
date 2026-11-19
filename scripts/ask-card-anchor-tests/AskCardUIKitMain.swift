// [T-ask-fixture-build] App-lifecycle host for the answered-question card UIKit
// fixture. This replaces the generated `main.swift` that only did
// `import UIKit` + a top-level `runAskCardUIKitCases()`:
//
//   * the seven cases pump ~19s of wall clock; an app bundle that never calls
//     `UIApplicationMain` never checks in with SpringBoard, so it sits inside
//     the 20s launch watchdog (0x8badf00d) and can be killed mid-suite with no
//     PASS/FAIL marker at all;
//   * every other UIKit driver in this repo that is green on Darwin
//     (ThinkingHarness, GenUIHeightTests, ToolFoldUIKitFixture, the status-bar
//     fixture via UIApplicationMain) runs under a real app lifecycle, so this
//     is the proven shape, not a copy of any animation code.
//
// The suite itself is unchanged: `runAskCardUIKitCases()` still builds its own
// UICollectionView/UIWindow per case and terminates the process with exit(0)
// (PASS) or exit(1) (FAIL).
import UIKit

@main
final class AskCardUIKitApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        window = w
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()

        // Last-resort bound: simctl's own timeout only produces a text log, and
        // a stuck case would otherwise be reported as a missing marker. This
        // prints a real FAIL marker first so the artifact says why.
        let watchdog = Timer(timeInterval: 330, repeats: false) { _ in
            print("ASK_CARD_ANCHOR_UIKIT_FAIL watchdog 330s")
            fflush(stdout)
            exit(3)
        }
        RunLoop.main.add(watchdog, forMode: .common)

        // Start after the first turn of the run loop so the window is on screen
        // (the same 0.4s hand-off the Thinking driver uses).
        let start = Timer(timeInterval: 0.4, repeats: false) { _ in
            runAskCardUIKitCases()
        }
        RunLoop.main.add(start, forMode: .common)
        return true
    }
}
