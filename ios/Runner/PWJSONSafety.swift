import Foundation

enum PWJSONSafety {
  static let errorDomain = "OfficialAetherARKit.MetadataJSON"

  static func finitePointPairs(
    _ points: [[Float]],
    identifiers: [UInt64]
  ) -> (points: [[Float]], identifiers: [UInt64]) {
    var finitePoints: [[Float]] = []
    var finiteIdentifiers: [UInt64] = []
    let pairedCount = min(points.count, identifiers.count)
    finitePoints.reserveCapacity(pairedCount)
    finiteIdentifiers.reserveCapacity(pairedCount)

    for index in 0..<pairedCount {
      let point = points[index]
      guard point.count == 3, point.allSatisfy({ $0.isFinite }) else {
        continue
      }
      finitePoints.append(point)
      finiteIdentifiers.append(identifiers[index])
    }
    return (finitePoints, finiteIdentifiers)
  }

  static func requireFinite(_ values: [Float], field: String) throws {
    guard values.allSatisfy({ $0.isFinite }) else {
      throw NSError(
        domain: errorDomain,
        code: 217,
        userInfo: [
          NSLocalizedDescriptionKey:
            "high-resolution metadata field '\(field)' contains a non-finite number",
          "field": field,
        ]
      )
    }
  }

  static func data(
    withJSONObject object: [String: Any]
  ) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw NSError(
        domain: errorDomain,
        code: 218,
        userInfo: [
          NSLocalizedDescriptionKey:
            "high-resolution metadata contains a non-JSON-safe value",
        ]
      )
    }
    return try JSONSerialization.data(withJSONObject: object, options: [])
  }
}
