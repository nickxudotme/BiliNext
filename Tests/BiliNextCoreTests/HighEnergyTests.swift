import Foundation
import Testing

@testable import BiliNextCore

@Test func highEnergyCurveReadsThePbpModule() throws {
    let body = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                #"""
                {"modules":[{"load_mode":"other","params":{}},
                {"load_mode":"pbp","params":{"data":{"step_sec":2,"tagstr":"",
                "events":{"default":[0, 0, 82, 75.5, 81, 95.5]}}}}]}
                """#.utf8)) as? [String: Any])
    let curve = try #require(HighEnergyCurve.parse(body))
    #expect(curve.stepSeconds == 2)
    #expect(curve.samples == [0.0, 0.0, 82.0, 75.5, 81.0, 95.5])
}

@Test func emptyHighEnergyDataMeansNoCurve() throws {
    let body = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                #"{"modules":[{"load_mode":"pbp","params":{"data":{"step_sec":0,"events":{}}}}]}"#
                    .utf8)) as? [String: Any])
    #expect(HighEnergyCurve.parse(body) == nil)
}
