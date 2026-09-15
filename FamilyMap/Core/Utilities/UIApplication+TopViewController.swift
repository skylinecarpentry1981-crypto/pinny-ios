import UIKit

extension UIApplication {
    /// The view controller to present the Google sign-in sheet from: the key window's root, then down
    /// the chain of presented controllers (so it also works from a sheet, e.g. delete account).
    var topViewController: UIViewController? {
        let windows = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
