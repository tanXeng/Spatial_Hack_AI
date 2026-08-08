//
//  TestTests.swift
//  TestTests
//
//  Created by Event on 7/8/26.
//

import Testing
@testable import Test

struct TestTests {

    @Test
    func immersiveExperienceCatalogContainsOnlyShippedMVPRoutes() {
        #expect(ImmersiveExperience.allCases == [
            .anthropometryCalibration,
            .auraPunch,
            .reactiveBoard,
            .bagPreview,
            .defense,
        ])
    }

}
