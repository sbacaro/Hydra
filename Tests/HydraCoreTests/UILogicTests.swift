// Hydra Audio — GPL-3.0
// Pure presentation logic: menu-bar engine presence, load severity buckets,
// elapsed-time formatting, and the console channel-pairing rules used by the
// grid. These back the app's views without needing SwiftUI in the test target.

import Testing
import Foundation
@testable import HydraCore

struct EnginePresenceTests {

    @Test func offlineWhenDisconnected() {
        // Disconnected wins regardless of the (stale) status fields.
        #expect(EnginePresence(connected: false, backplaneInstalled: true,
                               engineRunning: true) == .offline)
    }

    @Test func noBackplaneWhenConnectedButNotInstalled() {
        #expect(EnginePresence(connected: true, backplaneInstalled: false,
                               engineRunning: false) == .noBackplane)
    }

    @Test func stoppedWhenInstalledButEngineDown() {
        #expect(EnginePresence(connected: true, backplaneInstalled: true,
                               engineRunning: false) == .stopped)
    }

    @Test func runningWhenAllGreen() {
        let p = EnginePresence(connected: true, backplaneInstalled: true, engineRunning: true)
        #expect(p == .running)
        #expect(p.isHealthy)
    }

    @Test func onlyRunningIsHealthy() {
        #expect(!EnginePresence.offline.isHealthy)
        #expect(!EnginePresence.noBackplane.isHealthy)
        #expect(!EnginePresence.stopped.isHealthy)
    }

    @Test func shortLabels() {
        #expect(EnginePresence.offline.shortLabel == "Offline")
        #expect(EnginePresence.noBackplane.shortLabel == "No backplane")
        #expect(EnginePresence.stopped.shortLabel == "Stopped")
        #expect(EnginePresence.running.shortLabel == "Running")
    }
}

struct LoadSeverityTests {

    @Test func bucketsByThreshold() {
        #expect(LoadSeverity(load: 0.0) == .normal)
        #expect(LoadSeverity(load: 0.59) == .normal)
        #expect(LoadSeverity(load: 0.60) == .elevated)
        #expect(LoadSeverity(load: 0.84) == .elevated)
        #expect(LoadSeverity(load: 0.85) == .critical)
        #expect(LoadSeverity(load: 1.50) == .critical) // over-unity clamps to critical
    }
}

struct ElapsedFormatTests {

    @Test func formatsUnderAnHourAsMinutesSeconds() {
        #expect(formatElapsed(seconds: 0) == "0:00")
        #expect(formatElapsed(seconds: 5) == "0:05")
        #expect(formatElapsed(seconds: 65) == "1:05")
        #expect(formatElapsed(seconds: 599) == "9:59")
    }

    @Test func formatsOverAnHourWithHours() {
        #expect(formatElapsed(seconds: 3600) == "1:00:00")
        #expect(formatElapsed(seconds: 3661) == "1:01:01")
        #expect(formatElapsed(seconds: 36_000) == "10:00:00")
    }

    @Test func negativeClampsToZero() {
        #expect(formatElapsed(seconds: -10) == "0:00")
    }
}

struct ChannelPairingTests {

    @Test func stereoToStereoMapsLeftAndRight() {
        let pairs = ChannelPairing.pairs(source: [0, 1], destination: [4, 5])
        #expect(pairs.count == 2)
        #expect(pairs[0] == (0, 4))
        #expect(pairs[1] == (1, 5))
    }

    @Test func stereoToMonoSumsBothIntoDest() {
        let pairs = ChannelPairing.pairs(source: [0, 1], destination: [4])
        #expect(pairs[0] == (0, 4))
        #expect(pairs[1] == (1, 4))
    }

    @Test func monoToStereoDuplicatesSource() {
        let pairs = ChannelPairing.pairs(source: [2], destination: [4, 5])
        #expect(pairs[0] == (2, 4))
        #expect(pairs[1] == (2, 5))
    }

    @Test func monoToMonoIsOneToOne() {
        #expect(ChannelPairing.pairs(source: [3], destination: [7]).map { $0 == (3, 7) } == [true])
    }

    @Test func emptyInputsYieldNoPairs() {
        #expect(ChannelPairing.pairs(source: [], destination: [1]).isEmpty)
        #expect(ChannelPairing.pairs(source: [1], destination: []).isEmpty)
    }
}
