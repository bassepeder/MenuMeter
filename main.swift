// MenuMeter — a tiny stereo output level meter for the macOS menu bar.
// Captures everything the Mac plays through a Core Audio process tap (macOS 14.2+).

import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement
import os

// MARK: - Core Audio helpers

func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return err == noErr ? value : nil
}

func defaultOutputDevice() -> AudioObjectID? {
    getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(kAudioObjectUnknown))
}

func deviceUID(_ device: AudioObjectID) -> String? {
    getProperty(device, kAudioDevicePropertyDeviceUID, CFString?.none).flatMap { $0 as String? }
}

// MARK: - System audio tap

/// Peak amplitude per channel since the last read, written on the audio thread.
struct Peaks { var left: Float = 0; var right: Float = 0 }

final class SystemAudioTap {
    let peaks = OSAllocatedUnfairLock(initialState: Peaks())

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "menumeter.tap")
    private var listener: AudioObjectPropertyListenerBlock?
    private var excluded: [AudioObjectID] = []

    func start() {
        queue.async { self.restart() }

        // Rebuild the tap whenever the default output device changes (headphones, AirPods, ...).
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    /// Leaves these processes out of the meter. Apps whose volume MenuMeter controls are muted and
    /// replayed by MenuMeter, so their original audio would otherwise be counted on top of the copy.
    func exclude(_ processes: [AudioObjectID]) {
        queue.async {
            guard processes.sorted() != self.excluded else { return }
            self.excluded = processes.sorted()
            self.restart()
        }
    }

    private func restart() {
        stop()
        guard let output = defaultOutputDevice(), let outputUID = deviceUID(output) else { return }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            NSLog("MenuMeter: could not create process tap")
            return
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MenuMeter Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            NSLog("MenuMeter: could not create aggregate device")
            stop()
            return
        }

        let peaks = self.peaks
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, _, _ in
            // The tap's stereo mixdown is the last two input channels of the aggregate.
            var previous: Float = 0, last: Float = 0, channels = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let stride = max(Int(buffer.mNumberChannels), 1)
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<stride {
                    var peak: Float = 0
                    var i = channel
                    for _ in 0..<frames {
                        peak = max(peak, abs(samples[i]))
                        i += stride
                    }
                    previous = last
                    last = peak
                    channels += 1
                }
            }
            let left = channels >= 2 ? previous : last
            let right = last
            peaks.withLock {
                $0.left = max($0.left, left)
                $0.right = max($0.right, right)
            }
        }
        guard err == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            NSLog("MenuMeter: could not start audio IO")
            stop()
            return
        }
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - Meter ballistics

/// One channel's displayed state: fast attack, smooth release, peak hold and clip latch.
struct Channel {
    static let floorDB: Float = -40

    var level: Float = 0       // 0...1 on the dB scale
    var hold: Float = 0
    var holdUntil: TimeInterval = 0
    var clipUntil: TimeInterval = 0

    mutating func update(peak: Float, now: TimeInterval, dt: Float) {
        let db = 20 * log10(max(peak, 1e-6))
        let target = max(0, min(1, (db - Self.floorDB) / -Self.floorDB))
        // Release at ~24 dB per second.
        level = max(target, level - dt * 24 / -Self.floorDB)
        if level >= hold || now > holdUntil {
            hold = level
            holdUntil = now + 1.2
        }
        if peak >= 0.999 { clipUntil = now + 2 }
    }

    func clipped(_ now: TimeInterval) -> Bool { now < clipUntil }
}

// MARK: - Colors

enum MeterColor: String, CaseIterable {
    case yellow, green, blue, pink, accent, mono

    var title: String {
        switch self {
        case .accent: "Accent Color"
        case .mono: "Monochrome"
        default: rawValue.capitalized
        }
    }

    /// Fill color for a dark menu bar and for a light one.
    func fill(dark: Bool) -> NSColor {
        switch self {
        case .yellow: dark ? NSColor(srgbRed: 0.97, green: 0.88, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.58, blue: 0.0, alpha: 1)
        case .green: dark ? NSColor(srgbRed: 0.45, green: 0.95, blue: 0.45, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.62, blue: 0.20, alpha: 1)
        case .blue: dark ? NSColor(srgbRed: 0.45, green: 0.80, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.05, green: 0.45, blue: 0.90, alpha: 1)
        case .pink: dark ? NSColor(srgbRed: 1.0, green: 0.55, blue: 0.80, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.20, blue: 0.55, alpha: 1)
        case .accent: .controlAccentColor
        case .mono: dark ? .white : .black
        }
    }

