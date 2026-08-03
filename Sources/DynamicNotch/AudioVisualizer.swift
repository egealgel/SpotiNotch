import AppKit
import CoreAudio
import AudioToolbox
import Accelerate

/// Real-time music visualizer driven by the active music app's actual audio.
///
/// Architecture ported from the open-source Atoll / rtaudio projects: a
/// CoreAudio **process tap** is attached to the running player (Spotify /
/// Apple Music), its output is routed through a private aggregate device, and
/// the raw Float samples are FFT'd into a few log-spaced frequency bands. The
/// C++/ObjC++ FFT bridge those projects use is replaced here with Accelerate's
/// `vDSP`, which is directly callable from Swift — so this stays a pure-Swift
/// SwiftPM module with no bridging header.
///
/// The tap only runs while the notch card is expanded (`AppDelegate` drives
/// `start()`/`stop()`), so nothing is captured while the notch is collapsed.
/// On macOS < 14 or when no supported player is running, `isActive` stays
/// false and `NotchView` shows a lightweight animated equalizer instead
/// (boring.notch's default look).
@MainActor
final class AudioVisualizer: ObservableObject {
    static let shared = AudioVisualizer()

    /// 0…1 level per band, published at ~30 fps while the tap is live.
    @Published var levels: [CGFloat] = Array(repeating: 0.15, count: AudioTapEngine.bandCount)
    /// True when a real process tap is delivering levels.
    @Published private(set) var isActive = false

    private let engine = AudioTapEngine()
    private var displayTimer: Timer?
    private var smoothed: [CGFloat] = Array(repeating: 0.15, count: AudioTapEngine.bandCount)

    init() {}

    func start() {
        guard displayTimer == nil else { return }
        engine.startCapture()
        isActive = engine.isRunning
        guard isActive else { return }
        smoothed = Array(repeating: 0.15, count: AudioTapEngine.bandCount)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    func stop() {
        displayTimer?.invalidate()
        displayTimer = nil
        engine.stopCapture()
        isActive = false
        levels = Array(repeating: 0.15, count: AudioTapEngine.bandCount)
    }

    /// Fast-attack / slow-release smoothing on the latest FFT bands, giving the
    /// classic "jumps to the beat, settles slowly" equalizer feel.
    private func tick() {
        let target = engine.instantaneousLevels()
        for i in 0..<target.count {
            let t = CGFloat(target[i])
            let current = smoothed[i]
            let attack: CGFloat = 0.5
            let release: CGFloat = 0.14
            let a = t > current ? attack : release
            smoothed[i] = current + (t - current) * a
        }
        levels = smoothed
    }
}

/// CoreAudio process-tap capture + vDSP FFT in pure Swift. The tap's IO proc
/// runs on a real-time audio thread; it only mutates the FFT scratch buffers
/// and publishes band levels under a lock.
final class AudioTapEngine {
    static let bandCount = 4
    static let fftSize = 2048
    private static let minLevel: Float = 0.08
    private static let silencePeakThreshold: Float = 1e-4

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private let levelLock = NSLock()
    private var latestLevels: [Float] = Array(repeating: minLevel, count: bandCount)

    // Realtime-thread FFT state (never touched from the main thread).
    private var sampleBuffer = [Float](repeating: 0, count: fftSize)
    private var fillIndex = 0
    private var window = [Float](repeating: 0, count: fftSize)
    private var fftSetup: FFTSetup?
    private var realp = [Float](repeating: 0, count: fftSize / 2)
    private var imagp = [Float](repeating: 0, count: fftSize / 2)
    private var sampleRate: Float = 48000

    private(set) var isRunning = false

    // MARK: - Lifecycle

    func startCapture() {
        guard !isRunning else { return }
        let pids = Self.targetPlayerProcessIDs()
        guard !pids.isEmpty else { return }
        guard #available(macOS 14.2, *) else { return }
        guard setupTap(for: pids) else { return }
        prepareFFT()
        isRunning = true
    }

    func stopCapture() {
        guard isRunning else { return }
        isRunning = false
        if #available(macOS 14.2, *) {
            teardown()
        }
    }

    func instantaneousLevels() -> [Float] {
        levelLock.lock(); defer { levelLock.unlock() }
        return latestLevels
    }

    // MARK: - CoreAudio setup

    @available(macOS 14.2, *)
    private func setupTap(for pids: [AudioObjectID]) -> Bool {
        let description = CATapDescription()
        description.processes = pids
        description.isMixdown = true
        description.isMono = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { return false }

        // The tap's unique UID, needed to build the aggregate device around it.
        var tapUID: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = withUnsafeMutablePointer(to: &tapUID) { ptr in
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &size, ptr)
        }
        guard status == noErr else { teardown(); return false }

        // A private aggregate device routes the tap into our IO proc. It's
        // hidden from the user's Sound settings, exactly like Atoll does.
        let tapList = [[kAudioSubTapUIDKey: tapUID]]
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicNotch_Audio_Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        guard status == noErr else { teardown(); return false }

        sampleRate = Self.nominalSampleRate(of: aggregateDeviceID)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        ioProcID = nil
        status = AudioDeviceCreateIOProcID(aggregateDeviceID, Self.ioProc, selfPtr, &ioProcID)
        guard status == noErr, let procID = ioProcID else { teardown(); return false }

