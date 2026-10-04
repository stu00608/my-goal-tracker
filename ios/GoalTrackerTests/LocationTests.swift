import Testing
import CoreLocation
import ImageIO
import UIKit
@testable import GoalTracker

@MainActor struct LocationTests {
    private let saved = RecordedLocation(latitude: 35.68, longitude: 139.76)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func gpsPhoto(latitude: Double = 25.03, longitude: Double = 121.56,
                          latitudeRef: String? = "N", longitudeRef: String? = "E") throws -> Data {
        var gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: latitude, kCGImagePropertyGPSLongitude: longitude]
        if let latitudeRef { gps[kCGImagePropertyGPSLatitudeRef] = latitudeRef }
        if let longitudeRef { gps[kCGImagePropertyGPSLongitudeRef] = longitudeRef }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func fix(latitude: Double = 34.69, longitude: Double = 135.5,
                     accuracy: Double = 20, timestamp: Date? = nil) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: timestamp ?? now)
    }

    @Test func originalGPSUsesHemisphereAndOwnedCopyStripsIt() throws {
        let original = try gpsPhoto(latitude: 33.86, longitude: 151.21, latitudeRef: "S", longitudeRef: "W")
        #expect(photoLocation(original) == RecordedLocation(latitude: -33.86, longitude: -151.21))
        #expect(photoLocation(try gpsPhoto(latitude: 0, longitude: 0)) == RecordedLocation(latitude: 0, longitude: 0))
        #expect(photoLocation(try photoCopy(original)) == nil)
        #expect(photoLocation(Data([1, 2, 3])) == nil)
    }

    @Test func malformedOrMissingGPSCannotBecomeALocation() throws {
        #expect(photoLocation(try gpsPhoto(latitude: 91)) == nil)
        #expect(photoLocation(try gpsPhoto(longitude: 181)) == nil)
        // ImageIO's JPEG writer supplies missing hemisphere refs; use a genuinely GPS-free copy.
        #expect(photoLocation(try photoCopy(gpsPhoto())) == nil)
        #expect(photoLocation(try gpsPhoto(latitudeRef: "E")) == nil)
        var draft = RecordLocationDraft()
        draft.setFirstPhoto(RecordedLocation(latitude: .nan, longitude: 0))
        draft.setEnabled(true)
        #expect(draft.location == nil && draft.needsCurrentLocation)
    }

    @Test func firstOriginalGPSWaitsForOptInAndSurvivesStrippedCopy() throws {
        let original = try gpsPhoto()
        let ownedCopy = try photoCopy(original)
        var draft = RecordLocationDraft()
        draft.setFirstPhoto(photoLocation(original))
        #expect(!draft.enabled && draft.location == nil)
        #expect(draft.applying(to: nil) == nil)
        #expect(photoLocation(ownedCopy) == nil)
        draft.setEnabled(true)
        #expect(draft.location == photoLocation(original))
        #expect(draft.status == .photo && !draft.needsCurrentLocation)
        draft.receiveCurrent(fix(), now: now)
        #expect(draft.location == photoLocation(original))
    }

    @Test func deniedSelectionDoesNotInventLocationOrEraseDailyConflict() {
        var draft = RecordLocationDraft()
        #expect(!draft.enabled)
        #expect(draft.applying(to: saved) == saved)
        draft.setEnabled(true)
        draft.fail(.denied)
        #expect(draft.location == nil && draft.status == .denied)
        #expect(draft.applying(to: nil) == nil)
        #expect(draft.applying(to: saved) == saved)
        draft.setEnabled(false)
        #expect(draft.applying(to: saved) == nil)
        draft.receiveCurrent(fix(), now: now)
        draft.fail(.failed)
        #expect(draft.location == nil && draft.status == nil)
    }

    @Test func existingLocationIsRetainedUntilExplicitlyDisabled() throws {
        var draft = RecordLocationDraft(existing: saved)
        #expect(draft.enabled && !draft.needsCurrentLocation)
        draft.setFirstPhoto(photoLocation(try gpsPhoto()))
        draft.receiveCurrent(fix(), now: now)
        draft.fail(.denied)
        #expect(draft.location == saved && draft.status == .saved)
        #expect(draft.applying(to: saved) == saved)
        draft.setEnabled(false)
        #expect(draft.applying(to: saved) == nil)
        draft.setEnabled(true)
        #expect(draft.location == saved)
    }

    @Test func currentFixMustBeValidAndFreshAndKeepsCurrentProvenance() {
        var draft = RecordLocationDraft()
        draft.setFirstPhoto(nil)
        draft.setEnabled(true)
        draft.receiveCurrent(fix(accuracy: -1), now: now)
        #expect(draft.location == nil && draft.status == .failed)
        draft.receiveCurrent(fix(timestamp: now.addingTimeInterval(-3600)), now: now)
        #expect(draft.location == nil)
        draft.receiveCurrent(fix(latitude: 91), now: now)
        #expect(draft.location == nil)
        draft.receiveCurrent(fix(), now: now)
        #expect(draft.location == RecordedLocation(latitude: 34.69, longitude: 135.5))
        #expect(draft.status == .current)
        #expect(draft.applying(to: saved) == draft.location)
        draft.setFirstPhoto(nil)
        #expect(draft.status == .current)
    }

    @Test func stoppedRecorderIgnoresLateNativeCallbacks() {
        let recorder = RecordLocationRecorder()
        recorder.draft = RecordLocationDraft(existing: saved)
        recorder.setEnabled(false)
        recorder.cancel()
        let unrelatedManager = CLLocationManager()
        recorder.locationManager(unrelatedManager, didUpdateLocations: [fix()])
        recorder.locationManager(unrelatedManager, didFailWithError: CLError(.denied))
        #expect(recorder.draft.location == nil && recorder.draft.status == nil)
        #expect(recorder.draft.applying(to: saved) == nil)
    }
}
