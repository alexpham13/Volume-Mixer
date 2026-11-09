# Volume Mixer for macOS

Control the level of an app playing through your Mac’s selected sound output. Each row has an app icon, a gain slider, mute, a direct-playback option and input diagnostics. The app follows the output selected in macOS Sound settings. It uses Apple’s process taps and private aggregate devices and installs no audio driver.

**Verification status:** The render callback passed synthetic-buffer tests on Linux. The Xcode target has not been compiled with the macOS SDK in this environment. Live capture, audible gain, permissions, latency and AirPods behavior need the Mac checks below. This archive contains source and a local build script. It contains no signed distribution binary.

## Build and run

1. On a Mac running macOS 14.6 or later, use Xcode 16 or newer with the macOS SDK. Extract the ZIP and open **Volume Mixer.xcodeproj**. Select the **Volume Mixer** scheme and **My Mac**. Press **⌘R**. The target uses local ad-hoc signing and has no package dependencies.
2. Alternatively, in Terminal, change directory to the extracted folder containing the Xcode project and run:

   ~~~bash
   ./scripts/check-dsp.sh
   ./scripts/build-app.sh
   open "build/Build/Products/Release/Volume Mixer.app"
   ~~~

   The build script produces the standalone Release app, checks its capture usage string and verifies its local signature. If xcodebuild refers to Command Line Tools, select your full Xcode under Xcode Settings → Locations → Command Line Tools.
3. Keep one copy running. For everyday use, quit the build copy and copy the Release app to Applications before launching it there. Rebuilds, signature changes and a change of app location may require a fresh permission grant.
4. Start playback on the selected output. Open the **…** menu in that app’s row and choose **Check input signal**. Approve the macOS audio capture request. If prompted to restart, quit with **⌘Q** and reopen. Check System Settings → Privacy & Security → Screen & System Audio Recording (the wording varies by macOS version). This app does not save recordings.
5. Move the slider or press the speaker button. Muting preserves the previous slider setting. Dragging the slider clears mute. **Restore direct playback** releases that row’s tap and resets its level to 100%. Quitting the mixer releases all routes. Saved volume and mute settings are keyed by app identity.

## How the audio moves

- **AudioManager.swift** polls Core Audio for processes currently running output. It excludes its own PID. It resolves bundled helpers to the enclosing application or a GUI parent where possible and groups Core Audio object IDs under a stable app identifier. It reconciles changed process sets and output device, channel, rate or format changes on a serial control queue. Independent engines allow two rows to have different gains.
- **AudioHardware.swift** reads the default output UID, stream properties and process IDs. **ProcessAudioEngine.swift** scopes each tap to the selected process objects, that output UID and stream zero. Each private aggregate contains the hardware output as clock master and the drift-compensated tap as input. Setup waits for the aggregate’s streams, verifies matching native Float32 formats and disables physical input streams for its callback.
- **Signal check.** A fresh route first uses an unmuted tap. Its callback meters input and writes silence to the aggregate output. Original playback stays audible. Once a non-silent block arrives, a requested gain below unity starts a replacement tap with mutedWhenTapped. This suppresses the source during active reads while the callback sends the processed samples to the hardware. At 100% an untouched row uses direct playback. An explicit signal check can remain active at 100%.
- **MixerDSP.c** runs directly in the HAL IOProc. It reads only the tap buffers after any physical inputs, verifies channel counts, byte sizes and frame counts, slews gain over approximately 5 ms for a full-scale move, handles nonfinite samples, clamps each output sample and computes input and processed RMS. A small C bridge provides lock-free 32-bit atomics. The callback performs no allocations, locks, logging, dispatch or UI updates. There is no app-side ring buffer. Core Audio mixes the separate app outputs at the destination.
- **ContentView.swift / MyApp.swift** display requested levels, actual route status, meters, PID and HAL IDs. Closing the only window or quitting runs teardown. A setup failure, malformed callback layout, missing callbacks or initial signal timeout releases the route and reports an error. Use **Retry signal check** after correcting the issue.

## What was wrong in the upload

The original aggregate had a tap and no playback subdevice. The callback computed a local RMS value and discarded it, never wrote audio to output, and took an unfair lock to count callbacks. The view started only Spotify by display name at launch, independently of the sliders. Process discovery checked general activity, including input, rather than output activity. The uploaded project also lacked an NSAudioCaptureUsageDescription.

These issues explain the missing playback path and inconclusive diagnostics. The original files cannot identify the exact cause of the reported AirPods zeros. Candidates include permission, selection of the wrong playback process or device, and aggregate readiness. A callback count or a 48 kHz stereo format alone cannot demonstrate capture of Spotify’s signal.