        status = AudioDeviceStart(aggregateDeviceID, procID)
        guard status == noErr else { teardown(); return false }
        return true
    }

    @available(macOS 14.2, *)
    private func teardown() {
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = kAudioObjectUnknown
        aggregateDeviceID = kAudioObjectUnknown
        ioProcID = nil
    }

    // MARK: - Real-time callback

    private static let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, clientData in
        guard let clientData = clientData else { return noErr }
        let engine = Unmanaged<AudioTapEngine>.fromOpaque(clientData).takeUnretainedValue()
        guard engine.isRunning else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = buffers.first, let data = first.mData else { return noErr }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        engine.processSamples(data.assumingMemoryBound(to: Float.self), count: count)
        return noErr
    }

    private func processSamples(_ samples: UnsafePointer<Float>, count: Int) {
        guard fftSetup != nil else { return }
        var i = 0
        while i < count {
            sampleBuffer[fillIndex] = samples[i]
            fillIndex += 1
            i += 1
            if fillIndex == Self.fftSize {
                computeSpectrum()
                fillIndex = 0
            }
        }
    }

    // MARK: - FFT

    private func prepareFFT() {
        let log2n = vDSP_Length(log2(Float(Self.fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        fillIndex = 0
    }

    private func computeSpectrum() {
        guard let setup = fftSetup else { return }
        let log2n = vDSP_Length(log2(Float(Self.fftSize)))

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP.multiply(sampleBuffer, window, result: &windowed)

        let half = Self.fftSize / 2
        let nyquist = sampleRate / 2
        let fMin: Float = 40
        let fMax: Float = min(16000, nyquist * 0.9)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                // Pack the real signal into split-complex form for the real FFT
                // (even samples → real part, odd samples → imaginary part).
                for k in 0..<half {
                    rp[k] = windowed[2 * k]
                    ip[k] = windowed[2 * k + 1]
                }
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // Average magnitude per log-spaced band (perceptual, bass→treble).
                let norm = 2.0 / Float(Self.fftSize)
                var bands = [Float](repeating: 0, count: Self.bandCount)
                for b in 0..<Self.bandCount {
                    let t0 = Float(b) / Float(Self.bandCount)
                    let t1 = Float(b + 1) / Float(Self.bandCount)
                    let f0 = exp(log(fMin) + t0 * (log(fMax) - log(fMin)))
                    let f1 = exp(log(fMin) + t1 * (log(fMax) - log(fMin)))
                    let i0 = max(1, Int(f0 / nyquist * Float(half)))
                    let i1 = min(half - 1, max(i0 + 1, Int(f1 / nyquist * Float(half))))
                    var sum: Float = 0
                    for i in i0..<i1 {
                        let re = rp[i] * norm
                        let im = ip[i] * norm
                        sum += (re * re + im * im).squareRoot()
                    }
                    bands[b] = sum / Float(i1 - i0)
                }

                // Auto-range against the loudest band (so quiet tracks still
                // dance), but rest at minimum on near-silence (paused tracks).
                var result = [Float](repeating: Self.minLevel, count: Self.bandCount)
                let peak = bands.max() ?? 0
                if peak > Self.silencePeakThreshold {
                    for b in 0..<Self.bandCount {
                        let rel = bands[b] / peak
                        let perceptual = pow(max(0, rel), 0.6)
                        result[b] = max(Self.minLevel, min(1, perceptual))
                    }
                }

                levelLock.lock()
                latestLevels = result
                levelLock.unlock()
            }
        }
    }

    // MARK: - Process discovery

    /// Finds the running players we support. While a Bluetooth output is active
    /// we skip Spotify (not Apple Music): tapping Spotify into our private
    /// device disturbs the system Now Playing/AVRCP session, which is what
    /// AirPods' play/pause gestures rely on (same caveat Atoll documents).
    private static func targetPlayerProcessIDs() -> [AudioObjectID] {
        let bluetoothActive = isBluetoothOutputActive()
        let apps = NSWorkspace.shared.runningApplications
        var ids: [AudioObjectID] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }
            switch bundleID {
            case "com.spotify.client":
                if bluetoothActive { continue }
            case "com.apple.Music":
                break
            default:
                continue
            }
            if let objectID = audioObjectID(for: app.processIdentifier) {
                ids.append(objectID)
            }
        }
        return ids
    }

    private static func audioObjectID(for pid: pid_t) -> AudioObjectID? {
        var objectID: AudioObjectID = kAudioObjectUnknown
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID)
        return (status == noErr && objectID != kAudioObjectUnknown) ? objectID : nil
    }

    private static func nominalSampleRate(of device: AudioObjectID) -> Float {
        var rate: Float64 = 48000
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return (status == noErr && rate > 0) ? Float(rate) : 48000
    }

    private static func isBluetoothOutputActive() -> Bool {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return false }

        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &tAddress, 0, nil, &tSize, &transport) == noErr else {
            return false
        }
        let bluetooth: UInt32 = 0x626c7574 // 'blut'
        let bluetoothLE: UInt32 = 0x626c6565 // 'blee'
        return transport == bluetooth || transport == bluetoothLE
    }
}
