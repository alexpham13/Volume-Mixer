import AppKit
import SwiftUI
import CoreAudio

struct ContentView: View {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    
    func getAudioProcesses() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
            )
        var dataSize: UInt32 = 0

        let status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        
    }
    var body: some View {
        Text("Volume Mixer")
        
    }
    }

#Preview {
    ContentView()
}


