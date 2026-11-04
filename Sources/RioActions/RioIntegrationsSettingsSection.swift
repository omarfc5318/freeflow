import SwiftUI

/// Settings for weather, news, music, Notion, Canvas and texting Rio from the iPhone (builder S).
/// The lead embeds this in the Settings window. Every integration has its own switch, says what it
/// sends, and has step-by-step setup. Tokens are kept in the app's private settings file (owner
/// read/write only, next to the AI provider key), not the Keychain, and never logged.
struct RioIntegrationsSettingsSection: View {
    @AppStorage(RioOutsideSettings.weatherEnabledKey) private var weatherOn = true
    @AppStorage(RioOutsideSettings.weatherPlaceKey) private var weatherPlace = ""
    @AppStorage(RioOutsideSettings.newsEnabledKey) private var newsOn = true
    @AppStorage(RioOutsideSettings.newsModelKey) private var newsModel = ""
    @AppStorage(RioOutsideSettings.musicEnabledKey) private var musicOn = true
    @AppStorage(RioOutsideSettings.notionEnabledKey) private var notionOn = true
    @AppStorage(RioOutsideSettings.notionPageKey) private var notionPage = ""
    @AppStorage(RioOutsideSettings.canvasEnabledKey) private var canvasOn = true
    @AppStorage(RioOutsideSettings.canvasBaseKey) private var canvasBase = ""

    @State private var spotifyClientID = ""
    @State private var spotifyConnected = false
    @State private var spotifyMessage = ""
    @State private var spotifyBusy = false
    @State private var notionToken = ""
    @State private var canvasToken = ""

    /// Where the tokens really live, said plainly (the same place as the AI provider key).
    static let tokenStorageNote = "Your Spotify, Notion and Canvas tokens are kept in Rio's private settings file on this Mac (Application Support, readable only by your user account), next to your AI provider key. They are not in the Keychain, so anything running as you, or a backup of your Mac, can read them. Remove a Notion or Canvas token by clearing its field and saving."

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            weatherAndNews
            Divider()
            spotify
            Divider()
            notion
            Divider()
            canvas
            Divider()
            RioPhoneSettingsSection()
            Text(Self.tokenStorageNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
    }

    // MARK: Weather and news

    private var weatherAndNews: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weather and news").font(.headline)
            Toggle("Weather (\"what's the weather\")", isOn: $weatherOn)
            Text("Rio sends only the place name, then its coordinates, to Open-Meteo (open-meteo.com). No account or key, and no other data.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Default place, like Davis", text: $weatherPlace).textFieldStyle(.roundedBorder)
            Toggle("News (\"what's the news\")", isOn: $newsOn)
            Text("Rio asks the AI provider you set up for dictation, using a model that can search the web (on Groq, compound-mini), and sends only the topic and today's date. If your provider has no such model, Rio says news isn't available.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Search model (optional)", text: $newsModel).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Spotify

    private var spotify: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Music").font(.headline)
            Toggle("Play music (\"play Blinding Lights\")", isOn: $musicOn)
            steps("""
            Set up Spotify (needs Spotify Premium, and Spotify open on this Mac or your phone):
            1. Go to developer.spotify.com/dashboard, sign in, and press Create app.
            2. Name it Rio. For Redirect URI, add exactly: \(RioSpotifyRequests.redirectURI)
            3. Tick Web API, accept the terms, and save.
            4. Open the app's Settings, copy the Client ID, paste it below, and press Connect Spotify.
            5. Approve in your browser. Rio keeps a login token on this Mac, no password.
            Without Spotify, Rio opens a search in Apple Music instead.
            """)
            TextField("Spotify client ID", text: $spotifyClientID).textFieldStyle(.roundedBorder)
            HStack {
                Button(spotifyConnected ? "Reconnect Spotify" : "Connect Spotify") { connectSpotify() }
                    .disabled(spotifyBusy)
                if spotifyConnected {
                    Button("Disconnect", role: .destructive) { disconnectSpotify() }
                    Label("Connected", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
            }
            if !spotifyMessage.isEmpty { Text(spotifyMessage).font(.caption).foregroundStyle(.secondary) }
            Text("When you play something, Rio sends the song name and your token to Spotify (api.spotify.com).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Notion

    private var notion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notion").font(.headline)
            Toggle("Add to Notion (\"add buy milk to Notion\")", isOn: $notionOn)
            steps("""
            Set up Notion:
            1. Go to notion.so/profile/integrations and press New integration. Choose Internal and name it Rio.
            2. Copy the Internal Integration Secret and paste it below.
            3. Open the page you want notes added to, press the three dots, then Connections, and add Rio.
            4. Paste that page's link below as the default page.
            Say "add finish the essay to my tasks page in Notion" to pick another page you shared with Rio.
            """)
            SecureField("Notion token", text: $notionToken)
                .textFieldStyle(.roundedBorder)
                .onSubmit { RioOutsideSettings.setSecret(notionToken, account: RioOutsideSettings.notionTokenAccount) }
            TextField("Default page link", text: $notionPage).textFieldStyle(.roundedBorder)
            Button("Save Notion token") { RioOutsideSettings.setSecret(notionToken, account: RioOutsideSettings.notionTokenAccount) }
            Text("Rio sends your text and token to Notion (api.notion.com) only when you ask it to add something.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Canvas").font(.headline)
            Toggle("Canvas due dates (\"what's due this week\")", isOn: $canvasOn)
            steps("""
            Set up Canvas:
            1. Sign in to Canvas, press Account, then Settings.
            2. Under Approved Integrations, press New Access Token. Purpose: Rio. Leave expiry empty or pick a date.
            3. Copy the token (Canvas shows it once) and paste it below.
            4. If your school isn't UC Davis, enter its Canvas address, like https://canvas.school.edu
            """)
            SecureField("Canvas token", text: $canvasToken)
                .textFieldStyle(.roundedBorder)
                .onSubmit { RioOutsideSettings.setSecret(canvasToken, account: RioOutsideSettings.canvasTokenAccount) }
            TextField("Canvas address (default \(RioCanvasConfig.defaultBase))", text: $canvasBase).textFieldStyle(.roundedBorder)
            Button("Save Canvas token") { RioOutsideSettings.setSecret(canvasToken, account: RioOutsideSettings.canvasTokenAccount) }
            Text("Rio sends your token only to the Canvas address above, and only when you ask what's due. It must start with https://.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func steps(_ text: String) -> some View {
        Text(text).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func load() {
        spotifyClientID = RioOutsideSettings.secret(RioOutsideSettings.spotifyClientAccount)
        spotifyConnected = RioOutsideSettings.spotifyConnected
        notionToken = RioOutsideSettings.secret(RioOutsideSettings.notionTokenAccount)
        canvasToken = RioOutsideSettings.secret(RioOutsideSettings.canvasTokenAccount)
    }

    private func connectSpotify() {
        spotifyBusy = true
        spotifyMessage = "Finish the login in your browser..."
        Task { @MainActor in
            let problem = await RioSpotifyAuth.shared.connect(clientID: spotifyClientID)
            spotifyBusy = false
            spotifyConnected = RioOutsideSettings.spotifyConnected
            spotifyMessage = problem ?? "Spotify is connected."
        }
    }

    private func disconnectSpotify() {
        RioOutsideSettings.setSecret("", account: RioOutsideSettings.spotifyRefreshAccount)
        spotifyConnected = false
        spotifyMessage = "Disconnected. You can also remove Rio at spotify.com/account/apps."
    }
}
