import Foundation

/// The pure builders behind keyboard, browser and system control: key combos and codes, the browser
/// command map, battery text, networksetup parsing and brightness math. No real events or settings.
enum RioSystemCoreTests {
    static func run() {
        testComboParsing()
        testComboAllowList()
        testComboDescription()
        testKeyCodes()
        testBrowserPlans()
        testBatterySummary()
        testBatteryFromPowerSource()
        testNetworkSetup()
        testBrightnessMath()
        testPriorState()
    }

    private static func combo(_ key: String, cmd: Bool = false, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) -> KeyCombo {
        KeyCombo(key: key, command: cmd, shift: shift, option: opt, control: ctrl)
    }

    private static func testComboParsing() {
        TestSupport.expectEqual(RioKeyCombos.parse("press command t"), combo("t", cmd: true))
        TestSupport.expectEqual(RioKeyCombos.parse("PRESS Command Shift 4"), combo("4", cmd: true, shift: true))
        TestSupport.expectEqual(RioKeyCombos.parse("hit the enter key"), combo("return"))
        TestSupport.expectEqual(RioKeyCombos.parse("press forward delete"), combo("forwarddelete"))
        TestSupport.expectEqual(RioKeyCombos.parse("press option shift control command f12"), combo("f12", cmd: true, shift: true, opt: true, ctrl: true))
        // Bare keys without a verb or modifier are not shortcuts.
        TestSupport.expectEqual(RioKeyCombos.parse("escape"), nil)
        TestSupport.expectEqual(RioKeyCombos.parse("t"), nil)
        // Modifier only, repeated modifier, trailing junk, empty.
        TestSupport.expectEqual(RioKeyCombos.parse("press command"), nil)
        TestSupport.expectEqual(RioKeyCombos.parse("command command t"), nil)
        TestSupport.expectEqual(RioKeyCombos.parse("press command t twice"), nil)
        TestSupport.expectEqual(RioKeyCombos.parse("press"), nil)
        TestSupport.expectEqual(RioKeyCombos.parse(""), nil)
        // Not on the allow list or not a key at all.
        for hostile in ["press power", "press fn", "press command ;rm", "press rm", "press command q and rm", "press 10", "press command t; reboot"] {
            TestSupport.expectEqual(RioKeyCombos.parse(RioText.simplify(hostile)), nil)
        }
    }

    private static func testComboAllowList() {
        TestSupport.expect(RioKeyCombos.isAllowed(combo("t", cmd: true)), "cmd t allowed")
        TestSupport.expect(!RioKeyCombos.isAllowed(combo("power")), "power not allowed")
        TestSupport.expect(!RioKeyCombos.isAllowed(combo("")), "empty not allowed")
        TestSupport.expect(!RioKeyCombos.isAllowed(combo("T", cmd: true)), "case matters: executors refuse uppercase")
        TestSupport.expect(!RioKeyCombos.isAllowed(combo("rm -rf")), "garbage not allowed")
        for key in KeyCombo.allowedKeys {
            TestSupport.expect(RioKeyCombos.isAllowed(combo(key)), "\(key) should be allowed")
        }
    }

    private static func testComboDescription() {
        TestSupport.expectEqual(RioKeyCombos.describe(combo("t", cmd: true)), "command T")
        TestSupport.expectEqual(RioKeyCombos.describe(combo("4", cmd: true, shift: true)), "shift command 4")
        TestSupport.expectEqual(RioKeyCombos.describe(combo("tab", shift: true, ctrl: true)), "control shift tab")
        TestSupport.expectEqual(RioKeyCombos.describe(combo("return")), "return")
        TestSupport.expectEqual(RioKeyCombos.describe(combo("up", ctrl: true)), "control up arrow")
        TestSupport.expectEqual(RioKeyCombos.describe(combo("leftbracket", cmd: true)), "command left bracket")
    }

    private static func testKeyCodes() {
        var seen: [UInt16: String] = [:]
        for key in KeyCombo.allowedKeys.sorted() {
            guard let code = RioKeyCodes.code(for: key) else {
                TestSupport.expect(false, "no key code for \(key)")
                continue
            }
            TestSupport.expect(seen[code] == nil, "key code \(code) shared by \(key) and \(seen[code] ?? "")")
            seen[code] = key
        }
        TestSupport.expectEqual(RioKeyCodes.code(for: "a"), 0)
        TestSupport.expectEqual(RioKeyCodes.code(for: "t"), 17)
        TestSupport.expectEqual(RioKeyCodes.code(for: "4"), 21)
        TestSupport.expectEqual(RioKeyCodes.code(for: "return"), 36)
        TestSupport.expectEqual(RioKeyCodes.code(for: "escape"), 53)
        TestSupport.expectEqual(RioKeyCodes.code(for: "leftbracket"), 33)
        TestSupport.expectEqual(RioKeyCodes.code(for: "up"), 126)
        TestSupport.expectEqual(RioKeyCodes.code(for: "power"), nil)
        TestSupport.expect(RioKeyCodes.usesFunctionFlag("up") && RioKeyCodes.usesFunctionFlag("f5") && !RioKeyCodes.usesFunctionFlag("t"), "fn flag only for navigation keys")
    }

