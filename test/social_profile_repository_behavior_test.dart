import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';
import 'package:pocketworld_flutter/community/social_profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  SupabaseSocialProfileRepository repository({
    required MockClient httpClient,
    String? viewerId = 'viewer-1',
  }) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      accessToken: () async => 'test-jwt',
      httpClient: httpClient,
    );
    return SupabaseSocialProfileRepository(
      client: client,
      viewerIdProvider: () => viewerId,
    );
  }

  http.Response jsonResponse(
    http.BaseRequest request,
    Object? body, {
    int statusCode = 200,
  }) {
    return http.Response(
      jsonEncode(body),
      statusCode,
      headers: const {'content-type': 'application/json'},
      request: request,
    );
  }

  test('self-report and signed-out guards make no backend request', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return jsonResponse(request, const {});
    });

    final signedIn = repository(httpClient: client);
    await expectLater(
      signedIn.reportUser(
        UserReportDraft(
          targetUserId: 'viewer-1',
          reason: UserReportReason.other,
        ),
      ),
      throwsArgumentError,
    );

    final signedOut = repository(httpClient: client, viewerId: null);
    await expectLater(signedOut.unblock('user-2'), throwsStateError);
    await expectLater(signedOut.fetchBlockedUsers(), throwsStateError);
    expect(requestCount, 0);
  });

  test(
    'following and blocked RPCs apply their known relationship state',
    () async {
      final requestedPaths = <String>[];
      final client = MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path.endsWith('/rpc/get_my_following')) {
          return jsonResponse(request, [
            {
              'id': 'followed-1',
              'display_name': 'Followed',
              'is_following': false,
            },
          ]);
        }
        if (request.url.path.endsWith('/rpc/get_my_blocked_users')) {
          return jsonResponse(request, [
            {
              'id': 'blocked-1',
              'display_name': 'Blocked',
              'is_blocked_by_viewer': false,
            },
          ]);
        }
        return jsonResponse(request, {
          'message': 'unexpected',
        }, statusCode: 404);
      });
      final repo = repository(httpClient: client);

      final following = await repo.fetchFollowing('viewer-1');
      final blocked = await repo.fetchBlockedUsers();

      expect(following.single.isFollowing, isTrue);
      expect(blocked.single.isBlockedByViewer, isTrue);
      expect(
        requestedPaths,
        containsAll([
          '/rest/v1/rpc/get_my_following',
          '/rest/v1/rpc/get_my_blocked_users',
        ]),
      );
    },
  );

  test(
    'profile fetch uses caller-bound RPC for followed private profiles',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/rest/v1/rpc/get_social_profile');
        expect(jsonDecode(request.body), {'p_user_id': 'private-1'});
        return jsonResponse(request, [
          {
            'id': 'private-1',
            'display_name': 'Private Followed',
            'is_following': true,
            'is_blocked_by_viewer': false,
          },
        ]);
      });

      final profile = await repository(
        httpClient: client,
      ).fetchProfile('private-1');

      expect(profile.id, 'private-1');
      expect(profile.displayName, 'Private Followed');
      expect(profile.isFollowing, isTrue);
    },
  );

  test('follow, unfollow, block, and unblock use caller-owned keys', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        '',
        request.method == 'DELETE' ? 204 : 201,
        request: request,
      );
    });
    final repo = repository(httpClient: client);

    await repo.follow('user-2');
    await repo.unfollow('user-2');
    await repo.block('user-3');
    await repo.unblock('user-3');

    expect(requests.map((request) => request.method), [
      'POST',
      'DELETE',
      'POST',
      'DELETE',
    ]);
    expect(jsonDecode(requests[0].body), {
      'follower_id': 'viewer-1',
      'followee_id': 'user-2',
    });
    expect(
      requests[1].url.queryParameters,
      containsPair('follower_id', 'eq.viewer-1'),
    );
    expect(
      requests[1].url.queryParameters,
      containsPair('followee_id', 'eq.user-2'),
    );
    expect(jsonDecode(requests[2].body), {
      'blocker_id': 'viewer-1',
      'blocked_id': 'user-3',
    });
    expect(
      requests[3].url.queryParameters,
      containsPair('blocker_id', 'eq.viewer-1'),
    );
    expect(
      requests[3].url.queryParameters,
      containsPair('blocked_id', 'eq.user-3'),
    );
  });

  test('durable report survives a later evidence upload failure', () async {
    final requestPaths = <String>[];
    var functionCalls = 0;
    final client = MockClient((request) async {
      requestPaths.add(request.url.path);
      if (request.url.path == '/functions/v1/submit-report') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, containsPair('target_user_id', 'user-2'));
        expect(body, containsPair('kind', 'standard'));
        expect(body, containsPair('reason', 'harassment_threat'));
        expect(body, containsPair('detail', 'details'));
        return jsonResponse(request, {'report_id': 42}, statusCode: 201);
      }
      if (request.url.path == '/functions/v1/report-evidence-upload') {
        functionCalls++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body, containsPair('report_id', '42'));
        return functionCalls == 1
            ? jsonResponse(request, {'ok': true})
            : jsonResponse(request, {
                'error': 'upload failed',
              }, statusCode: 500);
      }
      return jsonResponse(request, {'message': 'unexpected'}, statusCode: 404);
    });
    final evidence = ReportEvidenceUpload(
      bytes: Uint8List.fromList([1, 2, 3]),
      contentType: 'image/png',
      extension: 'png',
    );

    final result = await repository(httpClient: client).reportUser(
      UserReportDraft(
        targetUserId: 'user-2',
        reason: UserReportReason.harassmentThreat,
        detail: '  details  ',
        evidence: [evidence, evidence],
      ),
    );

    expect(result.reportId, '42');
    expect(result.uploadedEvidenceCount, 1);
    expect(result.failedEvidenceCount, 1);
    expect(requestPaths.first, '/functions/v1/submit-report');
    expect(functionCalls, 2);
  });

  test('invalid report id stops before evidence upload', () async {
    var functionCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/functions/v1/submit-report') {
        return jsonResponse(request, {'report_id': null}, statusCode: 201);
      }
      functionCalls++;
      return jsonResponse(request, {'ok': true});
    });
    final evidence = ReportEvidenceUpload(
      bytes: Uint8List.fromList([1]),
      contentType: 'image/png',
      extension: 'png',
    );

    await expectLater(
      repository(httpClient: client).reportUser(
        UserReportDraft(
          targetUserId: 'user-2',
          reason: UserReportReason.spamFraud,
          evidence: [evidence],
        ),
      ),
      throwsStateError,
    );
    expect(functionCalls, 0);
  });

  test('report history parses the safe server response', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/functions/v1/my-reports');
      return jsonResponse(request, {
        'reports': [
          {
            'id': 7,
            'kind': 'standard',
            'reason': 'spam_fraud',
            'status': 'pending',
            'created_at': '2026-09-06T08:00:00Z',
            'due_at': '2026-09-13T08:00:00Z',
            'is_overdue': false,
          },
        ],
      });
    });

    final reports = await repository(httpClient: client).fetchMyReports();
    expect(reports, hasLength(1));
    expect(reports.single.id, '7');
    expect(reports.single.reason, UserReportReason.spamFraud);
  });
}
