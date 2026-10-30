import SwiftUI

struct ContentView: View {
    @State private var audioManager = AudioManager()
    @State private var audioEngine = ProcessAudioEngine()
    @State private var audioTimer: Timer?
    @State private var testVolume: Double = 0.5
        
    var body: some View {
        VStack(spacing: 20) {
            Text("Volume Mixer")
                .font(.title2)
                .fontWeight(.bold)
            
            ForEach(audioManager.activeApps, id: \.self) { appName in
                VStack(spacing: 8) {
                    HStack {
                        Text(appName)
                        Spacer()
                        // Displays the app's curent slider value as percentage
                        Text("\(Int((audioManager.appVolumes[appName] ?? 0.5) * 100))%")
                    }
                    // Gives each app an independent slider
                    Slider(
                        value: Binding(
                            get: {
                                audioManager.appVolumes[appName] ?? 0.5
                            },
                            set: { newValue in
                                audioManager.appVolumes[appName] = newValue
                            }
                        ),
                        in: 0...1
                    )
                }
            }
        }
        .padding(20)
            // Finds audio processes that exist on Mac currently
            .onAppear {
                audioManager.getAudioProcesses()
                // Tests capturing Spotify's audio using Core Audio process IDs
                if let spotifyIDs = audioManager.appProcessIDs["Spotify"] {
                    do {
                        try audioEngine.start(processIDs: spotifyIDs)
                        print("Spotify capture engine started successfully!")
                    } catch {
                        print("Spotify capture failed: \(error)")
                    }
                } else {
                    print("Spotify audio process not detected")
                }
                
                audioTimer?.invalidate()
                audioTimer = Timer.scheduledTimer(withTimeInterval: 2.0,repeats: true) { _ in audioManager.getAudioProcesses()
                    
                    // Checks how many audio callbacks our engine has received
                    print("Audio callbacks received: \(audioEngine.getCallbackCount())")
                }
            }
            .onDisappear {
                audioTimer?.invalidate()
                audioTimer = nil
                
                // Stops audio capture and releases Core Audio resources
                audioEngine.stop()
            }
    }
    }

#Preview {
    ContentView()
}


