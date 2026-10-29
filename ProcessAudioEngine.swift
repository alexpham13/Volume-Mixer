
import Foundation
import CoreAudio

// Handles audio capture and processing separately from the UI
final class ProcessAudioEngine {

    // Stores Core Audio process tap assigned to this engine
    private var tapID: AudioObjectID = 0
    
    // Stores Core Audio process IDs that engine will capture
    private var processIDs: [AudioObjectID] = []

    // Stores the aggregate device used to access captured audio
    private var aggregateDeviceID: AudioObjectID = 0

    // Tracks if audio engine is currently running
    private(set) var isRunning = false

    // Prepares audio engine for capturing app audio
    func start() {
        print("Preparing audio engine...")
    }

    // Stops the audio engine and releases its resources
    func stop() {
        isRunning = false
        print("Audio engine stopped")
    }
}

