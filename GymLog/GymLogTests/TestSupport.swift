import Foundation
import SwiftData
@testable import GymLogKit

enum TestSupport {
    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Client.self,
            BodyMetric.self,
            Assessment.self,
            WorkoutSession.self,
            SessionBlock.self,
            ExerciseEntry.self,
            SetLog.self,
            Exercise.self,
            SessionTemplate.self,
            TemplateBlock.self,
            TemplateExerciseSlot.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Loads the same fixture the app bundles and imports on first launch.
    ///
    /// Deliberately goes through `Bundle` resource lookup rather than
    /// resolving a path from `#filePath` on the host filesystem: reading an
    /// arbitrary host path via `Data(contentsOf:)` from inside a GymLogTests
    /// process running under the iOS Simulator runtime hangs indefinitely --
    /// confirmed by isolating each SwiftData call (container construction,
    /// context creation, fetch, insert+save all return in well under 100ms;
    /// only the raw file read off the host path outside the app/test sandbox
    /// container never returns). This does not reproduce on macOS destinations,
    /// which is why it was easy to miss. See VERIFICATION.md. `sample_seed.json`
    /// is declared as a `resources:` entry on the GymLogTests target in
    /// project.yml so it's copied into the test bundle itself, sidestepping
    /// the sandbox boundary entirely.
    enum FixtureLoadError: Error {
        case resourceNotFound
    }

    private final class BundleAnchor {}

    static func loadFixtureData() throws -> Data {
        try loadFixtureData(named: "sample_seed", withExtension: "json")
    }

    /// M7: generic version of the above for the new `source.xlsx` /
    /// `inbody_sample.jpg` fixtures -- same sandbox-boundary reasoning
    /// applies to any fixture, not just `sample_seed.json`.
    static func loadFixtureData(named name: String, withExtension ext: String) throws -> Data {
        let bundle = Bundle(for: BundleAnchor.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw FixtureLoadError.resourceNotFound
        }
        return try Data(contentsOf: url)
    }
}
