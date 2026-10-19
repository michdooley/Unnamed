import Foundation
import Testing
@testable import UnnamedKit

struct PlaybackQueueTests {
    let ids = (0..<5).map { _ in UUID() }

    @Test func playsInOrderAndStopsAtEnd() {
        var queue = PlaybackQueue()
        queue.load(ids)
        #expect(queue.current == ids[0])
        for i in 1..<5 {
            #expect(queue.advance(automatic: true) == ids[i])
        }
        #expect(queue.advance(automatic: true) == nil)
    }

    @Test func startsAtRequestedTrack() {
        var queue = PlaybackQueue()
        queue.load(ids, startAt: ids[3])
        #expect(queue.current == ids[3])
        #expect(queue.advance(automatic: false) == ids[4])
    }

    @Test func repeatAllWrapsAround() {
        var queue = PlaybackQueue()
        queue.repeatMode = .all
        queue.load(ids, startAt: ids[4])
        #expect(queue.advance(automatic: true) == ids[0])
        #expect(queue.goBack() == ids[4])
    }

    @Test func repeatOneOnlyRepeatsWhenTrackEnds() {
        var queue = PlaybackQueue()
        queue.repeatMode = .one
        queue.load(ids)
        #expect(queue.advance(automatic: true) == ids[0])
        #expect(queue.advance(automatic: false) == ids[1])
    }

    @Test func goBackStopsAtStartWithoutRepeat() {
        var queue = PlaybackQueue()
        queue.load(ids, startAt: ids[1])
        #expect(queue.goBack() == ids[0])
        #expect(queue.goBack() == nil)
    }

    @Test func shuffleKeepsCurrentTrackAndVisitsEveryTrackOnce() {
        var queue = PlaybackQueue()
        queue.load(ids, startAt: ids[2])
        queue.setShuffle(true)
        #expect(queue.current == ids[2])
        #expect(queue.order.first == ids[2])
        #expect(Set(queue.order) == Set(ids))

        var played = [queue.current!]
        while let next = queue.advance(automatic: true) { played.append(next) }
        #expect(played.count == ids.count)
        #expect(Set(played) == Set(ids))

        queue.setShuffle(false)
        #expect(queue.order == ids)
    }

    @Test func turningShuffleOffResumesNaturalOrderFromCurrentTrack() {
        var queue = PlaybackQueue()
        queue.setShuffle(true)
        queue.load(ids, startAt: ids[1])
        #expect(queue.current == ids[1])
        queue.setShuffle(false)
        #expect(queue.advance(automatic: false) == ids[2])
    }

    @Test func upNextPlaysBeforeTheRestOfTheQueue() {
        var queue = PlaybackQueue()
        let extra = UUID()
        queue.load(ids)
        queue.enqueue(extra)
        #expect(queue.advance(automatic: true) == extra)
        #expect(queue.advance(automatic: true) == ids[1])
    }

    @Test func goingBackFromUpNextReturnsToQueuePosition() {
        var queue = PlaybackQueue()
        let extra = UUID()
        queue.load(ids, startAt: ids[2])
        queue.enqueue(extra)
        #expect(queue.advance(automatic: false) == extra)
        #expect(queue.goBack() == ids[2])
    }

    @Test func removingTheCurrentTrackContinuesWithTheNextOne() {
        var queue = PlaybackQueue()
        queue.load(ids, startAt: ids[2])
        queue.remove(ids[2])
        #expect(queue.advance(automatic: false) == ids[3])

        var fromStart = PlaybackQueue()
        fromStart.load(ids)
        fromStart.remove(ids[0])
        #expect(fromStart.advance(automatic: false) == ids[1])
    }
}