    /// The fill with the user's saturation and brightness applied.
    func adjustedFill(dark: Bool) -> NSColor {
        let base = fill(dark: dark)
        guard let rgb = base.usingColorSpace(.sRGB) else { return base }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(colorSpace: .sRGB, hue: hue,
                       saturation: min(1, saturation * Self.saturation),
                       brightness: min(1, brightness * Self.brightness), alpha: alpha)
    }

    static var current: MeterColor {
        get { UserDefaults.standard.string(forKey: "color").flatMap(MeterColor.init) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "color") }
    }

    /// Multipliers for the fill's saturation and brightness; 1 leaves the colour as designed.
    static var saturation: CGFloat {
        get { UserDefaults.standard.object(forKey: "saturation") as? CGFloat ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "saturation") }
    }

    static var brightness: CGFloat {
        get { UserDefaults.standard.object(forKey: "brightness") as? CGFloat ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "brightness") }
    }
}

// MARK: - Menu bar view

/// Draws the meter with Core Animation layers. Moving layers is nearly free, whereas redrawing
/// the view makes AppKit CPU-render a copy of the menu bar item for every replica it keeps
/// (other displays, other menu bar states). Replicas are refreshed separately, see `AppDelegate`.
final class MeterView: NSView {
    var channels = [Channel(), Channel()]
    var now: TimeInterval = 0

    static let barWidth: CGFloat = 38
    static let barHeight: CGFloat = 5.5
    static let gap: CGFloat = 4.5
    static let dot: CGFloat = 5.5
    static let dotSpacing: CGFloat = 3
    static let verticalOffset: CGFloat = 1.5 // nudge down to line up with Audio Hijack's meter
    static let width = barWidth + dotSpacing + dot

    private struct Bar {
        let track = CALayer()               // rounded background, clips everything inside it
        let fill = CALayer()                // cut to the current level
        let gradient = CAGradientLayer()    // spans the whole bar, so colours stay put as the level moves
        let tick = CALayer()                // peak hold
        let dot = CALayer()                 // clip light
    }
    private let bars = [Bar(), Bar()]

    /// What's currently on screen, in half-point steps, so unchanged frames can be skipped.
    private(set) var drawn: [Int] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            bar.track.cornerRadius = Self.barHeight / 2
            bar.track.masksToBounds = true
            bar.fill.masksToBounds = true
            bar.gradient.startPoint = CGPoint(x: 0, y: 0.5)
            bar.gradient.endPoint = CGPoint(x: 1, y: 0.5)
            bar.gradient.locations = [0, 0.9, 1] // turns orange/red over the top 4 dB
            bar.dot.cornerRadius = Self.dot / 2
            bar.fill.addSublayer(bar.gradient)
            bar.track.addSublayer(bar.fill)
            bar.track.addSublayer(bar.tick)
            layer?.addSublayer(bar.track)
            layer?.addSublayer(bar.dot)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func snapshot() -> [Int] {
        channels.flatMap { channel in [
            Int((CGFloat(channel.level) * Self.barWidth * 2).rounded()),
            channel.hold > 0.02 ? Int((CGFloat(channel.hold) * Self.barWidth * 2).rounded()) : 0,
            channel.clipped(now) ? 1 : 0,
        ] }
    }

