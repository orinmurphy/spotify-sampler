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
            let sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000

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

            let ring = makeRing(sampleRate)
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
    }

    deinit { stop() }
}
