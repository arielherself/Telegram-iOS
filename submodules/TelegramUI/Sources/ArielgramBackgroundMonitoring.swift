import Foundation
import AVFAudio
import UIKit
import SwiftSignalKit
import TelegramAudio
import TelegramCore
import SGSimpleSettings

/// Ten minutes of mono 8 kHz PCM silence. Generated once inside the application
/// support directory, outside the message/media cache and excluded from backup.
func arielgramSilentAudioData() -> Data {
    let sampleRate: UInt32 = 8_000
    let dataLength: UInt32 = sampleRate * 600 * 2
    var data = Data()
    func append16(_ number: UInt16) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    func append32(_ number: UInt32) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    append32(dataLength + 36)
    data.append(contentsOf: "WAVEfmt ".utf8)
    append32(16)
    append16(1)
    append16(1)
    append32(sampleRate)
    append32(sampleRate * 2)
    append16(2)
    append16(16)
    data.append(contentsOf: "data".utf8)
    append32(dataLength)
    data.append(Data(count: Int(dataLength)))
    return data
}

final class ArielgramBackgroundMonitoringController {
    private let audioSession: ManagedAudioSession
    private let updated: (Bool) -> Void
    private let makePlayer: () throws -> AVAudioPlayer
    private var observers: [NSObjectProtocol] = []
    private var sessionDisposable: Disposable?
    private var player: AVAudioPlayer?
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var enabled = false
    private var interrupted = false
    private var active = false

    init(audioSession: ManagedAudioSession, updated: @escaping (Bool) -> Void, makePlayer: (() throws -> AVAudioPlayer)? = nil) {
        self.audioSession = audioSession
        self.updated = updated
        self.makePlayer = makePlayer ?? Self.makeSilentPlayer
        let notifications = NotificationCenter.default
        self.observers.append(notifications.addObserver(forName: SGSimpleSettings.arielgramBackgroundMonitoringChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateSetting()
        })
        self.observers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self.interrupted = type == .began
            self.resetSession()
            if !self.interrupted { self.acquireSession() }
        })
        for name in [AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification, UIApplication.didBecomeActiveNotification] {
            self.observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.enabled else { return }
                if name == UIApplication.didBecomeActiveNotification {
                    self.refreshPlayback()
                } else {
                    self.resetSession()
                    self.acquireSession()
                }
            })
        }
        self.updateSetting()
    }

    deinit {
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
        self.timer?.cancel()
        self.player?.stop()
        self.sessionDisposable?.dispose()
    }

    private func updateSetting() {
        assert(Thread.isMainThread)
        self.enabled = SGSimpleSettings.shared.arielgramBackgroundMonitoring
        self.updated(self.enabled)
        if self.enabled {
            self.acquireSession()
            if self.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + 30.0, repeating: 30.0)
                timer.setEventHandler { [weak self] in self?.refreshPlayback() }
                self.timer = timer
                timer.resume()
            }
        } else {
            self.timer?.cancel()
            self.timer = nil
            self.resetSession()
        }
    }

    private func resetSession() {
        self.generation += 1
        self.active = false
        self.player?.stop()
        self.player = nil
        self.sessionDisposable?.dispose()
        self.sessionDisposable = nil
    }

    private func acquireSession() {
        guard self.enabled, !self.interrupted, self.sessionDisposable == nil else { return }
        let generation = self.generation
        self.sessionDisposable = self.audioSession.push(params: ManagedAudioSessionClientParams(
            audioSessionType: .play(mixWithOthers: true),
            manualActivate: { [weak self] control in
                // The shared session maps this to AVAudioSession.playback with
                // mixWithOthers, and coordinates yielding to recordings/calls.
                control.setup()
                control.activate { _ in
                    DispatchQueue.main.async {
                        guard let self, self.enabled, !self.interrupted, self.generation == generation else { return }
                        self.active = true
                        self.refreshPlayback()
                    }
                }
            },
            deactivate: { [weak self] _ in
                return Signal { subscriber in
                    DispatchQueue.main.async {
                        if let self, self.generation == generation {
                            self.active = false
                            self.player?.pause()
                        }
                        subscriber.putNext(())
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            },
            headsetConnectionStatusChanged: { _ in },
            availableOutputsChanged: { _, _ in },
            isBackground: true
        ))
    }

    private func refreshPlayback() {
        guard self.enabled, !self.interrupted, self.active else { return }
        do {
            if self.player == nil {
                let player = try self.makePlayer()
                player.numberOfLoops = -1
                player.prepareToPlay()
                self.player = player
            }
            if let player = self.player, !player.isPlaying, !player.play() {
                throw NSError(domain: "ArielgramBackgroundMonitoring", code: 1)
            }
        } catch {
            Logger.shared.log("BackgroundMonitoring", "Silent playback failed: \(error)")
            SGSimpleSettings.shared.arielgramBackgroundMonitoring = false
        }
    }

    private static func makeSilentPlayer() throws -> AVAudioPlayer {
        let manager = FileManager.default
        var directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ArielgramBackgroundMonitoring", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let url = directory.appendingPathComponent("silence-600s.wav")
        if !manager.fileExists(atPath: url.path) {
            try arielgramSilentAudioData().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return try AVAudioPlayer(contentsOf: url)
    }
}