    /// True when the meter shows nothing and has nothing left to animate.
    var isSettled: Bool { drawn.allSatisfy { $0 == 0 } && snapshot() == drawn }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // let the status button handle clicks

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        update()
    }

    // Runs when the view is marked for display, which is also what refreshes the replicas.
    override func updateLayer() {
        update()
    }

    /// Moves the layers to match `channels`. Cheap: no drawing, and replicas are left alone.
    func update() {
        drawn = snapshot()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let track = dark ? NSColor.white.withAlphaComponent(0.88) : NSColor.black.withAlphaComponent(0.18)
            let color = MeterColor.current
            let fill = color.adjustedFill(dark: dark)
            // A white peak line disappears against a white/mono fill, so contrast it there.
            let tick = color == .mono ? NSColor.gray : (dark ? NSColor.white : NSColor.black.withAlphaComponent(0.6))
            let hot = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.25, alpha: 1)

            let total = Self.barHeight * 2 + Self.gap
            let top = ((bounds.height - total) / 2).rounded() + Self.verticalOffset
            let x = ((bounds.width - Self.width) / 2).rounded()

            for (i, (bar, channel)) in zip(bars, channels).enumerated() {
                let y = top + CGFloat(i) * (Self.barHeight + Self.gap)
                bar.track.frame = NSRect(x: x, y: y, width: Self.barWidth, height: Self.barHeight)
                bar.track.backgroundColor = track.cgColor
                bar.fill.frame = NSRect(x: 0, y: 0, width: Self.barWidth * CGFloat(channel.level), height: Self.barHeight)
                bar.gradient.frame = NSRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight)
                bar.gradient.colors = [fill.cgColor, fill.cgColor, hot.cgColor]
                bar.tick.isHidden = channel.hold <= 0.02
                bar.tick.frame = NSRect(x: max(0, Self.barWidth * CGFloat(channel.hold) - 1.5), y: 0, width: 1.5, height: Self.barHeight)
                bar.tick.backgroundColor = tick.cgColor
                bar.dot.frame = NSRect(x: x + Self.barWidth + Self.dotSpacing, y: y, width: Self.dot, height: Self.barHeight)
                bar.dot.backgroundColor = (channel.clipped(now) ? hot : track).cgColor
            }
        }
        CATransaction.commit()
    }
}

// MARK: - Menu rows

