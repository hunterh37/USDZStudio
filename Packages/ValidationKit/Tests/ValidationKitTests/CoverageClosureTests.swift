import Testing
@testable import ValidationKit

@Suite("ValidationKit coverage closure")
struct ValidationKitCoverageClosureTests {
    @Test func identifiersListsEveryProfileID() {
        let ids = ValidationProfile.identifiers
        for profile in ValidationProfile.all {
            #expect(ids.contains(profile.id))
        }
        #expect(ids.contains(", "))  // joined form the CLI/UI display
    }
}
