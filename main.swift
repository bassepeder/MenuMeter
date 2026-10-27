// MenuMeter — a tiny stereo output level meter for the macOS menu bar.
// Captures everything the Mac plays through a Core Audio process tap (macOS 14.2+).

import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement
import os

// MARK: - Core Audio helpers

private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    return err == noErr ? value : nil
}

private func defaultOutputDevice() -> AudioObjectID? {
    getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(kAudioObjectUnknown))
}

private func deviceUID(_ device: AudioObjectID) -> String? {
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

    func start() {
        queue.async { self.restart() }

        // Rebuild the tap whenever the default output device changes (headphones, AirPods, ...).
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    private func restart() {
        stop()
        guard let output = defaultOutputDevice(), let outputUID = deviceUID(output) else { return }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
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

    static var current: MeterColor {
        get { UserDefaults.standard.string(forKey: "color").flatMap(MeterColor.init) ?? .yellow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "color") }
    }
}

// MARK: - Menu bar view

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

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // let the status button handle clicks

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let track = dark ? NSColor.white.withAlphaComponent(0.88) : NSColor.black.withAlphaComponent(0.18)
            let color = MeterColor.current
            let fill = color.fill(dark: dark)
            // A white peak line disappears against a white/mono fill, so contrast it there.
            let tick = color == .mono ? NSColor.gray : (dark ? NSColor.white : NSColor.black.withAlphaComponent(0.6))
            let hot = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.25, alpha: 1)

            let total = Self.barHeight * 2 + Self.gap
            let top = ((bounds.height - total) / 2).rounded() + Self.verticalOffset
            let x = ((bounds.width - Self.width) / 2).rounded()

            for (i, channel) in channels.enumerated() {
                let y = top + CGFloat(i) * (Self.barHeight + Self.gap)
                let bar = NSRect(x: x, y: y, width: Self.barWidth, height: Self.barHeight)
                let radius = Self.barHeight / 2

                track.setFill()
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()
                let filled = Self.barWidth * CGFloat(channel.level)
                if filled > 0 {
                    // Turns orange/red over the top 6 dB, like a hot signal should.
                    let gradient = NSGradient(colorsAndLocations:
                        (fill, 0), (fill, 0.9), (hot, 1.0))!
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: x, y: y, width: filled, height: Self.barHeight)).addClip()
                    gradient.draw(in: bar, angle: 0)
                    NSGraphicsContext.restoreGraphicsState()
                }
                if channel.hold > 0.02 {
                    tick.setFill()
                    let hx = x + Self.barWidth * CGFloat(channel.hold) - 1.5
                    NSRect(x: max(x, hx), y: y, width: 1.5, height: Self.barHeight).fill()
                }
                NSGraphicsContext.restoreGraphicsState()

                // Clip indicator dot.
                (channel.clipped(now) ? hot : track).setFill()
                let dot = NSRect(x: x + Self.barWidth + Self.dotSpacing, y: y, width: Self.dot, height: Self.barHeight)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tap = SystemAudioTap()
    private var statusItem: NSStatusItem!
    private let meter = MeterView()
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
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MenuMeter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        tap.start()

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
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
        meter.needsDisplay = true
    }

    @objc private func chooseColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let color = MeterColor(rawValue: raw) else { return }
        MeterColor.current = color
        meter.needsDisplay = true
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
        menu.items.first?.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
