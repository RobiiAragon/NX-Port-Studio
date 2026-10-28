import Foundation
import AuthenticationServices
import UIKit

@MainActor final class MobileNextendoBrowser: NSObject, MobileNextendoBrowsing, ASWebAuthenticationPresentationContextProviding {
    weak var window: UIWindow?
    private var session: ASWebAuthenticationSession?
    private var presentationWindow: UIWindow?

    func open(_ request: NextendoSignInRequest, receiver: MobileNextendoCallback) -> Bool {
        guard let window, window.windowScene != nil else { return false }
        cancel()
        presentationWindow = window
        let value = ASWebAuthenticationSession(url: request.authorizationURL, callback: .customScheme("nxnative-nextendo")) { url, error in
            let result: Result<URL, NextendoError>
            if let url, error == nil { result = .success(url) }
            else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { result = .failure(.authorizationDenied) }
            else { result = .failure(.requestFailed) }
            Task { await receiver.deliver(result) }
        }
        value.presentationContextProvider = self
        value.prefersEphemeralWebBrowserSession = false
        session = value
        if !value.start() { cancel(); return false }
        return true
    }
    func cancel() { session?.cancel(); session = nil; presentationWindow = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The attached SwiftUI view supplies its own actual window.
        guard let anchor = presentationWindow ?? window else {
            preconditionFailure("Authentication requires its attached presentation window.")
        }
        return anchor
    }
}
