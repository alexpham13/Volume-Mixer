import SwiftUI

struct ContentView: View {
    @State private var audioManager = AudioManager()
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
                
                audioTimer?.invalidate()
                audioTimer = Timer.scheduledTimer(withTimeInterval: 2.0,repeats: true) { _ in audioManager.getAudioProcesses()
                }
            }
            .onDisappear {
                audioTimer?.invalidate()
                audioTimer = nil
            }
    }
    }

#Preview {
    ContentView()
}


