import SwiftUI
import UIKit

/// Hosts a session's view controller inside the full screen cover. Menu is left to the player so the
/// native info panel and transport bar behave as they would in a plain AVPlayerViewController.
struct PlayerHost: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> PlayerContainer { PlayerContainer() }

    func updateUIViewController(_ container: PlayerContainer, context: Context) { container.show(controller) }
}

final class PlayerContainer: UIViewController {
    private var child: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Letterbox bars must be black, never the screen behind the cover.
        view.backgroundColor = .black
    }

    func show(_ next: UIViewController) {
        guard next !== child else { return }
        if let child {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        child = next
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        child.map { [$0] } ?? []
    }
}
