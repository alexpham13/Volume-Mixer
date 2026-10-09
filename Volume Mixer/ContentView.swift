import AppKit
import SwiftUI
import CoreAudio

struct ContentView: View {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    
    func getAudioProcesses() {
        
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
        } else {
                print("Core Audio error: ", status)
            }
        
    }
    var body: some View {
        Text("Volume Mixer")
            // Finds audio processes that exist on Mac currently
            .onAppear {
                getAudioProcesses()
            }
    }
    }

#Preview {
    ContentView()
}