## Mac acceptance test

Keep system volume comfortable and constant. Use continuous, non-protected audio. Select the built-in speakers first, then repeat on AirPods. Leave Spotify’s own volume unchanged. Record macOS version, Xcode version, output, app, PID/HAL IDs, callback count, signal blocks, input/output dBFS and what you heard.

| Check | Action | Passing observation |
| --- | --- | --- |
| Capture | Play Spotify. At 100%, choose **Check input signal** and expand Diagnostics. | Callbacks **and signal blocks** rise. Monitoring shows finite input dBFS during music. Audio stays at the original level. |
| Gain | Move Spotify to 50%, then 10%. Wait for **Mixing**. | Sound gets progressively quieter. For steady input the output meter reads about 6 dB below input at 50% and 20 dB below at 10%. A meter measures what the callback wrote. Confirm the change by listening. |
| Mute and duplication | While Spotify keeps playing, mute at 50%, then unmute. | During mute Spotify becomes inaudible while input signal continues. Unmuting restores 50%. Residual full-level audio suggests an untapped helper or a second playback path. |
| Isolation | Play a distinctly different sound in Safari alongside Spotify. Mute each row in turn. Repeat with Discord playing through the macOS default output. | Only the selected sound changes. If a browser audio helper appears separately, test that row and record its PID. |
| Bluetooth route | While both apps play, switch the macOS output to AirPods. Wait for the header and rows to update. Switch back and disconnect/reconnect the headphones. | Audio resumes on the selected device at the requested per-app levels. No sustained doubling, feedback, distortion or drift. A brief direct-playback interval during reconstruction is possible. |
| Restart | Pause, resume, quit and relaunch a source app. Repeat the output switch several times. | The active rows follow playback. A changed process ID is re-tapped, and the saved gain returns for an identified app. |
| Failure and recovery | Deny capture permission on a fresh launch or turn it off and relaunch. Try a signal check. Restore permission, relaunch if prompted and retry. | A setup error or no-signal timeout is visible, and original playback is audible after teardown. |
| Cleanup | With one source attenuated and another muted, press **⌘Q** while both sources continue playing. | Both return to direct playback. Reopening the mixer makes one row per identified application. |

If callbacks increase but signal blocks stay at zero, verify that Spotify is playing **on this Mac**, that the output in the header is the one you hear, and that the permission belongs to the build you launched. Test Safari with an ordinary audio file. Compare speakers and AirPods with the same source. If built-in output succeeds, save both sets of diagnostics. If the processed meter changes but the audible level does not, try mute to distinguish an additional source path from a metering problem. **Restore direct playback** or quit to release the route.

## Limits and distribution

- Supports a single mono or stereo output stream in a matching native Float32 format, interleaved or planar. Multistream, surround, incompatible sample rates, some Bluetooth call profiles, aggregate outputs, devices in exclusive use, and protected playback may fail or yield silence. Apps explicitly routed to another device must use the selected macOS output to participate.
- Discovery uses polling, and route changes rebuild taps. New or restarted apps can briefly play at their original volume before the signal check completes. Mute is a playback control, unsuitable as a privacy boundary. Bluetooth hardware latency remains.
- Where macOS exposes a shared helper with no identifiable GUI owner, it may appear under its own name. Separate tabs or callers sharing one process cannot be controlled independently. PID-only identities cannot reliably retain preferences through restarts.
- Gains are limited to attenuation (0–100%). Each individual render is clamped. The final system mix, device processing and any downstream distortion sit outside the mixer’s control.
- The app is a locally signed, unsandboxed macOS development build. Developer ID signing, hardened runtime validation, notarization and distribution to other Macs remain release steps. Publish the source ZIP or its contents after running the hardware checklist. Private Git history, Xcode user state and build products are excluded from the archive.

## Checks included

Tests/render_test.c exercises the production callback with interleaved and planar stereo, physical-input offset, silent input, non-silent monitoring with silent output, independent gains, ramp-to-mute, malformed buffer sizes, NaN handling and clipping. scripts/check-dsp.sh runs it against the real SDK on your Mac. In the development environment it also passed optimized GCC and AddressSanitizer/UndefinedBehaviorSanitizer runs using a minimal Core Audio type shim. GCC static analysis ran on the DSP. LeakSanitizer was disabled because this host prevents process tracing. These checks do not exercise HAL device creation or Swift type checking.

## Apple references

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Process and output-device selection](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [Tap mute behavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- [System audio capture usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
