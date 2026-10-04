import CoreLocation
import ImageIO
import Observation

// Read only the selected original's GPS before the app-owned JPEG strips metadata.
func photoLocation(_ data: Data) -> RecordedLocation? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
          let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
          let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double,
          let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
          let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
          latitude.isFinite, longitude.isFinite,
          (0...90).contains(latitude), (0...180).contains(longitude),
          ["N", "S"].contains(latitudeRef), ["E", "W"].contains(longitudeRef) else { return nil }
    return RecordedLocation(latitude: latitudeRef == "S" ? -latitude : latitude,
                            longitude: longitudeRef == "W" ? -longitude : longitude)
}

enum RecordLocationStatus {
    case saved, photo, requesting, current, denied, unavailable, failed
    var key: String {
        switch self {
        case .saved: "Saved location will be kept."
        case .photo: "Location from the first photo."
        case .requesting: "Getting your current location…"
        case .current: "Current iPhone location, not the record’s historical location."
        case .denied: "Location access is denied. You can still save this record."
        case .unavailable: "Location Services are off. You can still save this record."
        case .failed: "Could not get your current location. You can still save this record."
        }
    }
}

// Editor state also records whether OFF was explicit, so a new daily merge preserves its prior location.
struct RecordLocationDraft {
    private(set) var enabled = false
    private(set) var location: RecordedLocation?
    var status: RecordLocationStatus?
    private var original: RecordedLocation?
    private var firstPhoto: RecordedLocation?
    private var changed = false

    init(existing: RecordedLocation? = nil) {
        original = existing?.isValid == true ? existing : nil
        location = original
        enabled = original != nil
        status = enabled ? .saved : nil
    }

    var needsCurrentLocation: Bool { enabled && location == nil }

    mutating func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        changed = true
        location = enabled ? original ?? firstPhoto : nil
        status = enabled ? (original != nil ? .saved : firstPhoto != nil ? .photo : nil) : nil
    }

    mutating func setFirstPhoto(_ location: RecordedLocation?) {
        firstPhoto = location?.isValid == true ? location : nil
        guard enabled, original == nil else { return }
        if let firstPhoto {
            self.location = firstPhoto
            status = .photo
        } else if status == .photo {
            self.location = nil
            status = nil
        }
    }

    mutating func receiveCurrent(_ fix: CLLocation, now: Date = Date()) {
        guard needsCurrentLocation else { return }
        let coordinate = RecordedLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        guard coordinate.isValid, fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0,
              (-5...60).contains(now.timeIntervalSince(fix.timestamp)) else { fail(.failed); return }
        location = coordinate
        status = .current
    }

    mutating func fail(_ status: RecordLocationStatus) {
        guard needsCurrentLocation else { return }
        self.status = status
    }

    func applying(to prior: RecordedLocation?) -> RecordedLocation? {
        guard changed else { return prior }
        return enabled ? location ?? prior : nil
    }
}

// A concrete, editor-owned native one-shot request; no manager exists until location is enabled.
@Observable final class RecordLocationRecorder: NSObject, @preconcurrency CLLocationManagerDelegate {
    var draft = RecordLocationDraft()
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var requestedFix = false

    func setEnabled(_ enabled: Bool) {
        cancel()
        draft.setEnabled(enabled)
        requestIfNeeded()
    }

    func setFirstPhoto(_ location: RecordedLocation?) {
        draft.setFirstPhoto(location)
        if !draft.needsCurrentLocation { cancel() }
        requestIfNeeded()
    }

    func cancel() {
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        requestedFix = false
    }

    func resumePending() {
        if draft.status == .requesting { requestIfNeeded() }
    }

    private func requestIfNeeded() {
        guard draft.needsCurrentLocation, manager == nil else { return }
        guard CLLocationManager.locationServicesEnabled() else { draft.fail(.unavailable); return }
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        draft.status = .requesting
        continueRequest(manager)
    }

    private func continueRequest(_ manager: CLLocationManager) {
        guard self.manager === manager, draft.needsCurrentLocation else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard !requestedFix else { return }
            requestedFix = true
            manager.requestLocation()
        case .denied, .restricted: draft.fail(.denied); cancel()
        @unknown default: draft.fail(.failed); cancel()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        continueRequest(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard self.manager === manager else { return }
        if let fix = locations.last { draft.receiveCurrent(fix) }
        else { draft.fail(.failed) }
        cancel()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard self.manager === manager else { return }
        draft.fail((error as? CLError)?.code == .denied ? .denied : .failed)
        cancel()
    }
}
