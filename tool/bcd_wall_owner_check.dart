import 'dart:convert';
import 'dart:io';

import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';

void main() {
  final document =
      jsonDecode(stdin.readLineSync() ?? '') as Map<String, dynamic>;
  final rows = (document['candidates'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  BcdWallStrictMetrics? strict(Map<String, dynamic> row) {
    final value = row['strict'];
    if (value == null) return null;
    final metrics = value as Map<String, dynamic>;
    return BcdWallStrictMetrics(
      eligible: metrics['eligible'] as bool,
      accepted: metrics['accepted'] as int,
      coverageCells5cm: metrics['coverage_cells_5cm'] as int,
      medianNcc: (metrics['median_ncc'] as num).toDouble(),
      nccP10: (metrics['ncc_p10'] as num).toDouble(),
    );
  }

  final decision = BcdFinalizeCoordinator.selectWallOwners([
    for (final row in rows)
      BcdWallCandidateMetrics(
        candidateId: row['candidate_id'] as String,
        thetaDeg: (row['theta_deg'] as num).toDouble(),
        planeValue: (row['plane_value'] as num).toDouble(),
        sparseScore: (row['sparse_score'] as num).toDouble(),
        sparseSupportPoints: row['sparse_support_points'] as int,
        accepted: row['accepted'] as int,
        coverageCells5cm: row['coverage_cells_5cm'] as int,
        medianNcc: (row['median_ncc'] as num).toDouble(),
        nccP10: (row['ncc_p10'] as num).toDouble(),
        incumbent: row['incumbent'] as bool? ?? false,
        strict: strict(row),
      ),
  ]);
  stdout.writeln(
    'BCD_RESULT=${jsonEncode({'selected_candidate_ids': decision.selectedCandidateIds, 'required_strict_candidate_ids': decision.requiredStrictCandidateIds, 'unresolved_family_count': decision.unresolvedFamilyCount, 'complete': decision.complete})}',
  );
}
