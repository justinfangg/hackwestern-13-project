import Foundation
import Testing
@testable import FogKit

@Suite struct FixFilterTests {
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func firstFixStartsSegment() {
        var f = FixFilter()
        #expect(f.evaluate(fix(.westernCampus, at: t0)) == .accept(newSegment: true))
    }

    @Test func rejectsInaccurateFixes() {
        var f = FixFilter()
        #expect(f.evaluate(fix(.westernCampus, at: t0, accuracy: 80)) == .reject(.inaccurate))
        #expect(f.evaluate(fix(.westernCampus, at: t0, accuracy: -1)) == .reject(.inaccurate))
    }

    @Test func rejectsJitterAndOutOfOrder() {
        var f = FixFilter()
        _ = f.evaluate(fix(.westernCampus, at: t0))
        #expect(f.evaluate(fix(Geo.offset(.westernCampus, north: 1, east: 0), at: t0 + 1)) == .reject(.tooClose))
        #expect(f.evaluate(fix(Geo.offset(.westernCampus, north: 10, east: 0), at: t0 - 1)) == .reject(.outOfOrder))
    }

    @Test func acceptsWalking() {
        var f = FixFilter()
        _ = f.evaluate(fix(.westernCampus, at: t0))
        #expect(f.evaluate(fix(Geo.offset(.westernCampus, north: 7, east: 0), at: t0 + 5)) == .accept(newSegment: false))
    }

    @Test func rejectsDrivingThenRecoversAsNewSegment() {
        var f = FixFilter()
        _ = f.evaluate(fix(.westernCampus, at: t0))
        // 500 m in 10 s = 50 m/s.
        let far = { (s: Double) in fix(Geo.offset(.westernCampus, north: 500 + s, east: 0), at: self.t0 + 10 + s) }
        #expect(f.evaluate(far(0)) == .reject(.tooFast))
        #expect(f.evaluate(far(1)) == .reject(.tooFast))
        #expect(f.evaluate(far(2)) == .accept(newSegment: true))
    }
}

@Suite struct PathInterpolatorTests {
    @Test func fillsGapsEveryTenMetres() {
        let to = Geo.offset(.westernCampus, north: 55, east: 0)
        let pts = PathInterpolator.points(from: .westernCampus, to: to)
        #expect(pts.count == 6)
        #expect(pts.last == to)
        let gaps = zip([Coordinate.westernCampus] + pts, pts).map { Geo.distance($0, $1) }
        #expect(gaps.allSatisfy { $0 <= 10.01 })
    }

    @Test func doesNotBridgeLongGaps() {
        let to = Geo.offset(.westernCampus, north: 400, east: 0)
        #expect(PathInterpolator.points(from: .westernCampus, to: to) == [to])
    }
}

@Suite @MainActor struct LocationServiceTests {
    @Test func fansOutInterpolatedStepsToAllSubscribers() {
        let service = LocationService()
        var a: [LocationStep] = [], b: [LocationStep] = []
        let s1 = service.subscribe { a.append($0) }
        let s2 = service.subscribe { b.append($0) }
        let t0 = Date(timeIntervalSince1970: 0)
        service.handle(fix(.westernCampus, at: t0))
        service.handle(fix(Geo.offset(.westernCampus, north: 25, east: 0), at: t0 + 10))
        #expect(a.count == 2 && b.count == 2)
        #expect(a[0].newSegment && !a[1].newSegment)
        #expect(a[1].pathPoints.count == 3)
        #expect(service.currentCoordinate == Geo.offset(.westernCampus, north: 25, east: 0))
        _ = (s1, s2)
    }
}

@Suite @MainActor struct SimulatorTests {
    @Test func joystickWalksNorthAtWalkingSpeed() {
        let clock = TestClock()
        let sim = SimulatedLocationProvider(start: .westernCampus, clock: clock.closure)
        var fixes: [LocationFix] = []
        sim.onFix = { fixes.append($0) }
        sim.setJoystick(x: 0, y: 1)
        for _ in 0..<10 { clock.advance(1); sim.tick(dt: 1) }
        #expect(abs(Geo.distance(.westernCampus, sim.position) - 14) < 0.1)
        #expect(sim.position.latitude > Coordinate.westernCampus.latitude)
        #expect(fixes.count == 10 && fixes.allSatisfy { $0.source == .simulated })
    }

    @Test func boostIsFiveTimesFaster() {
        let sim = SimulatedLocationProvider(start: .westernCampus)
        sim.boost = 5
        sim.setJoystick(x: 1, y: 0)
        sim.tick(dt: 1)
        #expect(abs(Geo.distance(.westernCampus, sim.position) - 7) < 0.1)
    }

    @Test func autoWalkFollowsRouteAndStops() {
        let sim = SimulatedLocationProvider()
        let a = Coordinate.westernCampus
        let b = Geo.offset(a, north: 20, east: 0), c = Geo.offset(b, north: 0, east: 20)
        sim.startAutoWalk([a, b, c])
        #expect(sim.position == a && sim.mode == .autoWalk)
        sim.boost = 10 // 14 m/s
        sim.tick(dt: 1)
        #expect(abs(Geo.distance(a, sim.position) - 14) < 0.2)
        for _ in 0..<5 { sim.tick(dt: 1) }
        #expect(Geo.distance(sim.position, c) < 0.01)
        #expect(sim.mode == .idle)
    }

    @Test func simulatedFixesFlowThroughTheFilter() {
        let clock = TestClock()
        let service = LocationService(simulator: SimulatedLocationProvider(clock: clock.closure))
        service.setSimulating(true)
        var steps = 0
        let sub = service.subscribe { _ in steps += 1 }
        service.simulator.setJoystick(x: 0, y: 1)
        // 3 s ticks = 4.2 m per fix, above the 3 m jitter threshold, so every fix is accepted.
        for _ in 0..<6 { clock.advance(3); service.simulator.tick(dt: 3) }
        #expect(steps == 6)
        _ = sub
    }
}

@Suite struct GPXTests {
    @Test func parsesTrackPoints() throws {
        let gpx = """
        <gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
        <trkpt lat="43.0" lon="-81.0"/><trkpt lat="43.1" lon="-81.1"><ele>250</ele></trkpt>
        </trkseg></trk></gpx>
        """
        #expect(try GPXParser.parse(Data(gpx.utf8)) == [Coordinate(latitude: 43, longitude: -81),
                                                       Coordinate(latitude: 43.1, longitude: -81.1)])
    }

    @Test func bundledDemoRouteLoads() throws {
        #expect(try GPXParser.bundledDemoRoute().count >= 2)
    }

    @Test func emptyFileThrows() {
        #expect(throws: GPXParser.Error.self) { try GPXParser.parse(Data("<gpx/>".utf8)) }
    }
}
