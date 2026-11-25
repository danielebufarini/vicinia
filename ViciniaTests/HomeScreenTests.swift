// Vicinia tests — home screen exposes development/diagnostic sections only
// with the VICINIA_DEVELOPER_TOOLS opt-in; the production connection form is
// present in every build.
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import Vicinia

@Suite("Home screen production cleanup")
struct HomeScreenTests {
    /// Stored-property labels of RootView (backing storage of `@State clips`
    /// is reflected with a compiler-added underscore prefix). Developer-tools
    /// state is compiled in only with `VICINIA_DEVELOPER_TOOLS`, so the labels
    /// observe which configuration the app module was built with. Suffix
    /// matching keeps the test independent of the exact prefix mangling.
    private static func storageLabels() -> Set<String> {
        Set(Mirror(reflecting: RootView()).children.compactMap(\.label))
    }

    @Test("Connection form state is present in every configuration")
    func connectionStatePresent() {
        let labels = Self.storageLabels()
        #expect(labels.contains(where: { $0.hasSuffix("host") }))
        #expect(labels.contains(where: { $0.hasSuffix("user") }))
        #expect(labels.contains(where: { $0.hasSuffix("password") }))
    }

    @Test("Sample-discovery state requires the developer-tools opt-in")
    func sampleStateDeveloperToolsOnly() {
        let labels = Self.storageLabels()
        #if DEBUG && VICINIA_DEVELOPER_TOOLS
        #expect(labels.contains(where: { $0.hasSuffix("clips") }))
        #else
        #expect(!labels.contains(where: { $0.hasSuffix("clips") }))
        #endif
    }
}
