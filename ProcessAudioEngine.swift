import Foundation
import CoreAudio
import AudioToolbox

// Owned by the serial control queue. The real-time IOProc only sees MixerDSP.
final class ProcessAudioEngine {
    // Stores Core Audio process tap assigned to this engine
    private var tapID: AudioObjectID = 0
    // Stores the aggregate device used to access captured audio
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    let processes: [AudioObjectID]
    let route: OutputRoute
    let rendering: Bool
    let started = ProcessInfo.processInfo.systemUptime
    var lastCalls: UInt32 = 0
    var lastCallbackTime = ProcessInfo.processInfo.systemUptime
    var meter: MixerMeter { dsp.map { MixerRead($0) } ?? MixerMeter() }

    init(processes: [AudioObjectID], route: OutputRoute, rendering: Bool) {
        self.processes = processes
        self.route = route
        self.rendering = rendering
    }

    func setVolume(_ gain: Float) {
        if let dsp { MixerGain(dsp, gain) }
    }

    func start(gain: Float) throws {
        let tap = CATapDescription(processes: processes, deviceUID: route.uid, stream: 0)
        tap.name = "Volume Mixer"
        tap.isPrivate = true
        tap.muteBehavior = rendering ? .mutedWhenTapped : .unmuted
        try HAL.check(AudioHardwareCreateProcessTap(tap, &tapID), "Create process tap")
        let uid = try HAL.string(tapID, kAudioTapPropertyUID)
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "Volume Mixer • \(route.name)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: route.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: route.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]]
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateDeviceID),
                      "Create private aggregate")
        // HAL publishes aggregate streams asynchronously. Wait off the UI thread.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var layout: (UInt32, UInt32, UInt32, UInt32, UInt32)?
        var reason = "Waiting for aggregate device."
        repeat {
            do {
                layout = try inspectLayout()
                break
            } catch {
                reason = error.localizedDescription
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let (offset, inputs, outputs, physicalStreams, totalStreams) = layout else { throw MixerError(reason) }
        guard let state = MixerCreate(offset, inputs, route.channels, outputs, gain, route.rate, rendering)
        else { throw MixerError("Could not allocate render state.") }
        dsp = state
        try HAL.check(
            AudioDeviceCreateIOProcID(
                aggregateDeviceID,
                { device, now, input, inputTime, output, outputTime, context in
                    return MixerIO(
                        device,
                        now,
                        input,
                        inputTime,
                        output,
                        outputTime,
                        context
                    )
                },
                UnsafeMutableRawPointer(state),
                &ioProcID
            ),
            "Register audio callback"
        )
        guard let ioProcID else { throw MixerError("Missing IOProc.") }
        try HAL.check(MixerDisableHardwareInputs(aggregateDeviceID, ioProcID, physicalStreams, totalStreams),
                      "Disable hardware inputs")
        try HAL.check(AudioDeviceStart(aggregateDeviceID, ioProcID), "Start audio device")
    }

    private func inspectLayout() throws -> (UInt32, UInt32, UInt32, UInt32, UInt32) {
        let input = kAudioObjectPropertyScopeInput, output = kAudioObjectPropertyScopeOutput
        let alive = try HAL.read(aggregateDeviceID, kAudioDevicePropertyDeviceIsAlive, UInt32(0))
        let physical = try HAL.ids(route.id, kAudioDevicePropertyStreams, scope: input)
        let ins = try HAL.ids(aggregateDeviceID, kAudioDevicePropertyStreams, scope: input)
        let outs = try HAL.ids(aggregateDeviceID, kAudioDevicePropertyStreams, scope: output)
        guard alive != 0, ins.count == physical.count + 1, let stream = ins.last, outs.count == 1 else {
            throw MixerError("Aggregate streams unavailable or unsupported.")
        }
        let formats = try [HAL.read(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription()),
                           HAL.read(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()),
                           HAL.read(outs[0], kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())]
        for f in formats {
            let flags = f.mFormatFlags
            let planar = flags & kAudioFormatFlagIsNonInterleaved != 0
            guard f.mFormatID == kAudioFormatLinearPCM, flags & kAudioFormatFlagIsFloat != 0,
                  flags & kAudioFormatFlagIsBigEndian == 0, f.mBitsPerChannel == 32,
                  (1...2).contains(route.channels), f.mChannelsPerFrame == route.channels,
                  f.mBytesPerFrame == 4 * (planar ? 1 : route.channels),
                  route.rate > 0, f.mSampleRate == route.rate else {
                throw MixerError("Requires matching mono/stereo Float32 streams. Found \(f.mSampleRate) Hz, \(f.mChannelsPerFrame) ch, flags \(flags).")
            }
        }
        let offset = MixerBufferCount(route.id, input)
        let count = MixerBufferCount(aggregateDeviceID, input) - offset
        let out = MixerBufferCount(aggregateDeviceID, output)
        guard offset >= 0, count == 1 || count == Int32(route.channels),
              out == 1 || out == Int32(route.channels) else { throw MixerError("Unsupported aggregate buffer layout.") }
        return (UInt32(offset), UInt32(count), UInt32(out), UInt32(physical.count), UInt32(ins.count))
    }

    // Stops audio capture and releases Core Audio resources in reverse order.
    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if status != noErr {
                // Retain callback storage until aggregate destruction invalidates the IOProc.
                NSLog("Volume Mixer: destroy IOProc returned %d", status)
            }
            if status == noErr { self.ioProcID = nil }
        }
        if aggregateDeviceID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status == noErr { aggregateDeviceID = 0; ioProcID = nil }
            else { NSLog("Volume Mixer: destroy aggregate returned %d", status) }
        }
        if ioProcID == nil, let dsp { MixerFree(dsp); self.dsp = nil }
        if tapID != 0 {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr { tapID = 0 }
            else { NSLog("Volume Mixer: destroy tap returned %d", status) }
        }
    }
    deinit { stop() }
}
