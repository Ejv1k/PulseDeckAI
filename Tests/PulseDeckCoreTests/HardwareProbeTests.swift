import XCTest
import AVFoundation
import AudioToolbox
import CoreAudio
@testable import PulseDeckCore

/// Manual real-hardware probe. Skipped unless PULSEDECK_HW_PROBE is set:
///   PULSEDECK_HW_PROBE=cue    master on speakers, cue on headphones
///   PULSEDECK_HW_PROBE=master master on headphones, cue on speakers
///   PULSEDECK_HW_OTHER=<name part> uses that device instead of the Mac speakers
///   PULSEDECK_HW_PHONES=<name part> uses that device as the headphones (e.g. Bluetooth cans)
/// Unplug the headphone jack, wait, plug it back in. The probe logs routing for 90 s.
final class HardwareProbeTests: XCTestCase {
    func testHeadphoneUnplugAndReturn() throws {
        guard let scenario = ProcessInfo.processInfo.environment["PULSEDECK_HW_PROBE"] else {
            throw XCTSkip("Set PULSEDECK_HW_PROBE=cue|master to run on real hardware")
        }
        let coordinator = AudioEngineCoordinator()
        let devices = coordinator.enumerateOutputDevices()
        for d in devices { print("PROBE device:", d.name, "|", d.id, "| ch", d.outputChannelCount) }
        let phonesName = ProcessInfo.processInfo.environment["PULSEDECK_HW_PHONES"]
        let headphones = try XCTUnwrap(devices.first { d in
            phonesName.map { d.name.localizedCaseInsensitiveContains($0) }
                ?? (d.name.localizedCaseInsensitiveContains("sluchátka") || d.name.localizedCaseInsensitiveContains("headphones"))
        })
        // PULSEDECK_HW_OTHER=<name part> picks the second device (e.g. a Bluetooth speaker); default: Mac speakers.
        let otherName = ProcessInfo.processInfo.environment["PULSEDECK_HW_OTHER"]
        let speakers = try XCTUnwrap(devices.first { d in
            otherName.map { d.name.localizedCaseInsensitiveContains($0) }
                ?? (d.name.localizedCaseInsensitiveContains("reproduktory") || d.name.localizedCaseInsensitiveContains("speakers"))
        })

        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("probe-tone-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tone) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: tone, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 120))
            buffer.frameLength = buffer.frameCapacity
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                // Quiet 440 Hz pulse, 0.25 s on / 0.25 s off, so dropouts are easy to hear.
                let s: Float = (i / 11025) % 2 == 0 ? Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.05) : 0
                data[0][i] = s; data[1][i] = s
            }
            try file.write(from: buffer)
        }

        let (masterUID, cueUID) = scenario == "master" ? (headphones.id, speakers.id) : (speakers.id, headphones.id)
        try coordinator.setOutputDevice(role: .master, uid: masterUID)
        try coordinator.setOutputDevice(role: .cue, uid: cueUID)
        _ = try coordinator.start(requireCue: false)
        defer { coordinator.stop() }
        let deck = coordinator.deckAGraph
        try deck.loadTrack(url: tone)
        deck.volume = 1
        deck.isCueActive = true
        coordinator.setCrossfader(position: 0)
        deck.play()

        let t0 = Date()
        let stamp: @Sendable () -> String = { String(format: "%5.2fs", Date().timeIntervalSince(t0)) }
        let masterEngine = coordinator.masterAudioEngine.rawEngine
        let cueEngine = coordinator.cueAudioEngine.rawEngine
        let masterID = ObjectIdentifier(masterEngine), cueID = ObjectIdentifier(cueEngine)
        let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { note in
            guard let engine = note.object as? AVAudioEngine else { return }
            let role = ObjectIdentifier(engine) == masterID ? "master" : ObjectIdentifier(engine) == cueID ? "cue" : "other"
            print("PROBE \(stamp()) CONFIG-CHANGE \(role) isRunning=\(engine.isRunning) out=\(engine.outputNode.outputFormat(forBus: 0).sampleRate)Hz")
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let original = coordinator.monitor.onEngineRestarted
        coordinator.monitor.onEngineRestarted = { role in
            print("PROBE \(stamp()) RESTARTED \(role)")
            original?(role)
        }
        func unitDevice(_ engine: AVAudioEngine) -> String {
            guard let unit = engine.outputNode.audioUnit else { return "?" }
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
            guard status == noErr else { return "err\(status)" }
            return devices.first { (try? CoreAudioOutputDevices.deviceID(forUID: $0.id, using: SystemAudioHardware.shared)) == id }?.name ?? "id\(id)"
        }
        func name(_ d: AudioDeviceDescriptor?) -> String { d?.name ?? "NONE" }
        var sawUnplug = false, sawReturn = false, lastLine = ""
        let start = Date()
        while Date().timeIntervalSince(start) < 90 {
            let present = coordinator.enumerateOutputDevices().contains { $0.id == headphones.id }
            if !present { sawUnplug = true }
            if sawUnplug && present { sawReturn = true }
            let line = "jack=\(present ? "in" : "OUT") master=\(name(coordinator.boundDevice(for: .master)))"
                + " running=\(coordinator.masterAudioEngine.rawEngine.isRunning) fallback=\(coordinator.isFallbackActive(for: .master))"
                + " | cue=\(name(coordinator.boundDevice(for: .cue))) running=\(coordinator.cueAudioEngine.rawEngine.isRunning)"
                + " fallback=\(coordinator.isFallbackActive(for: .cue)) | deckPlaying=\(deck.isMasterPlaying) playhead=\(Int(deck.currentMasterPlayheadSeconds()))"
                + " | UNIT m=\(unitDevice(masterEngine)) c=\(unitDevice(cueEngine))"
                + " | nodes m=\(deck.masterPlayerNode.isPlaying) c=\(deck.cuePlayerNode.isPlaying)"
                + " | hw m=\(Int(masterEngine.outputNode.outputFormat(forBus: 0).sampleRate)) c=\(Int(cueEngine.outputNode.outputFormat(forBus: 0).sampleRate))"
                + " mix m=\(Int(masterEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate)) c=\(Int(cueEngine.mainMixerNode.outputFormat(forBus: 0).sampleRate))"
            let state = line.replacingOccurrences(of: #"playhead=\d+"#, with: "", options: .regularExpression)
            let tick = Int(Date().timeIntervalSince(start) * 4)
            if state != lastLine || tick % 4 == 0 { print(String(format: "PROBE t=%5.1fs ", Date().timeIntervalSince(start)) + line); lastLine = state }
            if sawReturn, Date().timeIntervalSince(start) > 15 {
                for _ in 0..<5 {
                    RunLoop.current.run(until: Date().addingTimeInterval(1))
                    print("PROBE after-return: master UNIT=\(unitDevice(masterEngine)) cue UNIT=\(unitDevice(cueEngine)) playhead=\(Int(deck.currentMasterPlayheadSeconds()))")
                }
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        print("PROBE result: unplugSeen=\(sawUnplug) returnSeen=\(sawReturn)")

        // Second gap from the audit: play() on a stopped engine must not crash.
        coordinator.stop()
        deck.play()
        print("PROBE play() on stopped engine: no crash")
    }

    /// Issue #60: does an engine bound to one device follow macOS when the *default* output changes?
    /// PULSEDECK_HW_PROBE=default switches the default output programmatically (no cable needed) and restores it.
    func testEngineStaysOnBoundDeviceWhenDefaultOutputChanges() throws {
        guard ProcessInfo.processInfo.environment["PULSEDECK_HW_PROBE"] == "default" else {
            throw XCTSkip("Set PULSEDECK_HW_PROBE=default to run on real hardware")
        }
        let hal = SystemAudioHardware.shared
        let coordinator = AudioEngineCoordinator()
        let devices = coordinator.enumerateOutputDevices()
        let phonesName = ProcessInfo.processInfo.environment["PULSEDECK_HW_PHONES"]
        let headphones = try XCTUnwrap(devices.first { d in
            phonesName.map { d.name.localizedCaseInsensitiveContains($0) }
                ?? (d.name.localizedCaseInsensitiveContains("sluchátka") || d.name.localizedCaseInsensitiveContains("headphones"))
        })
        let speakers = try XCTUnwrap(devices.first { $0.name.localizedCaseInsensitiveContains("reproduktory") || $0.name.localizedCaseInsensitiveContains("speakers") })
        let headphonesID = try XCTUnwrap(CoreAudioOutputDevices.deviceID(forUID: headphones.id, using: hal))
        let speakersID = try XCTUnwrap(CoreAudioOutputDevices.deviceID(forUID: speakers.id, using: hal))
        let originalDefault = try XCTUnwrap(hal.getDefaultOutputDeviceID())
        func setDefault(_ id: AudioDeviceID) {
            var value = id
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                    UInt32(MemoryLayout<AudioDeviceID>.size), &value)
            print("PROBE set default -> \(id == speakersID ? "speakers" : "headphones") status=\(status)")
        }
        defer { setDefault(originalDefault) }
        func unitDevice(_ engine: AVAudioEngine) -> String {
            guard let unit = engine.outputNode.audioUnit else { return "?" }
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr else { return "err" }
            return id == speakersID ? "speakers" : id == headphonesID ? "headphones" : "id\(id)"
        }

        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("probe-default-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tone) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: tone, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 20))
            buffer.frameLength = buffer.frameCapacity
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(buffer.frameLength) {
                let s: Float = (i / 11025) % 2 == 0 ? Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.03) : 0
                data[0][i] = s; data[1][i] = s
            }
            try file.write(from: buffer)
        }

        setDefault(headphonesID)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try coordinator.setOutputDevice(role: .master, uid: speakers.id)
        try coordinator.setOutputDevice(role: .cue, uid: headphones.id)
        _ = try coordinator.start(requireCue: false)
        defer { coordinator.stop() }
        try coordinator.deckAGraph.loadTrack(url: tone)
        coordinator.deckAGraph.volume = 1
        coordinator.setCrossfader(position: 0)
        coordinator.deckAGraph.play()
        let master = coordinator.masterAudioEngine.rawEngine, cue = coordinator.cueAudioEngine.rawEngine
        func log(_ label: String) {
            print("PROBE \(label): master UNIT=\(unitDevice(master)) bound=\(coordinator.boundDevice(for: .master)?.name ?? "NONE") running=\(master.isRunning) | cue UNIT=\(unitDevice(cue)) running=\(cue.isRunning)")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)); log("start")
        setDefault(speakersID)
        RunLoop.current.run(until: Date().addingTimeInterval(2)); log("default=speakers")
        setDefault(headphonesID)
        RunLoop.current.run(until: Date().addingTimeInterval(2)); log("default=headphones")
        XCTAssertEqual(unitDevice(master), "speakers", "Master must stay on its bound device when the default output changes")
        XCTAssertEqual(unitDevice(cue), "headphones")
    }
}
