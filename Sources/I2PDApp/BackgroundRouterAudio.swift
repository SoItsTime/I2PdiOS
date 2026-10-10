import AVFoundation
import UIKit

// Mirrors the documented background-download mechanism. It is an experiment,
// not a guarantee that iOS will keep the router alive.
@MainActor
final class BackgroundRouterAudio {
    private var player: AVAudioPlayer?
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var interruptionObserver: NSObjectProtocol?
    private var shouldRun = false
    private var activationPending = false
    private var generation = 0
    private let sessionQueue = DispatchQueue(label: "I2PdiOS.audioSession", qos: .utility)

    func start() {
        shouldRun = true
        guard player?.isPlaying != true, !activationPending else { return }
        activationPending = true
        generation += 1
        let request = generation
        if taskID == .invalid {
            taskID = UIApplication.shared.beginBackgroundTask(withName: "I2P router") { [weak self] in
                Task { @MainActor in self?.endTask() }
            }
        }
        sessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            let failure: String?
            do {
                try session.setCategory(.playback, options: .mixWithOthers)
                try session.setActive(true)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            Task { @MainActor [weak self] in
                self?.finishActivation(request: request, failure: failure)
            }
        }
    }

    private func finishActivation(request: Int, failure: String?) {
        guard request == generation else { return }
        activationPending = false
        guard shouldRun else { return }
        if let failure {
            NSLog("Background audio unavailable: %@", failure)
            endTask()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            let player = try AVAudioPlayer(data: Self.quietLoop())
            player.numberOfLoops = -1
            player.volume = 0.01
            guard player.play() else {
                endTask()
                deactivateSession()
                return
            }
            self.player = player

            if interruptionObserver == nil {
                interruptionObserver = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: session,
                    queue: .main
                ) { [weak self] notification in
                    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                    Task { @MainActor in
                        guard self?.shouldRun == true else { return }
                        self?.start()
                    }
                }
            }
        } catch {
            NSLog("Background audio unavailable: %@", error.localizedDescription)
            endTask()
            deactivateSession()
        }
    }

    func stop() {
        shouldRun = false
        generation += 1
        activationPending = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        player?.stop()
        player = nil
        endTask()
        deactivateSession()
    }

    private func deactivateSession() {
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func endTask() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }

    private static func quietLoop() -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount = Int(sampleRate)
        let sampleBytes = UInt32(sampleCount * MemoryLayout<Int16>.size)
        var data = Data()

        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + sampleBytes)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(sampleBytes)

        for index in 0..<sampleCount {
            let sample = Int16(400 * sin(2 * .pi * 220 * Double(index) / Double(sampleRate)))
            append(sample)
        }
        return data
    }
}
