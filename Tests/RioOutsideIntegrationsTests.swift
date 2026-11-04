import Foundation

/// Spotify (PKCE, search, play), Notion (blocks) and Canvas (planner) with fixtures and a fake network.
enum RioOutsideIntegrationsTests {
    static func run() async {
        pkce()
        spotifyRequests()
        spotifyParsing()
        await spotifyService()
        notionPieces()
        await notionService()
        canvasPieces()
        await canvasService()
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func form(_ request: URLRequest) -> [String: String] {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1].removingPercentEncoding }
        }
        return result
    }

    private static func json(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    // MARK: Spotify

    private static func pkce() {
        // RFC 7636 appendix B.
        TestSupport.expectEqual(
            RioSpotifyPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        let verifier = RioSpotifyPKCE.makeVerifier()
        TestSupport.expectEqual(verifier.count, 64)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        TestSupport.expect(verifier.allSatisfy { allowed.contains($0) }, "verifier uses only unreserved characters")
        TestSupport.expect(verifier != RioSpotifyPKCE.makeVerifier(), "verifiers are random")
        TestSupport.expectEqual(RioSpotifyPKCE.verifier(from: [0, 1, 2, 255, 26]), "ABCa")  // 255 is skipped (modulo bias)
        TestSupport.expect(!RioSpotifyPKCE.makeState().isEmpty, "a state value is made")
    }

    private static func spotifyRequests() {
        let url = RioSpotifyRequests.authorizeURL(clientID: "abc123", challenge: "CHAL", state: "st4te")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        TestSupport.expectEqual(url.host, "accounts.spotify.com")
        TestSupport.expectEqual(items["response_type"], "code")
        TestSupport.expectEqual(items["client_id"], "abc123")
        TestSupport.expectEqual(items["redirect_uri"], "http://127.0.0.1:8898/callback")
        TestSupport.expectEqual(items["code_challenge_method"], "S256")
        TestSupport.expectEqual(items["code_challenge"], "CHAL")
        TestSupport.expectEqual(items["state"], "st4te")
        TestSupport.expectEqual(items["scope"], "user-modify-playback-state user-read-playback-state")

        let exchange = RioSpotifyRequests.tokenExchange(clientID: "abc123", code: "the code", verifier: "VER")
        TestSupport.expectEqual(exchange.httpMethod, "POST")
        TestSupport.expectEqual(exchange.url?.absoluteString, "https://accounts.spotify.com/api/token")
        TestSupport.expectEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        TestSupport.expectEqual(form(exchange)["grant_type"], "authorization_code")
        TestSupport.expectEqual(form(exchange)["code"], "the code")
        TestSupport.expectEqual(form(exchange)["code_verifier"], "VER")
        TestSupport.expectEqual(form(exchange)["redirect_uri"], "http://127.0.0.1:8898/callback")
        TestSupport.expect(form(exchange)["client_secret"] == nil, "PKCE sends no client secret")

        let refresh = RioSpotifyRequests.tokenRefresh(clientID: "abc123", refreshToken: "RT")
        TestSupport.expectEqual(form(refresh)["grant_type"], "refresh_token")
        TestSupport.expectEqual(form(refresh)["refresh_token"], "RT")
        TestSupport.expectEqual(form(refresh)["client_id"], "abc123")

        let search = RioSpotifyRequests.search(query: "blinding lights & more", accessToken: "AT")
        TestSupport.expectEqual(search.url?.host, "api.spotify.com")
        TestSupport.expectEqual(search.url?.path, "/v1/search")
        TestSupport.expectEqual(query(search)["q"], "blinding lights & more")
        TestSupport.expectEqual(query(search)["type"], "track,artist")
        TestSupport.expectEqual(query(search)["limit"], "1")
        TestSupport.expectEqual(search.value(forHTTPHeaderField: "Authorization"), "Bearer AT")

        let playTrack = RioSpotifyRequests.play(target: .track(uri: "spotify:track:1", title: "T", artist: "A"), accessToken: "AT")
        TestSupport.expectEqual(playTrack.httpMethod, "PUT")
        TestSupport.expectEqual(playTrack.url?.absoluteString, "https://api.spotify.com/v1/me/player/play")
        TestSupport.expectEqual(json(playTrack)["uris"] as? [String], ["spotify:track:1"])
        let playArtist = RioSpotifyRequests.play(target: .artist(uri: "spotify:artist:9", name: "N"), accessToken: "AT")
        TestSupport.expectEqual(json(playArtist)["context_uri"] as? String, "spotify:artist:9")
        TestSupport.expect(json(playArtist)["uris"] == nil, "an artist plays as a context")
    }

    static let searchFixture = #"{"tracks":{"items":[{"uri":"spotify:track:0VjIjW4GlUZAMYd2vXMi3b","name":"Blinding Lights","artists":[{"name":"The Weeknd"}]}]},"artists":{"items":[{"uri":"spotify:artist:1Xyo4u8uXC1ZmMpatF05PJ","name":"The Weeknd"}]}}"#

    private static func spotifyParsing() {
        let token = RioSpotifyParser.token(from: Data(#"{"access_token":"AT","token_type":"Bearer","expires_in":3600,"refresh_token":"RT2","scope":"x"}"#.utf8))
        TestSupport.expectEqual(token, RioSpotifyToken(access: "AT", refresh: "RT2", expiresIn: 3600))
        TestSupport.expectEqual(RioSpotifyParser.token(from: Data(#"{"access_token":"AT","expires_in":10}"#.utf8))?.refresh, nil)
        TestSupport.expect(RioSpotifyParser.token(from: Data(#"{"error":"invalid_grant"}"#.utf8)) == nil, "an error body is not a token")

        let data = Data(searchFixture.utf8)
        TestSupport.expectEqual(
            RioSpotifyParser.target(from: data, query: "blinding lights"),
            .track(uri: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b", title: "Blinding Lights", artist: "The Weeknd")
        )
        TestSupport.expectEqual(
            RioSpotifyParser.target(from: data, query: "the weeknd"),
            .artist(uri: "spotify:artist:1Xyo4u8uXC1ZmMpatF05PJ", name: "The Weeknd")
        )
        TestSupport.expect(RioSpotifyParser.target(from: Data(#"{"tracks":{"items":[]},"artists":{"items":[]}}"#.utf8), query: "zzz") == nil, "nothing found")

        TestSupport.expectEqual(RioSpotifyParser.authorizationCode(fromRequestLine: "GET /callback?code=XYZ&state=st HTTP/1.1", expectedState: "st"), .code("XYZ"))
        TestSupport.expectEqual(RioSpotifyParser.authorizationCode(fromRequestLine: "GET /callback?code=XYZ&state=other HTTP/1.1", expectedState: "st"), .rejected)
        TestSupport.expectEqual(RioSpotifyParser.authorizationCode(fromRequestLine: "GET /callback?error=access_denied&state=st HTTP/1.1", expectedState: "st"), .denied)
        TestSupport.expectEqual(RioSpotifyParser.authorizationCode(fromRequestLine: "GET /favicon.ico HTTP/1.1", expectedState: "st"), .ignore)
        TestSupport.expectEqual(RioSpotifyParser.authorizationCode(fromRequestLine: "POST /callback?code=XYZ&state=st HTTP/1.1", expectedState: "st"), .ignore)

        let appleURL = RioAppleMusic.searchURL(query: "lo fi & chill")
        TestSupport.expectEqual(appleURL?.scheme, "music")
        TestSupport.expect(appleURL?.absoluteString.contains("term=lo%20fi%20%26%20chill") == true, "term is encoded: \(String(describing: appleURL))")
    }

    private static func spotifyService() async {
        let network = RioFakeNetwork([
            RioFakeNetwork.rule("accounts.spotify.com/api/token", #"{"access_token":"AT","expires_in":3600,"refresh_token":"RT-new"}"#),
            RioFakeNetwork.rule("api.spotify.com/v1/search", searchFixture),
            RioFakeNetwork.rule("api.spotify.com/v1/me/player/play", 204, ""),
        ])
        let service = RioSpotifyService(fetch: network.fetch, clientID: "abc123", refreshToken: "RT")
        let result = try? await service.play(query: "blinding lights")
        TestSupport.expectEqual(result?.outcome, .playing("Playing Blinding Lights by The Weeknd"))
        TestSupport.expectEqual(result?.newRefreshToken, "RT-new")
        TestSupport.expectEqual(network.requests.count, 3)
        TestSupport.expectEqual(network.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer AT")

        let noDevice = RioFakeNetwork([
            RioFakeNetwork.rule("accounts.spotify.com/api/token", #"{"access_token":"AT","expires_in":3600}"#),
            RioFakeNetwork.rule("api.spotify.com/v1/search", searchFixture),
            RioFakeNetwork.rule("api.spotify.com/v1/me/player/play", 404, #"{"error":{"status":404,"reason":"NO_ACTIVE_DEVICE"}}"#),
        ])
        let idle = try? await RioSpotifyService(fetch: noDevice.fetch, clientID: "abc123", refreshToken: "RT").play(query: "blinding lights")
        if case .noDevice(let target)? = idle?.outcome {
            TestSupport.expectEqual(target.uri, "spotify:track:0VjIjW4GlUZAMYd2vXMi3b")
        } else {
            fatalError("a missing device must be reported as noDevice, got \(String(describing: idle))")
        }
        TestSupport.expectEqual(idle?.newRefreshToken, nil)

        let revoked = RioFakeNetwork([RioFakeNetwork.rule("accounts.spotify.com/api/token", 400, #"{"error":"invalid_grant"}"#)])
        do {
            _ = try await RioSpotifyService(fetch: revoked.fetch, clientID: "abc123", refreshToken: "RT").play(query: "x")
            fatalError("a revoked token must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .notConfigured(RioSpotifyService.reconnectMessage))
        }
        let nothing = RioFakeNetwork([
            RioFakeNetwork.rule("accounts.spotify.com/api/token", #"{"access_token":"AT","expires_in":3600}"#),
            RioFakeNetwork.rule("api.spotify.com/v1/search", #"{"tracks":{"items":[]},"artists":{"items":[]}}"#),
        ])
        do {
            _ = try await RioSpotifyService(fetch: nothing.fetch, clientID: "abc123", refreshToken: "RT").play(query: "zzz")
            fatalError("no match must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .notFound("zzz"))
        }
    }

    // MARK: Notion

    private static let pageID = "0123456789abcdef0123456789abcdef"
    private static let dashedID = "01234567-89ab-cdef-0123-456789abcdef"

    private static func notionPieces() {
        TestSupport.expectEqual(RioNotionPageID.extract(from: "https://www.notion.so/My-Page-\(pageID)"), dashedID)
        TestSupport.expectEqual(RioNotionPageID.extract(from: "https://www.notion.so/workspace/\(pageID)?pvs=4"), dashedID)
        TestSupport.expectEqual(RioNotionPageID.extract(from: pageID), dashedID)
        TestSupport.expectEqual(RioNotionPageID.extract(from: " \(dashedID) "), dashedID)
        TestSupport.expect(RioNotionPageID.extract(from: "my notes") == nil, "a name is not an id")
        TestSupport.expect(RioNotionPageID.extract(from: "") == nil, "empty is not an id")

        let blocks = RioNotionRequests.blocks(for: "buy milk")
        TestSupport.expectEqual(blocks.count, 1)
        let paragraph = blocks[0]["paragraph"] as? [String: Any]
        let richText = paragraph?["rich_text"] as? [[String: Any]]
        let content = (richText?.first?["text"] as? [String: Any])?["content"] as? String
        TestSupport.expectEqual(blocks[0]["type"] as? String, "paragraph")
        TestSupport.expectEqual(blocks[0]["object"] as? String, "block")
        TestSupport.expectEqual(content, "buy milk")
        let long = RioNotionRequests.blocks(for: String(repeating: "a", count: 4_500))
        TestSupport.expectEqual(long.count, 3)
        TestSupport.expect(long.allSatisfy {
            (((($0["paragraph"] as? [String: Any])?["rich_text"] as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String)?.count ?? 9_999 <= 2_000
        }, "no block exceeds Notion's 2000 character limit")

        let append = RioNotionRequests.append(pageID: dashedID, text: "buy \"milk\"\nand eggs", token: "secret_x")!
        TestSupport.expectEqual(append.httpMethod, "PATCH")
        TestSupport.expectEqual(append.url?.absoluteString, "https://api.notion.com/v1/blocks/\(dashedID)/children")
        TestSupport.expectEqual(append.value(forHTTPHeaderField: "Authorization"), "Bearer secret_x")
        TestSupport.expectEqual(append.value(forHTTPHeaderField: "Notion-Version"), "2022-06-28")
        TestSupport.expectEqual(append.value(forHTTPHeaderField: "Content-Type"), "application/json")
        TestSupport.expectEqual((json(append)["children"] as? [[String: Any]])?.count, 1)
        TestSupport.expect(RioNotionRequests.append(pageID: "../../users", text: "x", token: "t") == nil, "a page id must be a UUID")

        let search = RioNotionRequests.search(query: "tasks", token: "secret_x")
        TestSupport.expectEqual(search.url?.absoluteString, "https://api.notion.com/v1/search")
        TestSupport.expectEqual(search.httpMethod, "POST")
        TestSupport.expectEqual(json(search)["query"] as? String, "tasks")

        let found = Data(#"{"results":[{"object":"page","id":"\#(dashedID)","properties":{"Name":{"type":"title","title":[{"plain_text":"My "},{"plain_text":"Tasks"}]}}}]}"#.utf8)
        let match = RioNotionParser.pageMatch(from: found)
        TestSupport.expectEqual(match?.id, dashedID)
        TestSupport.expectEqual(match?.title, "My Tasks")
        TestSupport.expect(RioNotionParser.pageMatch(from: Data(#"{"results":[]}"#.utf8)) == nil, "no pages")
    }

    private static func notionService() async {
        let network = RioFakeNetwork([
            RioFakeNetwork.rule("api.notion.com/v1/search", #"{"results":[{"object":"page","id":"\#(dashedID)","properties":{"title":{"type":"title","title":[{"plain_text":"Tasks"}]}}}]}"#),
            RioFakeNetwork.rule("api.notion.com/v1/blocks/", #"{"object":"list"}"#),
        ])
        let viaSearch = try? await RioNotionService(fetch: network.fetch, token: "secret_x", defaultPage: nil).add(text: "buy milk", page: "tasks")
        TestSupport.expectEqual(viaSearch, "Tasks")
        TestSupport.expectEqual(network.requests.count, 2)

        let direct = RioFakeNetwork([RioFakeNetwork.rule("api.notion.com/v1/blocks/", #"{"object":"list"}"#)])
        let usedDefault = try? await RioNotionService(fetch: direct.fetch, token: "secret_x", defaultPage: "https://notion.so/Inbox-\(pageID)").add(text: "x", page: nil)
        TestSupport.expectEqual(usedDefault, "your Notion page")
        TestSupport.expectEqual(direct.requests.count, 1)

        do {
            _ = try await RioNotionService(fetch: direct.fetch, token: "secret_x", defaultPage: nil).add(text: "x", page: nil)
            fatalError("no page and no default must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .notConfigured(RioNotionService.noPageMessage))
        }
        let missing = RioFakeNetwork([RioFakeNetwork.rule("api.notion.com/v1/search", #"{"results":[]}"#)])
        do {
            _ = try await RioNotionService(fetch: missing.fetch, token: "secret_x", defaultPage: nil).add(text: "x", page: "ghost")
            fatalError("an unknown page must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .notFound("ghost"))
        }
        let unauthorized = RioFakeNetwork([RioFakeNetwork.rule("api.notion.com/v1/blocks/", 401, #"{"object":"error"}"#)])
        do {
            _ = try await RioNotionService(fetch: unauthorized.fetch, token: "bad", defaultPage: pageID).add(text: "x", page: nil)
            fatalError("a bad token must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .http(401))
        }
    }

    // MARK: Canvas

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    /// Tuesday 2026-11-03 14:05:09 UTC.
    private static let now = Date(timeIntervalSince1970: 1_793_714_709)

    static let plannerFixture = """
    [
     {"plannable_type":"assignment","plannable_date":"2026-11-05T07:59:00Z","plannable":{"id":1,"title":"Homework 6","due_at":"2026-11-05T07:59:00Z"},"context_name":"MAT 108","submissions":{"submitted":false,"excused":false,"graded":false,"missing":false}},
     {"plannable_type":"assignment","plannable_date":"2026-11-04T08:00:00Z","plannable":{"id":2,"title":"Homework 5","due_at":"2026-11-04T08:00:00Z"},"context_name":"MAT 108","submissions":{"submitted":true,"excused":false,"graded":false,"missing":false}},
     {"plannable_type":"quiz","plannable_date":"2026-11-04T20:00:00Z","plannable":{"id":3,"title":"Quiz 3","due_at":"2026-11-04T20:00:00Z"},"context_name":"ECS 119","submissions":false},
     {"plannable_type":"announcement","plannable_date":"2026-11-04T09:00:00Z","plannable":{"id":4,"title":"Office hours moved"},"context_name":"ECS 119","submissions":false},
     {"plannable_type":"assignment","plannable_date":"2026-12-30T08:00:00Z","plannable":{"id":5,"title":"Final project","due_at":"2026-12-30T08:00:00Z"},"context_name":"ECS 119","submissions":{"submitted":false}},
     {"plannable_type":"assignment","plannable_date":"2026-11-03T23:00:00Z","plannable":{"id":6,"title":"Reading response"},"context_name":null,"submissions":{"submitted":false}}
    ]
    """

    private static func canvasPieces() {
        TestSupport.expectEqual(RioCanvasConfig.baseURL(from: "")?.absoluteString, "https://canvas.ucdavis.edu")
        TestSupport.expectEqual(RioCanvasConfig.baseURL(from: "canvas.example.edu/")?.absoluteString, "https://canvas.example.edu")
        TestSupport.expectEqual(RioCanvasConfig.baseURL(from: "https://canvas.example.edu/courses/12")?.absoluteString, "https://canvas.example.edu")
        TestSupport.expect(RioCanvasConfig.baseURL(from: "http://canvas.example.edu") == nil, "Canvas must be https, the token travels there")
        TestSupport.expect(RioCanvasConfig.baseURL(from: "ftp://x") == nil, "only https")

        let today = RioCanvasRange.interval(for: "today", now: now, calendar: utc)
        TestSupport.expectEqual(today.duration, 86_400)
        TestSupport.expectEqual(RioCanvasRange.interval(for: "tomorrow", now: now, calendar: utc).start, today.end)
        let week = RioCanvasRange.interval(for: "this week", now: now, calendar: utc)
        TestSupport.expect(week.contains(Date(timeIntervalSince1970: 1_793_714_709 + 3 * 86_400)), "Friday is this week")
        TestSupport.expect(!week.contains(Date(timeIntervalSince1970: 1_793_714_709 + 8 * 86_400)), "next Wednesday is not this week")
        let next = RioCanvasRange.interval(for: "next week", now: now, calendar: utc)
        TestSupport.expectEqual(next.start, week.end)
        let open = RioCanvasRange.interval(for: nil, now: now, calendar: utc)
        TestSupport.expectEqual(open.duration, 7 * 86_400)
        TestSupport.expectEqual(RioCanvasRange.label(for: nil), "in the next 7 days")
        TestSupport.expectEqual(RioCanvasRange.label(for: "this week"), "this week")

        let request = RioCanvasRequests.planner(base: URL(string: "https://canvas.example.edu")!, interval: week, token: "tok")
        TestSupport.expectEqual(request.url?.host, "canvas.example.edu")
        TestSupport.expectEqual(request.url?.path, "/api/v1/planner/items")
        TestSupport.expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        // "This week" starts now, not last Sunday: work due Monday is overdue, not "due this week".
        TestSupport.expect(query(request)["start_date"]?.hasPrefix("2026-11-03T14:05") == true, "start date is now: \(String(describing: query(request)["start_date"]))")
        TestSupport.expect(!week.contains(Date(timeIntervalSince1970: 1_793_714_709 - 86_400)), "yesterday is not due this week")
        TestSupport.expectEqual(query(request)["per_page"], "50")

        let items = RioCanvasParser.items(from: Data(plannerFixture.utf8), interval: week)
        TestSupport.expectEqual(items.map(\.title), ["Reading response", "Quiz 3", "Homework 6"])
        TestSupport.expectEqual(items.last?.course, "MAT 108")
        TestSupport.expectEqual(items.first?.course, nil)
        TestSupport.expect(RioCanvasParser.items(from: Data("nope".utf8), interval: week).isEmpty, "garbage gives no items")

        let two = Array(items.dropFirst())
        TestSupport.expectEqual(
            RioCanvasSpeech.sentence(items: two, range: "this week", now: now, calendar: utc),
            "You have 2 things due this week: Quiz 3 for ECS 119 tomorrow at 8:00 PM, Homework 6 for MAT 108 Thursday at 7:59 AM."
        )
        TestSupport.expectEqual(
            RioCanvasSpeech.sentence(items: [items[0]], range: "today", now: now, calendar: utc),
            "You have 1 thing due today: Reading response today at 11:00 PM."
        )
        TestSupport.expectEqual(RioCanvasSpeech.sentence(items: [], range: "today", now: now, calendar: utc), "Nothing due today on Canvas.")
        canvasCoursesAndOverdue()
        let many = (0..<6).map { RioCanvasItem(title: "Task \($0)", course: nil, due: now.addingTimeInterval(Double($0) * 3_600)) }
        let spoken = RioCanvasSpeech.sentence(items: many, range: nil, now: now, calendar: utc)
        TestSupport.expect(spoken.hasPrefix("You have 6 things due in the next 7 days:") && spoken.hasSuffix("and 2 more."), spoken)
    }

    private static func canvasCoursesAndOverdue() {
        // The range string carries a course code; plain ranges work as before.
        TestSupport.expect(RioCanvasRange.parts("next week MAT108") == ("next week", "MAT108"), "range + course")
        TestSupport.expect(RioCanvasRange.parts("MAT108") == (nil, "MAT108"), "course only")
        TestSupport.expect(RioCanvasRange.parts("today") == ("today", nil), "range only")
        TestSupport.expect(RioCanvasRange.parts(nil) == (nil, nil), "nil")
        TestSupport.expect(RioCanvasRange.parts("whenever you like") == (nil, nil), "unknown range is ignored")
        TestSupport.expectEqual(RioCanvasRange.label(for: "this week ECS119"), "this week")
        TestSupport.expectEqual(RioCanvasRange.interval(for: "MAT108", now: now, calendar: utc).duration, 7 * 86_400)

        let homework = RioCanvasItem(title: "Homework 6", course: "MAT 108 A01 Fall 2026", due: now.addingTimeInterval(2 * 86_400))
        let quiz = RioCanvasItem(title: "Quiz 3", course: "ECS 119", due: now.addingTimeInterval(3_600))
        TestSupport.expect(RioCanvasRange.item(homework, isFor: "MAT108"), "MAT108 matches MAT 108 A01")
        TestSupport.expect(RioCanvasRange.item(homework, isFor: "mat 108"), "spaces and case ignored")
        TestSupport.expect(!RioCanvasRange.item(homework, isFor: "MAT10"), "MAT10 is not MAT108")
        TestSupport.expect(!RioCanvasRange.item(quiz, isFor: "MAT108"), "ECS 119 is not MAT108")
        TestSupport.expect(!RioCanvasRange.item(RioCanvasItem(title: "x", course: nil, due: now), isFor: "MAT108"), "no course, no match")
        TestSupport.expectEqual(
            RioCanvasSpeech.sentence(items: [homework], range: "MAT108", now: now, calendar: utc),
            "For MAT108 you have 1 thing due in the next 7 days: Homework 6 Thursday at 2:05 PM."
        )
        TestSupport.expectEqual(
            RioCanvasSpeech.sentence(items: [], range: "this week MAT108", now: now, calendar: utc),
            "Nothing due this week for MAT108 on Canvas."
        )
        // Past items are overdue, never "today at".
        let late = RioCanvasItem(title: "Homework 5", course: "MAT 108", due: now.addingTimeInterval(-2 * 86_400))
        let earlier = RioCanvasItem(title: "Reading", course: nil, due: now.addingTimeInterval(-3_600))
        TestSupport.expectEqual(
            RioCanvasSpeech.sentence(items: [late, earlier], range: "today", now: now, calendar: utc),
            "You have 2 things due today: Homework 5 for MAT 108 overdue since Sunday at 2:05 PM, Reading overdue since 1:05 PM today."
        )
    }

    private static func canvasService() async {
        let network = RioFakeNetwork([RioFakeNetwork.rule("/api/v1/planner/items", plannerFixture)])
        let service = RioCanvasService(fetch: network.fetch, base: URL(string: "https://canvas.example.edu")!, token: "tok")
        let answer = try? await service.due(range: "this week", now: now, calendar: utc)
        TestSupport.expect(answer?.hasPrefix("You have 3 things due this week") == true, "got \(String(describing: answer))")
        let mat = try? await service.due(range: "this week MAT108", now: now, calendar: utc)
        TestSupport.expectEqual(mat, "For MAT108 you have 1 thing due this week: Homework 6 Thursday at 7:59 AM.")
        let rejected = RioFakeNetwork([RioFakeNetwork.rule("/api/v1/planner/items", 401, #"{"errors":[{"message":"Invalid access token."}]}"#)])
        do {
            _ = try await RioCanvasService(fetch: rejected.fetch, base: URL(string: "https://canvas.example.edu")!, token: "bad").due(range: nil, now: now, calendar: utc)
            fatalError("a rejected token must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .http(401))
        }
    }
}
