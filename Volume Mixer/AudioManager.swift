import Foundation
import CoreAudio
import AppKit
import Observation

//Manages core audio functionality separately from UI
@Observable
final class AudioManager {

    let systemObject = AudioObjectID(kAudioObjectSystemObject)

    var activeApps: [String] = []
    var appVolumes: [String: Double] = [:]

    // Maps application names to their Core Audio process IDs
    var appProcessIDs: [String: [AudioObjectID]] = [:]

    // Stores active process taps so they remain alive during audio capture
    @ObservationIgnored
    private var activeTaps: [String: AudioObjectID] = [:]

    // Remembers which process IDs belong to each active tap
    @ObservationIgnored
    private var tappedProcessIDs: [String: [AudioObjectID]] = [:]

    // Prevents new audio operations after shutdown begins
    @ObservationIgnored
    private var isShuttingDown = false

    func getAudioProcesses() {
        guard !isShuttingDown else { return }

        // Specifies which information we need
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Store the amount of memory needed for list
        var dataSize: UInt32 = 0

        // Ask core audio how many bytes the list needs
        let status = AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &dataSize
        )

        if status == noErr {
            // Calculates how many audio process IDs can fit in data
            let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size

            // Prevents app from crashing if we have empty process ID array
            guard processCount > 0 else {
                print("No audio processes found")
                activeApps.removeAll()
                appProcessIDs.removeAll()
                return
            }

            // Creates an array to store audio process IDs
            var processIDs = [AudioObjectID](
                repeating: 0,
                count: processCount
            )

            // Allow Core Audio to access and fill our process ID array
            let fetchStatus = processIDs.withUnsafeMutableBufferPointer { buffer in
                AudioObjectGetPropertyData(
                    systemObject,
                    &address,
                    0,
                    nil,
                    &dataSize,
                    buffer.baseAddress!
                )
            }

            guard fetchStatus == noErr else {
                print("Failed to fetch audio processes: \(fetchStatus)")
                return
            }

            // Temporarily stores the apps found during this scan
            var discoveredApps: [String: [AudioObjectID]] = [:]

            // Examines each ID individually
            for processId in processIDs {

                // Specifies we want the macOS PID of this audio process
                var pidAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioProcessPropertyPID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                var pid: pid_t = 0

                // Stores the amount of memory needed for one macOS process ID
                var pidSize = UInt32(MemoryLayout<pid_t>.size)

                let pidStatus = AudioObjectGetPropertyData(
                    processId,
                    &pidAddress,
                    0,
                    nil,
                    &pidSize,
                    &pid
                )

                if pidStatus == noErr {

                    // Uses the macOS process ID to find corresponding application
                    let app = NSRunningApplication(processIdentifier: pid)
                    let appName = app?.localizedName ?? "Unknown App (\(pid))"

                    // Specifies that we want to check whether this audio process is running
                    var runningAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioProcessPropertyIsRunning,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )

                    var isRunning: UInt32 = 0

                    // Stores the memory size needed for the audio process running status
                    var runningSize = UInt32(MemoryLayout<UInt32>.size)

                    let runningStatus = AudioObjectGetPropertyData(
                        processId,
                        &runningAddress,
                        0,
                        nil,
                        &runningSize,
                        &isRunning
                    )

                    if runningStatus == noErr {

                        if isRunning != 0 {
                            print("\(appName) - Audio process is running!")

                            // Stores each running audio process ID in its app's array
                            discoveredApps[appName, default: []].append(processId)
                        }
                    }
                }
            }

            appProcessIDs = discoveredApps
            activeApps = discoveredApps.keys.sorted()

            // Prevents duplicate app names from appearing in UI
            for appName in activeApps {

                // Gives new applications a default volume of 100%
                if appVolumes[appName] == nil {
                    appVolumes[appName] = 1.0
                }
            }

        } else {
            print("Core Audio error: ", status)
        }
    }

    // Updates an application's stored volume between 0% and 100%
    func setVolume(_ value: Double, for appName: String) {
        appVolumes[appName] = min(max(value, 0.0), 1.0)
    }

    // Returns the application's stored volume value
    func volume(for appName: String) -> Double {
        return appVolumes[appName] ?? 1.0
    }

    func startTap(for appName: String) -> Bool {

        // Prevents new taps from being created during shutdown
        guard !isShuttingDown else { return false }

        // Retrieves the selected application's detected Core Audio process IDs
        guard let processIDs = appProcessIDs[appName],
              !processIDs.isEmpty else {
            print("\(appName) audio process not found")
            return false
        }

        // Reuses an existing tap if its process IDs have not changed
        if activeTaps[appName] != nil {

            if tappedProcessIDs[appName] == processIDs {
                return true
            }

            // Removes the old tap before creating a replacement
            stopTap(for: appName)

            // Do not replace the tap if cleanup failed
            guard activeTaps[appName] == nil else {
                return false
            }
        }

        // Describes a tap that captures audio from the selected processes
        let tapDescription = CATapDescription(
            stereoMixdownOfProcesses: processIDs
        )

        // Stores the Core Audio object ID assigned to our new process tap
        var tapID: AudioObjectID = 0

        // Request core audio to create a process tap
        let status = AudioHardwareCreateProcessTap(
            tapDescription,
            &tapID
        )

        if status == noErr {

            // Keeps the tap alive instead of destroying it immediately
            activeTaps[appName] = tapID
            tappedProcessIDs[appName] = processIDs

            print("Process tap created successfully! ID: \(tapID)")
            return true

        } else {
            print("Failed to create process tap. Error: \(status)")
            return false
        }
    }

    func stopTap(for appName: String) {

        // Finds the existing process tap for this application
        guard let tapID = activeTaps[appName] else {
            return
        }

        // Releases the process tap when it is no longer needed
        let destroyStatus = AudioHardwareDestroyProcessTap(tapID)

        print("Tap cleanup status: \(destroyStatus)")

        if destroyStatus == noErr {
            // Removes the tap from our stored dictionaries
            activeTaps.removeValue(forKey: appName)
            tappedProcessIDs.removeValue(forKey: appName)
        }
    }

    func stopAllTaps() {

        for appName in Array(activeTaps.keys) {
            stopTap(for: appName)
        }
    }
    
    func shutdown() {

        // Prevents shutdown from running more than once
        guard !isShuttingDown else { return }

        isShuttingDown = true

        stopAllTaps()
    }

    deinit {
        // Final cleanup if the AudioManager is released
        for tapID in activeTaps.values {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }
}
