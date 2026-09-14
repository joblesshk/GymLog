import SwiftUI
import GymLogKit

/// SwiftUI-facing wrapper around `ClientColorHash` (GymLogKit) --
/// deliberately just a thin `Color` conversion so the hash itself stays
/// SwiftUI-free and unit-testable from GymLogTests.
extension Client {
    var stableColor: Color {
        Color(hue: ClientColorHash.hue(forID: id), saturation: 0.6, brightness: 0.82)
    }
}
