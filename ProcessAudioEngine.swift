
import Foundation
import CoreAudio
import AudioToolbox
import os

final class ProcessAudioEngine {

    // Stores Core Audio process tap assigned to this engine
    private var tapID: AudioObjectID = 0

    // Stores the aggregate device used to access captured audio
    private var aggregateDeviceID: AudioObjectID = 0

    // Stores audio callback connected with Core Audio
    private var ioProcID: AudioDeviceIOProcID?

    // Stores Core Audio process IDs that engine captures
    private var processIDs: [AudioObjectID] = []

    // Tracks if audio engine is currently running
    private(set) var isRunning = false
    
    // Counts how many times Core Audio delivers audio buffers
    private let callbackCount = OSAllocatedUnfairLock(initialState: 0)

    // Controls the gain we eventually apply to captured samples
    // This is not connected to audible output yet
    private var volume: Float = 1.0

    // Starts capturing audio from the supplied application processes
    func start(processIDs: [AudioObjectID]) throws {
        guard !isRunning else { return }

        guard !processIDs.isEmpty else {
            throw AudioEngineError.noProcesses
        }

        self.processIDs = processIDs

        do {
            try createTap()
            try createAggregateDevice()
            try startAudioCallback()
            isRunning = true
            print("Audio capture engine started")
        } catch {
            stop()
            throw error
        }
    }

    // Updates volume value used by our future processing pipeline
    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
    }

    // Creates tap that captures audio from selected processes
    private func createTap() throws {
        let description = CATapDescription(
            stereoMixdownOfProcesses: processIDs
        )

        // Leave the application's normal playback unchanged during capture testing
        description.muteBehavior = .unmuted

        let status = AudioHardwareCreateProcessTap(
            description,
            &tapID
        )

        guard status == noErr else {
            throw AudioEngineError.coreAudioFailure(
                operation: "Create process tap",
                status: status
            )
        }

        print("Created process tap: \(tapID)")
    }

    private func createAggregateDevice() throws {
        guard tapID != 0 else {
            throw AudioEngineError.noTap
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var tapUID: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let uidStatus = withUnsafeMutablePointer(to: &tapUID) { pointer in
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }

        guard uidStatus == noErr else {
            throw AudioEngineError.coreAudioFailure(
                operation: "Read tap UID",
                status: uidStatus
            )
        }

        let aggregateUID = UUID().uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volume Mixer Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateDeviceID
        )

        guard status == noErr else {
            throw AudioEngineError.coreAudioFailure(
                operation: "Create aggregate device",
                status: status
            )
        }

        print("Created aggregate device: \(aggregateDeviceID)")
    }

    // Registers callback that Core Audio uses with captured audio buffers
    private func startAudioCallback() throws {
        guard aggregateDeviceID != 0 else {
            throw AudioEngineError.noAggregateDevice
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            DispatchQueue(label: "com.volumemixer.audio", qos: .userInteractive)
        ) { _, inputData, _, _, _ in

            // The input buffers contain captured audio samples
            // This callback should not perform UI updates or heavy work
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            
            self.callbackCount.withLock { count in
                count += 1
            }

            for buffer in buffers {
                // Checks whether Core Audio provided actual audio data
                if buffer.mDataByteSize > 0 && buffer.mData != nil {
                    // Counts the number of bytes received from the audio tap
                    // Avoids printing continuously inside the audio callback
                    _ = buffer.mDataByteSize
                }
            }
        }

        guard status == noErr else {
            throw AudioEngineError.coreAudioFailure(
                operation: "Create audio callback",
                status: status
            )
        }

        let startStatus = AudioDeviceStart(
            aggregateDeviceID,
            ioProcID
        )

        guard startStatus == noErr else {
            throw AudioEngineError.coreAudioFailure(
                operation: "Start audio device",
                status: startStatus
            )
        }
    }

    // Stops audio capture and releases Core Audio resources
    func stop() {
        if aggregateDeviceID != 0 {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }

            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }

        processIDs.removeAll()
        isRunning = false

        print("Audio capture engine stopped")
    }
    
    // Returns the number of audio callbacks received
    func getCallbackCount() -> Int {
        callbackCount.withLock { $0 }
    }

    deinit {
        stop()
    }
}

// Describes errors encountered while configuring Core Audio
enum AudioEngineError: LocalizedError {
    case noProcesses
    case noTap
    case noAggregateDevice
    case coreAudioFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noProcesses:
            return "No audio processes were provided."
        case .noTap:
            return "A process tap has not been created."
        case .noAggregateDevice:
            return "An aggregate audio device has not been created."
        case let .coreAudioFailure(operation, status):
            return "\(operation) failed with Core Audio status \(status)."
        }
    }
}