/// A menu row with an optional icon, a title, a slider and its value in percent.
final class SliderRow: NSView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (Double) -> Void

    init(title: String, icon: NSImage? = nil, value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 26))

        var x: CGFloat = 20
        if let icon {
            let image = NSImageView(frame: NSRect(x: x, y: 5, width: 16, height: 16))
            image.image = icon
            addSubview(image)
            x += 22
        }
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: x, y: 4, width: 150 - x, height: 17)
        addSubview(label)

        slider.frame = NSRect(x: 154, y: 3, width: 106, height: 20)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        addSubview(slider)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 264, y: 5, width: 38, height: 15)
        addSubview(valueLabel)
        showValue()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setValue(_ value: Double) {
        slider.doubleValue = value
        showValue()
    }

    @objc private func changed() {
        showValue()
        onChange(slider.doubleValue)
    }

    private func showValue() {
        valueLabel.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tap = SystemAudioTap()
    private let volumes = AppVolumes()
    private var appRows: [NSMenuItem] = []     // the per-app volume section, rebuilt each time the menu opens
    private var colorSliders: [SliderRow] = []
    private var statusItem: NSStatusItem!
    private let meter = MeterView(frame: .zero)
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: MeterView.width + 8)
        if let button = statusItem.button {
            meter.frame = button.bounds
            meter.autoresizingMask = [.width, .height]
            button.addSubview(meter)
        }

        let menu = NSMenu()
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let colors = NSMenu()
        for color in MeterColor.allCases {
            let item = NSMenuItem(title: color.title, action: #selector(chooseColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            colors.addItem(item)
        }
        colors.addItem(.separator())
        let saturation = SliderRow(title: "Saturation", value: MeterColor.saturation, range: 0...1.5) { [weak self] value in
            MeterColor.saturation = value
            self?.meter.needsDisplay = true
        }
        let brightness = SliderRow(title: "Brightness", value: MeterColor.brightness, range: 0.4...1.2) { [weak self] value in
            MeterColor.brightness = value
            self?.meter.needsDisplay = true
        }
        colorSliders = [saturation, brightness]
        for row in colorSliders {
            let item = NSMenuItem()
            item.view = row
            colors.addItem(item)
        }
        let reset = NSMenuItem(title: "Reset Saturation and Brightness", action: #selector(resetColorTweaks), keyEquivalent: "")
        reset.target = self
        colors.addItem(reset)
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        let smooth = NSMenuItem(title: "Smooth Animation (60 fps)", action: #selector(toggleSmooth(_:)), keyEquivalent: "")
        smooth.target = self
        menu.addItem(smooth)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MenuMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        volumes.tappedProcessesChanged = { [tap] processes in tap.exclude(processes) }
        tap.start()
        volumes.start()
        setFrameRate(Self.activeRate)
    }

    // Animate at full rate while there's sound; poll slowly while silent.
    private static var activeRate: Double { UserDefaults.standard.bool(forKey: "smooth") ? 60 : 30 }
    private static let idleRate: Double = 10

    private func setFrameRate(_ rate: Double) {
        guard timer?.timeInterval != 1 / rate else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(now - lastTick)
        lastTick = now
        let peaks = tap.peaks.withLock { current in
            defer { current = Peaks() }
            return current
        }
        meter.channels[0].update(peak: peaks.left, now: now, dt: dt)
        meter.channels[1].update(peak: peaks.right, now: now, dt: dt)
        meter.now = now
        if meter.snapshot() != meter.drawn {
            meter.update()
            refreshReplicasIfDue(now)
        }
        let silent = max(peaks.left, peaks.right) < 0.01 // below the meter's −40 dB floor
        setFrameRate(silent && meter.isSettled ? Self.idleRate : Self.activeRate)
    }

    // Replicas of the menu bar item (on other displays, for example) only change when the view
    // redraws, and each redraw CPU-renders all of them. Refresh them at 10 fps while one is on a
    // screen, otherwise once a second, plus once when the meter falls silent so none is left stale.
    private var replicasOnScreen = false
    private var lastReplicaCheck: TimeInterval = 0
    private var lastReplicaRefresh: TimeInterval = 0

    private func refreshReplicasIfDue(_ now: TimeInterval) {
        if now - lastReplicaCheck >= 1 {
            lastReplicaCheck = now
            let main = statusItem.button?.window
            replicasOnScreen = NSApp.windows.contains { window in
                window !== main && NSStringFromClass(type(of: window)) == "NSStatusBarWindow"
                    && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
            }
        }
        let interval: TimeInterval = replicasOnScreen ? 0.1 : 1
        if now - lastReplicaRefresh >= interval || meter.drawn.allSatisfy({ $0 == 0 }) {
            lastReplicaRefresh = now
            meter.needsDisplay = true
        }
    }

    @objc private func chooseColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let color = MeterColor(rawValue: raw) else { return }
        MeterColor.current = color
        meter.needsDisplay = true
    }

    @objc private func resetColorTweaks() {
        MeterColor.saturation = 1
        MeterColor.brightness = 1
        colorSliders.forEach { $0.setValue(1) }
        meter.needsDisplay = true
    }

    /// Puts a volume slider at the top of the menu for each app that's playing sound right now.
    private func rebuildAppRows(in menu: NSMenu) {
        appRows.forEach(menu.removeItem)
        appRows = [NSMenuItem.sectionHeader(title: "Volume")]
        let playing = AudioApps.current().filter(\.isPlaying)
        if playing.isEmpty {
            let none = NSMenuItem(title: "No apps are playing", action: nil, keyEquivalent: "")
            none.isEnabled = false
            appRows.append(none)
        }
        for app in playing {
            let item = NSMenuItem()
            let key = app.key
            item.view = SliderRow(title: app.name, icon: app.icon, value: Double(AppVolumes.volume(for: key)), range: 0...1) { [weak self] value in
                self?.volumes.setVolume(Float(value), for: key)
            }
            appRows.append(item)
        }
        appRows.append(.separator())
        for (index, item) in appRows.enumerated() { menu.insertItem(item, at: index) }
    }

    @objc private func toggleSmooth(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "smooth"), forKey: "smooth")
        setFrameRate(Self.activeRate)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MenuMeter: login item change failed: \(error)")
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildAppRows(in: menu)
        menu.items.first { $0.action == #selector(toggleLogin(_:)) }?.state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        menu.items.first { $0.action == #selector(toggleSmooth(_:)) }?.state =
            UserDefaults.standard.bool(forKey: "smooth") ? .on : .off
        let current = MeterColor.current.rawValue
        for item in menu.items.compactMap(\.submenu).flatMap(\.items) {
            item.state = item.representedObject as? String == current ? .on : .off
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
