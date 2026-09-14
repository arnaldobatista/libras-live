import Foundation
import Testing
@testable import LibrasCore

@Suite struct OverlayRosterTests {
    let obs = UUID()
    let monitor = UUID()

    func roster(_ ids: UUID..., visible: [UUID: Bool] = [:]) -> OverlayRoster {
        var roster = OverlayRoster()
        for id in ids {
            roster.connect(id)
            _ = roster.apply(OverlayInbound(type: .ready, visible: visible[id] ?? true), from: id)
        }
        return roster
    }

    @Test func needsReadyOverlayToPlay() {
        var r = OverlayRoster()
        r.connect(obs)
        #expect(!r.canPlay)
        _ = r.apply(OverlayInbound(type: .hello, loaded: false), from: obs)
        #expect(!r.canPlay)
        _ = r.apply(OverlayInbound(type: .ready), from: obs)
        #expect(r.canPlay)
    }

    @Test func waitsForAllVisibleOverlays() {
        var r = roster(obs, monitor)
        r.beginPlayback(itemID: 1)
        let afterMonitor = r.ended(itemID: 1, from: monitor)
        let afterOBS = r.ended(itemID: 1, from: obs)
        #expect(afterMonitor == false)
        #expect(afterOBS == true)
        #expect(r.playingItem == nil)
    }

    @Test func hiddenOverlayDoesNotGatePlayback() {
        var r = roster(obs, monitor, visible: [monitor: false])
        #expect(r.hiddenCount == 1)
        r.beginPlayback(itemID: 7)
        #expect(r.ended(itemID: 7, from: monitor) == false)
        #expect(r.ended(itemID: 7, from: obs) == true)
    }

    @Test func onlyHiddenOverlaysStillPlay() {
        var r = roster(monitor, visible: [monitor: false])
        r.beginPlayback(itemID: 2)
        #expect(r.ended(itemID: 2, from: monitor) == true)
    }

    @Test func ignoresStaleItemIDs() {
        var r = roster(obs)
        r.beginPlayback(itemID: 3)
        #expect(r.ended(itemID: 2, from: obs) == false)
        #expect(r.playingItem == 3)
    }

    @Test func disconnectReleasesPlayback() {
        var r = roster(obs, monitor)
        r.beginPlayback(itemID: 4)
        #expect(r.ended(itemID: 4, from: obs) == false)
        #expect(r.disconnect(monitor) == true)
        #expect(r.total == 1)
    }

    @Test func becomingHiddenReleasesPlayback() {
        var r = roster(obs)
        r.beginPlayback(itemID: 5)
        #expect(r.apply(OverlayInbound(type: .visibility, visible: false), from: obs) == true)
    }
}