    private static func testBrowserPlans() {
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .newTab), .keys(combo("t", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .closeTab), .keys(combo("w", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .reopenTab), .keys(combo("t", cmd: true, shift: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .nextTab), .keys(combo("tab", ctrl: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .previousTab), .keys(combo("tab", shift: true, ctrl: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .back), .keys(combo("leftbracket", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .forward), .keys(combo("rightbracket", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .reload), .keys(combo("r", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .find), .keys(combo("f", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .scrollToTop), .keys(combo("up", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .scrollToBottom), .keys(combo("down", cmd: true)))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .scrollDown), .scroll(pixelsDown: RioBrowserKeys.scrollPixels))
        TestSupport.expectEqual(RioBrowserKeys.plan(for: .scrollUp), .scroll(pixelsDown: -RioBrowserKeys.scrollPixels))
        for command in [BrowserCommand.newTab, .closeTab, .reopenTab, .nextTab, .previousTab, .back, .forward, .reload, .scrollDown, .scrollUp, .scrollToTop, .scrollToBottom, .find] {
            if case .keys(let c) = RioBrowserKeys.plan(for: command) {
                TestSupport.expect(RioKeyCombos.isAllowed(c), "\(command) maps to a disallowed key")
            }
            TestSupport.expect(!RioBrowserKeys.summary(for: command).isEmpty, "\(command) needs a summary")
        }
    }

    private static func testBatterySummary() {
        func info(_ p: Int, charging: Bool = false, plugged: Bool = false, full: Bool = false, minutes: Int? = nil) -> BatteryInfo {
            BatteryInfo(percent: p, isCharging: charging, isPluggedIn: plugged, isFullyCharged: full, minutesRemaining: minutes)
        }
        TestSupport.expectEqual(RioBattery.summary(info(64, charging: true, plugged: true, minutes: 60)), "You're at 64%, charging, about 1 hour to full")
        TestSupport.expectEqual(RioBattery.summary(info(21, charging: true, plugged: true, minutes: 111)), "You're at 21%, charging, about 1 hour 51 minutes to full")
        TestSupport.expectEqual(RioBattery.summary(info(64, charging: true, plugged: true)), "You're at 64%, charging")
        TestSupport.expectEqual(RioBattery.summary(info(64, minutes: 125)), "You're at 64% on battery, about 2 hours 5 minutes left")
        TestSupport.expectEqual(RioBattery.summary(info(8, minutes: 45)), "You're at 8% on battery, about 45 minutes left")
        TestSupport.expectEqual(RioBattery.summary(info(50)), "You're at 50% on battery")
        TestSupport.expectEqual(RioBattery.summary(info(100, plugged: true, full: true)), "You're at 100% and fully charged")
        TestSupport.expectEqual(RioBattery.summary(info(80, plugged: true)), "You're at 80%, plugged in and not charging")
        TestSupport.expectEqual(RioBattery.durationPhrase(minutes: 61), "1 hour 1 minute")
        TestSupport.expectEqual(RioBattery.durationPhrase(minutes: 1), "1 minute")
        TestSupport.expectEqual(RioBattery.durationPhrase(minutes: 120), "2 hours")
        TestSupport.expectEqual(RioBattery.noBatteryMessage, "This Mac doesn't have a battery")
    }

    private static func testBatteryFromPowerSource() {
        let charging: [String: Any] = [
            "Type": "InternalBattery", "Current Capacity": 21, "Max Capacity": 100, "Is Charging": true,
            "Power Source State": "AC Power", "Time to Full Charge": 111, "Time to Empty": 0,
        ]
        let parsed = BatteryInfo(powerSource: charging)
        TestSupport.expectEqual(parsed, BatteryInfo(percent: 21, isCharging: true, isPluggedIn: true, isFullyCharged: false, minutesRemaining: 111))
        let onBattery: [String: Any] = [
            "Type": "InternalBattery", "Current Capacity": 45, "Max Capacity": 90, "Is Charging": false,
            "Power Source State": "Battery Power", "Time to Empty": -1,
        ]
        TestSupport.expectEqual(BatteryInfo(powerSource: onBattery), BatteryInfo(percent: 50, isCharging: false, isPluggedIn: false, isFullyCharged: false, minutesRemaining: nil))
        let full: [String: Any] = [
            "Type": "InternalBattery", "Current Capacity": 100, "Max Capacity": 100, "Is Charging": false,
            "Is Charged": true, "Power Source State": "AC Power", "Time to Full Charge": 0,
        ]
        TestSupport.expectEqual(BatteryInfo(powerSource: full)?.isFullyCharged, true)
        TestSupport.expect(BatteryInfo(powerSource: ["Type": "UPS", "Current Capacity": 50, "Max Capacity": 100]) == nil, "UPS is not the battery")
        TestSupport.expect(BatteryInfo(powerSource: ["Type": "InternalBattery", "Current Capacity": 5, "Max Capacity": 0]) == nil, "zero max is garbage")
        TestSupport.expect(BatteryInfo(powerSource: [:]) == nil, "empty is nothing")
    }

    private static func testNetworkSetup() {
        let ports = """
        Hardware Port: Ethernet Adapter (en3)
        Device: en3
        Ethernet Address: 42:31:81:ab:a3:b0

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: c4:35:d9:ad:75:07

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: N/A
        """
        TestSupport.expectEqual(RioNetworkSetup.wifiDevice(fromHardwarePorts: ports), "en0")
        TestSupport.expectEqual(RioNetworkSetup.wifiDevice(fromHardwarePorts: "Hardware Port: AirPort\nDevice: en1\n"), "en1")
        TestSupport.expectEqual(RioNetworkSetup.wifiDevice(fromHardwarePorts: "Hardware Port: Wi-Fi\nDevice: en0; rm\n"), nil)
        TestSupport.expectEqual(RioNetworkSetup.wifiDevice(fromHardwarePorts: "Hardware Port: Wi-Fi\nDevice: bridge0\n"), nil)
        TestSupport.expectEqual(RioNetworkSetup.wifiDevice(fromHardwarePorts: "Hardware Port: Ethernet\nDevice: en3\n"), nil)
        TestSupport.expectEqual(RioNetworkSetup.wifiDevice(fromHardwarePorts: ""), nil)
        TestSupport.expect(RioNetworkSetup.isValidDevice("en0") && RioNetworkSetup.isValidDevice("en12"), "en digits valid")
        for bad in ["", "en", "en0 ", "en0\n", "en0;ls", "eth0", "EN0", "-en0", "en0 on", "../en0"] {
            TestSupport.expect(!RioNetworkSetup.isValidDevice(bad), "\(bad) must be invalid")
        }
        TestSupport.expectEqual(RioNetworkSetup.setPowerArguments(device: "en0", isOn: true), ["-setairportpower", "en0", "on"])
        TestSupport.expectEqual(RioNetworkSetup.setPowerArguments(device: "en0", isOn: false), ["-setairportpower", "en0", "off"])
        TestSupport.expectEqual(RioNetworkSetup.setPowerArguments(device: "en0; reboot", isOn: true), nil)
        TestSupport.expectEqual(RioNetworkSetup.getPowerArguments(device: "en0"), ["-getairportpower", "en0"])
        TestSupport.expectEqual(RioNetworkSetup.getPowerArguments(device: "x"), nil)
        TestSupport.expectEqual(RioNetworkSetup.isPoweredOn(output: "Wi-Fi Power (en0): On\n"), true)
        TestSupport.expectEqual(RioNetworkSetup.isPoweredOn(output: "Wi-Fi Power (en0): Off\n"), false)
        TestSupport.expectEqual(RioNetworkSetup.isPoweredOn(output: "Error: no such device"), nil)
        TestSupport.expectEqual(RioNetworkSetup.listPortsArguments, ["-listallhardwareports"])
        TestSupport.expectEqual(RioNetworkSetup.executablePath, "/usr/sbin/networksetup")
    }

    private static func testBrightnessMath() {
        TestSupport.expectEqual(RioBrightness.percent(fromScalar: 0.405928), 41)
        TestSupport.expectEqual(RioBrightness.percent(fromScalar: 1.4), 100)
        TestSupport.expectEqual(RioBrightness.percent(fromScalar: -1), 0)
        TestSupport.expectApproximatelyEqual(Double(RioBrightness.scalar(fromPercent: 50)), 0.5)
        TestSupport.expectApproximatelyEqual(Double(RioBrightness.scalar(fromPercent: 400)), 1.0)
        TestSupport.expectEqual(RioBrightness.target(after: .up, fromPercent: 41), 51)
        TestSupport.expectEqual(RioBrightness.target(after: .up, fromPercent: 95), 100)
        TestSupport.expectEqual(RioBrightness.target(after: .down, fromPercent: 5), 0)
        TestSupport.expectEqual(RioBrightness.target(after: .set(70), fromPercent: 10), 70)
        TestSupport.expectEqual(RioBrightness.target(after: .set(-10), fromPercent: 10), 0)
        TestSupport.expectEqual(RioBrightness.target(after: .mute, fromPercent: 10), nil)
        TestSupport.expectEqual(RioBrightness.target(after: .unmute, fromPercent: 10), nil)
    }

    private static func testPriorState() {
        let wifi = RioSystemPriorState.toggle(.wifi, wasOn: true)
        TestSupport.expectEqual(wifi.inverseAction, .systemToggle(.wifi, isOn: true))
        TestSupport.expectEqual(RioSystemPriorState.toggle(.darkMode, wasOn: false).inverseAction, .systemToggle(.darkMode, isOn: false))
        TestSupport.expectEqual(RioSystemPriorState.brightness(percent: 41).inverseAction, .brightness(.set(41)))
        TestSupport.expectEqual(RioSystemPriorState.brightness(percent: 300).inverseAction, .brightness(.set(100)))
    }
}
