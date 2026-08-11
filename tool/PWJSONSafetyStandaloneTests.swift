import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
struct PWJSONSafetyStandaloneTests {
  static func main() throws {
    let filtered = PWJSONSafety.finitePointPairs(
      [
        [1, 2, 3],
        [4, .nan, 6],
        [7, 8, 9],
        [.infinity, 11, 12],
      ],
      identifiers: [101, 102, 103, 104]
    )
    expect(
      filtered.points == [[1, 2, 3], [7, 8, 9]],
      "only non-finite points must be removed"
    )
    expect(
      filtered.identifiers == [101, 103],
      "point identifiers must remain paired and ordered"
    )

    let mismatched = PWJSONSafety.finitePointPairs(
      [[1, 2, 3], [4, 5, 6]],
      identifiers: [201]
    )
    expect(
      mismatched.points == [[1, 2, 3]]
        && mismatched.identifiers == [201],
      "mismatched input counts must not create unpaired metadata"
    )

    do {
      try PWJSONSafety.requireFinite([1, .nan, 3], field: "extrinsic")
      expect(false, "required non-finite geometry must throw")
    } catch {
      // Expected: invalid required geometry fails only this save.
    }
    try PWJSONSafety.requireFinite(
      [1, 2, 3],
      field: "intrinsics_fxfycxcy"
    )

    do {
      _ = try PWJSONSafety.data(
        withJSONObject: ["anchors_world": [[Float.nan, 0, 1]]]
      )
      expect(false, "nested NaN must be rejected before Foundation writes it")
    } catch {
      // Expected: the process stays alive because data(withJSONObject:) was not called.
    }
    let valid = try PWJSONSafety.data(
      withJSONObject: ["anchors_world": [[Float(1), 2, 3]]]
    )
    expect(!valid.isEmpty, "valid metadata must still serialize")

    print("PWJSONSafetyStandaloneTests: PASS")
  }
}
