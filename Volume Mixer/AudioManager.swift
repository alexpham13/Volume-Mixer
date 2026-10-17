import Foundation
import CoreAudio
import AppKit

//Manages core audio functionality separately from UI
class AudioManager {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var activeApps: [String] = []
    var appVolumes: [String: Double] = [:]
    
    func getAudioProcesses() {
        activeApps.removeAll()
        
        // Specifies which information we need
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
            )
        
        // Store the amount of memory needed for list
        var dataSize: UInt32 = 0

        // Ask core audio how many bytes the list needs
        let status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        
        if status == noErr {
            print(dataSize)
            
            // Calculates how many audio process IDs can fit in data
            let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            
            // Prevents app from crashing if we have empty process ID array
            guard processCount > 0 else {
                print("No audio processes found")
                return
            }
            
            // Creates an array to store audio process IDs
            var processIDs = [AudioObjectID](repeating: 0, count: processCount)
        
            // Allow Core Audio to access and fill our process ID array
            processIDs.withUnsafeMutableBufferPointer { buffer in
                let fetchStatus = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, UnsafeMutableRawPointer(buffer.baseAddress!))
                
                if fetchStatus == noErr {
                    print(Array(buffer))
                    
                }
            }
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
                
                let pidStatus = AudioObjectGetPropertyData(processId, &pidAddress, 0, nil, &pidSize, &pid)
                
                if pidStatus == noErr {
                    
                    
                    // Uses the macOS process ID to find corresponding application
                    let app = NSRunningApplication(processIdentifier: pid)
                    
                    let appName = app?.localizedName ?? "Unknown App"
                    
                    // Specifies that we want to check whether this audio process is running
                    var runningAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioProcessPropertyIsRunning,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var isRunning: UInt32 = 0
                    // Stores the memory size needed for the audio process running status
                    var runningSize = UInt32(MemoryLayout<UInt32>.size)
                    
                    let runningStatus = AudioObjectGetPropertyData(processId, &runningAddress, 0, nil, &runningSize, &isRunning)
                    
                    if runningStatus == noErr {
                        if isRunning != 0 {
                            print("\(appName) - Audio process is running!")
                            // Prevents duplicate app names from appearing in UI
                            if !activeApps.contains(appName) {
                                activeApps.append(appName)
                                
                                if appVolumes[appName] == nil {
                                    appVolumes[appName] = 0.5
                                }
                            }
                        }
                    }
                }
            }
            
        } else {
                print("Core Audio error: ", status)
            }
    }
    
}
