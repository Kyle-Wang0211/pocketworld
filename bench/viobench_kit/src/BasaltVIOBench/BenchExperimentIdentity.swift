import Foundation

/// Experiment identity, read from the bundled contract rather than restated in
/// Swift.
///
/// `experiment_id` used to be a string literal in four places: three engine
/// descriptors and the receipt's default, plus a fifth copy inside
/// `RunReceipt.validate()` that hard-required it. Bumping the contract to
/// schema v2 therefore changed nothing the device wrote -- every receipt from
/// 2026-08-30 still declared `vio-iphone-three-arm-v1-20260829` while the
/// contract on disk said v2. The receipt hashes the contract in the same breath,
/// so an artifact could carry a v2 `contract_sha256` next to a v1
/// `experiment_id` and look internally consistent to a reader who checked only
/// one of them.
///
/// There is now one copy, and it comes from the artifact the receipt already
/// hashes, so the two cannot disagree.
enum BenchExperimentIdentity {

    /// Deliberately not a plausible-looking identifier. If the contract resource
    /// is missing from the bundle, every receipt fails validation loudly instead
    /// of quietly inheriting a stale but well-formed default.
    static let unavailable = "contract-resource-missing"

    private struct ContractHeader: Decodable {
        let experimentID: String
        let scope: String

        enum CodingKeys: String, CodingKey {
            case experimentID = "experiment_id"
            case scope
        }
    }

    private static let header: ContractHeader? = {
        guard let url = Bundle.main.url(forResource: "contract", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ContractHeader.self, from: data)
    }()

    static var experimentID: String { header?.experimentID ?? unavailable }
    static var scope: String { header?.scope ?? unavailable }
    static var isAvailable: Bool { header != nil }
}
