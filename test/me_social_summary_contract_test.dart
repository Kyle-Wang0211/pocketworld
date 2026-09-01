import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Me page wires the signed-in profile summary and following route', () {
    final source = File('lib/ui/me_page.dart').readAsStringSync();
    expect(
      source,
      contains('SocialProfileRepository? socialProfileRepository'),
    );
    expect(source, contains('_loadSocialProfile'));
    expect(source, contains('_MeSocialSummary('));
    expect(source, contains('value.publicWorksCount'));
    expect(source, contains('value.followersCount'));
    expect(source, contains('value.followingCount'));
    expect(source, contains('FollowingListPage('));
    expect(source, contains('label: AppL10n.of(context).socialFollow'));
    expect(source, contains('await Navigator.of(context).push'));
  });
}
