import Foundation
import FogCore

/// Reads track/route/way points from a GPX file, for Auto-Walk (PRD D-3).
/// Vishaal draws the real demo route in gpx.studio; drop it into the package's Resources folder
/// as `demo-route.gpx` (replacing the placeholder).
public enum GPXParser {
    public enum Error: Swift.Error { case unreadable, noPoints }

    public static func parse(_ data: Data) throws -> [Coordinate] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw Error.unreadable }
        // Prefer track points, then route points, then waypoints.
        let points = !delegate.trk.isEmpty ? delegate.trk : !delegate.rte.isEmpty ? delegate.rte : delegate.wpt
        guard !points.isEmpty else { throw Error.noPoints }
        return points
    }

    public static func parse(contentsOf url: URL) throws -> [Coordinate] {
        try parse(Data(contentsOf: url))
    }

    /// The demo route bundled with FogKit.
    public static func bundledDemoRoute() throws -> [Coordinate] {
        guard let url = Bundle.module.url(forResource: "demo-route", withExtension: "gpx") else {
            throw Error.unreadable
        }
        return try parse(contentsOf: url)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var trk: [Coordinate] = [], rte: [Coordinate] = [], wpt: [Coordinate] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            guard ["trkpt", "rtept", "wpt"].contains(local),
                  let lat = attributes["lat"].flatMap(Double.init),
                  let lon = attributes["lon"].flatMap(Double.init) else { return }
            let c = Coordinate(latitude: lat, longitude: lon)
            switch local {
            case "trkpt": trk.append(c)
            case "rtept": rte.append(c)
            default: wpt.append(c)
            }
        }
    }
}
