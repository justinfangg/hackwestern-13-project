import MapKit

/// A single, world-sized overlay whose renderer paints fog only in MapKit's
/// requested dirty rectangles. The overlay deliberately contains no mutable
/// exploration state; `FogRenderer` owns an immutable render snapshot instead.
final class FogOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}
