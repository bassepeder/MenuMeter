// Per-app volume: finds the apps that are playing sound, and plays an app at a chosen volume by
// tapping its audio (which mutes its normal output) and playing the tapped audio back, scaled.

import AppKit
import CoreAudio
import os

// MARK: - Apps that use audio

/// An app the user knows, with every process it plays sound from (browsers use helper processes).
struct AudioApp {
    let key: String          // bundle ID, or the executable path for command-line tools
    let name: String
    let ownerPID: pid_t
    var processes: [AudioObjectID]
    var isPlaying: Bool

    var icon: NSImage {
        NSRunningApplication(processIdentifier: ownerPID)?.icon
            ?? NSWorkspace.shared.icon(forFile: key.hasPrefix("/") ? key : "/bin/sh")
    }
}

enum AudioApps {
    /// Every app with an audio process, playing or not, excluding MenuMeter itself.
    static func current() -> [AudioApp] {
        var apps: [String: AudioApp] = [:]
        var order: [String] = []
        for object in processObjects() {
            guard let pid = getProperty(object, kAudioProcessPropertyPID, pid_t(0)), pid > 0,
                  let owner = owner(of: pid), owner.pid != getpid() else { continue }
            let playing = getProperty(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1
            if apps[owner.key] == nil {
                apps[owner.key] = AudioApp(key: owner.key, name: owner.name, ownerPID: owner.pid, processes: [], isPlaying: false)
                order.append(owner.key)
            }
            apps[owner.key]!.processes.append(object)
            apps[owner.key]!.isPlaying = apps[owner.key]!.isPlaying || playing
        }
        return order.map { key in
            var app = apps[key]!
            app.processes.sort()
            return app
        }
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// The app a process belongs to: the process macOS holds responsible for it (Chrome for its
    /// helpers, Safari for WebKit's audio process), or the process itself.
    private static func owner(of pid: pid_t) -> (key: String, name: String, pid: pid_t)? {
        for candidate in [responsiblePID?(pid) ?? pid, pid] {
            if let app = NSRunningApplication(processIdentifier: candidate),
               let id = app.bundleIdentifier, let name = app.localizedName {
                return (id, name, candidate)
            }
        }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        return (executable, (executable as NSString).lastPathComponent, pid)
    }

    private static let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()
}

// MARK: - One app's volume

/// Plays one app at a chosen volume. Tapping the app's processes mutes their normal output; the
/// tapped audio is played to the output device here instead, scaled. Stopping unmutes them.
final class AppVolumeTap {
    let processes: [AudioObjectID]
    private let target: OSAllocatedUnfairLock<Float>
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// The gain actually applied, eased towards `target` across each buffer to avoid clicks.
    private final class Ramp { var gain: Float = 1 }

    init?(processes: [AudioObjectID], outputUID: String, volume: Float) {
        self.processes = processes
        target = OSAllocatedUnfairLock(initialState: volume)

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            NSLog("MenuMeter: could not create volume tap")
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MenuMeter Volume",
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
            NSLog("MenuMeter: could not create volume device")
            stop()
            return nil
        }

        let target = self.target
        let ramp = Ramp()
        ramp.gain = volume
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            // The tap's stereo mixdown is the last two input channels of the aggregate.
            var left: UnsafePointer<Float>?, right: UnsafePointer<Float>?
            var leftStride = 1, rightStride = 1, frames = Int.max
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let stride = max(Int(buffer.mNumberChannels), 1)
                frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride))
                let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                for channel in 0..<stride {
                    (left, leftStride) = (right, rightStride)
                    (right, rightStride) = (samples + channel, stride)
                }
            }

            let outputs = UnsafeMutableAudioBufferListPointer(output)
            for buffer in outputs where buffer.mData != nil {
                memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
            }
            let goal = target.withLock { $0 }
            defer { ramp.gain = goal }
            guard let right, frames != Int.max, frames > 0 else { return }
            let sources = [(left ?? right, left == nil ? rightStride : leftStride), (right, rightStride)]
            let step = (goal - ramp.gain) / Float(frames)

            var channelIndex = 0
            for buffer in outputs {
                let stride = max(Int(buffer.mNumberChannels), 1)
                defer { channelIndex += stride }
                guard let data = buffer.mData else { continue }
                let out = data.assumingMemoryBound(to: Float.self)
                let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride))
                for channel in 0..<stride where channelIndex + channel < 2 {
                    let (source, sourceStride) = sources[channelIndex + channel]
                    var gain = ramp.gain
                    for frame in 0..<count {
                        out[frame * stride + channel] = source[frame * sourceStride] * gain
                        gain += step
                    }
                }
            }
        }
        guard err == noErr, AudioDeviceStart(aggregateID, procID) == noErr else {
            NSLog("MenuMeter: could not start volume playback")
            stop()
            return nil
        }
    }

    func setVolume(_ volume: Float) {
        target.withLock { $0 = volume }
    }

    func stop() {
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

// MARK: - All apps' volumes

/// Remembers a volume per app and keeps a volume tap running for every open app that isn't at 100%.
final class AppVolumes {
    /// Called with every tapped process whenever that set changes, so the meter can leave out
    /// those apps' original (muted) audio and count the scaled copy instead.
    var tappedProcessesChanged: (([AudioObjectID]) -> Void)?

    private var taps: [String: AppVolumeTap] = [:]
    private let queue = DispatchQueue(label: "menumeter.volumes")
    private var listeners: [AudioObjectPropertyListenerBlock] = []

    /// Volumes at or above this count as 100%, which leaves the app untouched.
    static let full: Float = 0.995

    static func volume(for key: String) -> Float {
        Float(UserDefaults.standard.dictionary(forKey: "volumes")?[key] as? Double ?? 1)
    }

    func start() {
        // Apps start and stop using audio, and the output device changes (headphones, AirPods, ...).
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let rebuild = selector == kAudioHardwarePropertyDefaultSystemOutputDevice
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sync(rebuild: rebuild) }
            listeners.append(block)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        queue.async { self.sync() }
    }

    func setVolume(_ volume: Float, for key: String) {
        var volumes = UserDefaults.standard.dictionary(forKey: "volumes") ?? [:]
        volumes[key] = volume >= Self.full ? nil : Double(volume)
        UserDefaults.standard.set(volumes, forKey: "volumes")
        queue.async {
            if volume < Self.full, let tap = self.taps[key] {
                tap.setVolume(volume)
            } else {
                self.sync()
            }
        }
    }

    private func sync(rebuild: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        var changed = false
        if rebuild {
            taps.values.forEach { $0.stop() }
            changed = !taps.isEmpty
            taps = [:]
        }
        let apps = Dictionary(AudioApps.current().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, tap) in taps where apps[key]?.processes != tap.processes || Self.volume(for: key) >= Self.full {
            tap.stop()
            taps[key] = nil
            changed = true
        }
        if let outputUID = defaultOutputDevice().flatMap(deviceUID) {
            for (key, app) in apps where taps[key] == nil {
                let volume = Self.volume(for: key)
                guard volume < Self.full,
                      let tap = AppVolumeTap(processes: app.processes, outputUID: outputUID, volume: volume) else { continue }
                taps[key] = tap
                changed = true
            }
        }
        if changed { tappedProcessesChanged?(taps.values.flatMap(\.processes)) }
    }
}
