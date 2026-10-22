import XCTest
@testable import AdmiralCore

final class JSONSchemaValidatorTests: XCTestCase {
    private func json(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    func testValidObjectPasses() {
        let schema = json(#"{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name"]}"#)
        XCTAssertEqual(JSONSchemaValidator.validate(json(#"{"name":"ada","age":40}"#), against: schema), [])
    }

    func testTypeMismatchReportsPath() {
        let schema = json(#"{"type":"object","properties":{"age":{"type":"integer"}}}"#)
        XCTAssertEqual(JSONSchemaValidator.validate(json(#"{"age":"forty"}"#), against: schema),
                       ["$.age: expected integer"])
    }

    func testIntegerRejectsFraction() {
        XCTAssertEqual(JSONSchemaValidator.validate(json("1.5"), against: json(#"{"type":"integer"}"#)),
                       ["$: expected integer"])
        XCTAssertEqual(JSONSchemaValidator.validate(json("2"), against: json(#"{"type":"integer"}"#)), [])
    }

    func testRequiredMissing() {
        let schema = json(#"{"type":"object","required":["id"]}"#)
        XCTAssertEqual(JSONSchemaValidator.validate(json("{}"), against: schema),
                       ["$.id: required property missing"])
    }

    /// The violation names the values, because it is the only one a model cannot act on:
    /// the real failure this came from spent two of its three attempts guessing `status`.
    func testEnumViolationNamesTheAllowedValues() {
        XCTAssertEqual(JSONSchemaValidator.validate(json(#""complete""#),
                                                    against: json(#"{"enum":["done","blocked"]}"#)),
                       [#"$: "complete" is not one of: "done", "blocked""#])
    }

    /// Enum members are not always strings; each is printed as it appears in the schema.
    func testEnumViolationPrintsNonStringValuesAsJSON() {
        XCTAssertEqual(JSONSchemaValidator.validate(json("3"), against: json(#"{"enum":[1,2]}"#)),
                       ["$: 3 is not one of: 1, 2"])
        XCTAssertEqual(JSONSchemaValidator.validate(json("null"),
                                                    against: json(#"{"enum":[true,false]}"#)),
                       ["$: null is not one of: true, false"])
    }

    func testEnumAndConst() {
        XCTAssertEqual(JSONSchemaValidator.validate(json(#""maybe""#),
                                                    against: json(#"{"enum":["yes","no"]}"#)),
                       [#"$: "maybe" is not one of: "yes", "no""#])
        XCTAssertEqual(JSONSchemaValidator.validate(json("2"), against: json(#"{"const":1}"#)),
                       ["$: must equal the const value"])
    }

    func testNestedArrayItems() {
        let schema = json(#"{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}}}"#)
        XCTAssertEqual(JSONSchemaValidator.validate(json(#"{"tags":["ok",3]}"#), against: schema),
                       ["$.tags[1]: expected string"])
    }

    func testAdditionalPropertiesFalse() {
        let schema = json(#"{"type":"object","properties":{"a":{"type":"string"}},"additionalProperties":false}"#)
        XCTAssertEqual(JSONSchemaValidator.validate(json(#"{"a":"x","b":1}"#), against: schema),
                       ["$.b: additional property not allowed"])
    }

    func testUnsupportedKeywordsIgnoredAndNonObjectSchemaPermissive() {
        // `minLength` is outside the subset — ignored, so this passes.
        XCTAssertEqual(JSONSchemaValidator.validate(json(#""x""#),
                                                    against: json(#"{"type":"string","minLength":5}"#)), [])
        // A non-object schema (e.g. `true`) validates everything.
        XCTAssertEqual(JSONSchemaValidator.validate(json("{}"), against: json("true")), [])
    }
}
