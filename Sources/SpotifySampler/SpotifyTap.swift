import AudioToolbox
import CoreAudio
import Foundation

/// Captures Spotify's audio output directly using a Core Audio process tap (macOS 14.2+).
/// Only Spotify's processes are tapped, so other system sounds never end up in your samples,
/// and Spotify keeps playing through your speakers as normal (tap is non-muting).
final class SpotifyTap {
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "sampler.tap.io", qos: .userInteractive)

    private(set) var processes: [AudioObjectID] = []
    private(set) var outputUID = ""
    /// Rate the IO proc actually delivers frames at (the aggregate device's clock).
    private(set) var sampleRate: Double = 0

    var isRunning: Bool { ioProcID != nil }

    /// Creates the tap, asks `makeRing` for a buffer at the tap's sample rate, then starts IO.
    func start(processes: [AudioObjectID], outputUID: String, makeRing: (Double) -> RingBuffer) throws -> RingBuffer {
        stop()
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.uuid = UUID()
            description.name = "Spotify Sampler Tap"
            description.isPrivate = true
            description.muteBehavior = .unmuted

            var tap = AudioObjectID.unknown
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")
            tapID = tap

            let format = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            let tapRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Spotify Sampler",
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
            var agg = AudioObjectID.unknown
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Create aggregate device")
            aggregateID = agg

            // Frames arrive at the aggregate device's rate (its main sub-device, i.e. the output),
            // which can differ from the tap's format rate. Labelling them with the tap rate made
            // samples play back fast and sharp, and threw tempo detection off by the same ratio.
            let deviceRate = deviceSampleRate() ?? tapRate
            sampleRate = deviceRate
            let ring = makeRing(deviceRate)
            var procID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
                ring.write(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
            }, "Create IO proc")
            ioProcID = procID
            try check(AudioDeviceStart(aggregateID, procID), "Start capture")

            self.processes = processes
            self.outputUID = outputUID
            return ring
        } catch {
            stop()
            throw error
        }
    }

    /// The aggregate device's current nominal rate.
    func deviceSampleRate() -> Double? {
        guard aggregateID != .unknown,
              let rate = try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0)),
              rate > 0 else { return nil }
        return rate
    }

    /// False once the output device has switched rate (e.g. a DAW changed it) since capture started.
    var rateIsCurrent: Bool {
        guard let now = deviceSampleRate() else { return true }
        return abs(now - sampleRate) < 1
    }

    func stop() {
        if aggregateID != .unknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
        processes = []
        outputUID = ""
        sampleRate = 0
    }

    deinit { stop() }
}
