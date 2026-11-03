import Foundation

/// Meeting-link extraction and the "join my next meeting" pick, from synthetic events only.
enum RioMeetingLinksTests {
    private static func url(_ text: String) -> URL { URL(string: text)! }
    private static let now = RioDateTimeParserTests.now
    private static func d(_ h: Int, _ m: Int = 0, day: Int = 3) -> Date { RioDateTimeParserTests.date(2026, 11, day, h, m) }

    static func run() {
        links()
        picking()
    }

    private static func links() {
        let zoom = "https://us02web.zoom.us/j/81234567890?pwd=AbC123"
        TestSupport.expectEqual(RioMeetingLinks.joinURL(url: url(zoom), location: nil, notes: nil), url(zoom))
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(url: nil, location: "https://zoom.us/j/123456789", notes: nil),
            url("https://zoom.us/j/123456789")
        )
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(url: nil, location: "Room 4", notes: "Join: https://meet.google.com/abc-defg-hij."),
            url("https://meet.google.com/abc-defg-hij")
        )
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(url: nil, location: nil, notes: "Click (https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=1) to join"),
            url("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=1")
        )
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(url: nil, location: nil, notes: "FaceTime https://facetime.apple.com/join#v=1&p=abc"),
            url("https://facetime.apple.com/join#v=1&p=abc")
        )
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(url: nil, location: nil, notes: "https://acme.webex.com/meet/ali"),
            url("https://acme.webex.com/meet/ali")
        )
        // Priority: the URL field, then the location, then the notes.
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(
                url: url("https://meet.google.com/aaa-bbbb-ccc"),
                location: "https://zoom.us/j/1",
                notes: "https://zoom.us/j/2"
            ),
            url("https://meet.google.com/aaa-bbbb-ccc")
        )
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(url: url("https://example.com/agenda"), location: "https://zoom.us/j/1", notes: nil),
            url("https://zoom.us/j/1")
        )
        // The first meeting link wins, skipping ordinary links.
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(
                url: nil, location: nil,
                notes: "Agenda https://docs.example.com/a then https://zoom.us/j/55 or https://zoom.us/j/66"
            ),
            url("https://zoom.us/j/55")
        )
        // Outlook safelinks wrap the real link.
        let wrapped = "https://nam11.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2Fabc&data=05"
        TestSupport.expectEqual(
            RioMeetingLinks.joinURL(url: nil, location: nil, notes: wrapped),
            url("https://teams.microsoft.com/l/meetup-join/abc")
        )
        // Look-alike hosts, other schemes and plain text never count.
        let hostile: [String] = [
            "https://evilzoom.us/j/1", "http://zoom.us.evil.com/j/1", "https://notmeet.google.com.evil.io/x",
            "javascript:alert(1)", "file:///etc/passwd", "zoommtg://zoom.us/join?confno=1",
            "Zoom link to follow", "https://example.com/zoom.us",
        ]
        for text in hostile {
            TestSupport.expect(
                RioMeetingLinks.joinURL(url: URL(string: text), location: text, notes: text) == nil,
                "'\(text)' must not be a join link"
            )
        }
        TestSupport.expect(RioMeetingLinks.joinURL(url: nil, location: nil, notes: nil) == nil, "no inputs")
    }

    private static func event(_ id: String, _ title: String, _ start: Date, _ end: Date, link: String? = nil,
                              allDay: Bool = false, declined: Bool = false, unaccepted: Bool = false) -> RioCalendarEventInfo {
        RioCalendarEventInfo(
            identifier: id, title: title, start: start, end: end, isAllDay: allDay,
            location: nil, notes: nil, url: link.flatMap(URL.init(string:)), isDeclined: declined,
            isUnacceptedInvite: unaccepted
        )
    }

    private static func picking() {
        let zoom = "https://zoom.us/j/9"
        let current = event("1", "Standup", d(9, 30), d(10, 30), link: zoom)
        let later = event("2", "Call with Ali", d(15), d(16), link: "https://meet.google.com/aaa-bbbb-ccc")
        let lunch = event("3", "Lunch", d(12), d(13))

        // An invite the owner never accepted (calendar spam with a Zoom link) is never auto-joined.
        let spam = event("9", "You won a prize", d(9, 45), d(10, 45), link: "https://zoom.us/j/666", unaccepted: true)
        TestSupport.expectEqual(
            RioMeetingPicker.pick(events: [spam, later], now: now),
            .join(later, url("https://meet.google.com/aaa-bbbb-ccc"))
        )
        // A meeting in progress is joinable.
        TestSupport.expectEqual(RioMeetingPicker.pick(events: [later, current], now: now), .join(current, url(zoom)))
        // Otherwise the next one with a link, skipping link-less events, all-day events and declined ones.
        TestSupport.expectEqual(
            RioMeetingPicker.pick(events: [lunch, later], now: now),
            .join(later, url("https://meet.google.com/aaa-bbbb-ccc"))
        )
        let allDay = event("4", "Holiday", d(0), d(23, 59), link: zoom, allDay: true)
        let declined = event("5", "Declined call", d(11), d(12), link: zoom, declined: true)
        let past = event("6", "Earlier", d(8), d(9), link: zoom)
        TestSupport.expectEqual(
            RioMeetingPicker.pick(events: [allDay, declined, past, later], now: now),
            .join(later, url("https://meet.google.com/aaa-bbbb-ccc"))
        )
        // Events with no link: say so for the first real event.
        TestSupport.expectEqual(RioMeetingPicker.pick(events: [lunch], now: now), .noLink(lunch))
        TestSupport.expectEqual(RioMeetingPicker.pick(events: [], now: now), .none)
        TestSupport.expectEqual(RioMeetingPicker.pick(events: [allDay, past], now: now), .none)
        // Beyond 24 hours is not "next".
        let tomorrowNoon = event("7", "Far call", d(13, day: 5), d(14, day: 5), link: zoom)
        TestSupport.expectEqual(RioMeetingPicker.pick(events: [tomorrowNoon], now: now), .none)
        // Input order doesn't matter.
        TestSupport.expectEqual(
            RioMeetingPicker.pick(events: [later, lunch, current], now: now),
            RioMeetingPicker.pick(events: [current, lunch, later], now: now)
        )
    }
}
