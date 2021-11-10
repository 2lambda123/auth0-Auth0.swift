#if WEB_AUTH_PLATFORM
import AuthenticationServices

final class Auth0WebAuth: WebAuth {

    let clientId: String
    let url: URL
    let storage: TransactionStore
    var telemetry: Telemetry
    var logger: Logger?
    var universalLink = false
    var ephemeralSession = false

    #if os(macOS)
    private let platform = "macos"
    #else
    private let platform = "ios"
    #endif

    private let responseType = "code"
    private let requiredScope = "openid"
    private(set) var parameters: [String: String] = [:]
    private(set) var issuer: String
    private(set) var leeway: Int = 60 * 1000 // Default leeway is 60 seconds
    private(set) var organization: String?
    private(set) var invitationURL: URL?
    private var nonce: String?
    private var maxAge: Int?

    lazy var redirectURL: URL? = {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        var components = URLComponents(url: self.url, resolvingAgainstBaseURL: true)
        components?.scheme = self.universalLink ? "https" : bundleIdentifier
        return components?.url?
            .appendingPathComponent(self.platform)
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("callback")
    }()

    init(clientId: String,
         url: URL,
         storage: TransactionStore = TransactionStore.shared,
         telemetry: Telemetry = Telemetry()) {
        self.clientId = clientId
        self.url = url
        self.storage = storage
        self.telemetry = telemetry
        self.issuer = "\(url.absoluteString)/"
    }

    func useUniversalLink() -> Self {
        self.universalLink = true
        return self
    }

    func connection(_ connection: String) -> Self {
        self.parameters["connection"] = connection
        return self
    }

    func scope(_ scope: String) -> Self {
        self.parameters["scope"] = scope
        return self
    }

    func connectionScope(_ connectionScope: String) -> Self {
        self.parameters["connection_scope"] = connectionScope
        return self
    }

    func state(_ state: String) -> Self {
        self.parameters["state"] = state
        return self
    }

    func parameters(_ parameters: [String: String]) -> Self {
        parameters.forEach { self.parameters[$0] = $1 }
        return self
    }

    func redirectURL(_ redirectURL: URL) -> Self {
        self.redirectURL = redirectURL
        return self
    }

    func nonce(_ nonce: String) -> Self {
        self.nonce = nonce
        return self
    }

    func audience(_ audience: String) -> Self {
        self.parameters["audience"] = audience
        return self
    }

    func issuer(_ issuer: String) -> Self {
        self.issuer = issuer
        return self
    }

    func leeway(_ leeway: Int) -> Self {
        self.leeway = leeway
        return self
    }

    func maxAge(_ maxAge: Int) -> Self {
        self.maxAge = maxAge
        return self
    }

    func useEphemeralSession() -> Self {
        self.ephemeralSession = true
        return self
    }

    func invitationURL(_ invitationURL: URL) -> Self {
        self.invitationURL = invitationURL
        return self
    }

    func organization(_ organization: String) -> Self {
        self.organization = organization
        return self
    }

    func start(_ callback: @escaping (Auth0Result<Credentials>) -> Void) {
        guard let redirectURL = self.redirectURL else {
            return callback(.failure(WebAuthError.noBundleIdentifierFound))
        }
        let handler = self.handler(redirectURL)
        let state = self.parameters["state"] ?? generateDefaultState()
        var organization: String? = self.organization
        var invitation: String?
        if let invitationURL = self.invitationURL {
            guard let queryItems = URLComponents(url: invitationURL, resolvingAgainstBaseURL: false)?.queryItems,
                let organizationId = queryItems.first(where: { $0.name == "organization" })?.value,
                let invitationId = queryItems.first(where: { $0.name == "invitation" })?.value else {
                return callback(.failure(WebAuthError.unknownError)) // TODO: On the next major, create a new error case
            }
            organization = organizationId
            invitation = invitationId
        }

        let authorizeURL = self.buildAuthorizeURL(withRedirectURL: redirectURL,
                                                  defaults: handler.defaults,
                                                  state: state,
                                                  organization: organization,
                                                  invitation: invitation)
        let session = ASTransaction(authorizeURL: authorizeURL,
                                    redirectURL: redirectURL,
                                    state: state,
                                    handler: handler,
                                    logger: self.logger,
                                    ephemeralSession: self.ephemeralSession,
                                    callback: callback)
        logger?.trace(url: authorizeURL, source: String(describing: session.self))
        self.storage.store(session)
    }

    func clearSession(federated: Bool, callback: @escaping (Bool) -> Void) {
        let endpoint = federated ?
            URL(string: "/v2/logout?federated", relativeTo: self.url)! :
            URL(string: "/v2/logout", relativeTo: self.url)!

        let returnTo = URLQueryItem(name: "returnTo", value: self.redirectURL?.absoluteString)
        let clientId = URLQueryItem(name: "client_id", value: self.clientId)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: true)
        let queryItems = components?.queryItems ?? []
        components?.queryItems = queryItems + [returnTo, clientId]

        guard let logoutURL = components?.url, let redirectURL = self.redirectURL else {
            return callback(false)
        }

        let session = ASCallbackTransaction(url: logoutURL,
                                            schemeURL: redirectURL,
                                            callback: callback)
        self.storage.store(session)
    }

    func buildAuthorizeURL(withRedirectURL redirectURL: URL,
                           defaults: [String: String],
                           state: String?,
                           organization: String?,
                           invitation: String?) -> URL {
        let authorize = URL(string: "/authorize", relativeTo: self.url)!
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: true)!
        var items: [URLQueryItem] = []
        var entries = defaults

        entries["scope"] = defaultScope
        entries["client_id"] = self.clientId
        entries["response_type"] = self.responseType
        entries["redirect_uri"] = redirectURL.absoluteString
        entries["state"] = state
        entries["nonce"] = nonce
        entries["organization"] = organization
        entries["invitation"] = invitation

        if let maxAge = self.maxAge {
            entries["max_age"] = String(maxAge)
        }

        self.parameters.forEach { entries[$0] = $1 }

        if let scope = entries["scope"]?.split(separator: " ").map(String.init), !scope.contains(requiredScope) {
            entries["scope"] = "\(requiredScope) \(entries["scope"]!)"
        }

        entries.forEach { items.append(URLQueryItem(name: $0, value: $1)) }
        components.queryItems = self.telemetry.queryItemsWithTelemetry(queryItems: items)
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func handler(_ redirectURL: URL) -> OAuth2Grant {
        var authentication = Auth0Authentication(clientId: self.clientId, url: self.url, telemetry: self.telemetry)
        authentication.logger = self.logger
        return PKCE(authentication: authentication,
                    redirectURL: redirectURL,
                    issuer: self.issuer,
                    leeway: self.leeway,
                    maxAge: self.maxAge,
                    nonce: self.nonce,
                    organization: self.organization)
    }

    func generateDefaultState() -> String? {
        let data = Data(count: 32)
        var tempData = data

        let result = tempData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, data.count, $0.baseAddress!)
        }

        guard result == 0 else { return nil }
        return tempData.a0_encodeBase64URLSafe()
    }

}

extension Auth0Authentication {

    func webAuth(withConnection connection: String) -> WebAuth {
        let webAuth = Auth0WebAuth(clientId: self.clientId, url: self.url, telemetry: self.telemetry)
        return webAuth
            .logging(enabled: self.logger != nil)
            .connection(connection)
    }

}
#endif