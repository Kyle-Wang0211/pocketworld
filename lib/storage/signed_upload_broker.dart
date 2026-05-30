import 'package:supabase_flutter/supabase_flutter.dart';

class SignedUploadBrokerException implements Exception {
  final String message;
  const SignedUploadBrokerException(this.message);

  @override
  String toString() => 'SignedUploadBrokerException: $message';
}

class SignedUploadCredential {
  final String bucket;
  final String path;
  final String token;
  final String signedUrl;
  final int expiresInSeconds;

  const SignedUploadCredential({
    required this.bucket,
    required this.path,
    required this.token,
    required this.signedUrl,
    required this.expiresInSeconds,
  });

  factory SignedUploadCredential.fromJson(Map<String, dynamic> json) {
    final bucket = json['bucket'];
    final path = json['path'];
    final token = json['token'];
    final signedUrl = json['signed_url'] ?? json['signedUrl'];
    final expiresInSeconds =
        json['expires_in_seconds'] ?? json['expiresInSeconds'];
    if (bucket is! String ||
        path is! String ||
        token is! String ||
        signedUrl is! String ||
        expiresInSeconds is! int) {
      throw const SignedUploadBrokerException(
        'upload broker returned an invalid credential',
      );
    }
    return SignedUploadCredential(
      bucket: bucket,
      path: path,
      token: token,
      signedUrl: signedUrl,
      expiresInSeconds: expiresInSeconds,
    );
  }
}

class SignedUploadBroker {
  final SupabaseClient _client;
  final String functionName;

  SignedUploadBroker({
    SupabaseClient? client,
    this.functionName = 'storage-sign-upload',
  }) : _client = client ?? Supabase.instance.client;

  Future<SignedUploadCredential> createCredential({
    required String bucket,
    required String path,
    required String contentType,
    required int bytes,
    required String role,
    String? scanId,
    String? clientCaptureId,
    String? sha256,
    String? workId,
  }) async {
    final body = <String, Object?>{
      'bucket': bucket,
      'path': path,
      'content_type': contentType,
      'bytes': bytes,
      'role': role,
      'scan_id': ?scanId,
      'client_capture_id': ?clientCaptureId,
      'sha256': ?sha256,
      'work_id': ?workId,
    };

    try {
      final response = await _client.functions.invoke(functionName, body: body);
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return SignedUploadCredential.fromJson(data);
      }
      if (data is Map) {
        return SignedUploadCredential.fromJson(Map<String, dynamic>.from(data));
      }
      throw const SignedUploadBrokerException(
        'upload broker returned a non-object response',
      );
    } on FunctionException catch (e) {
      throw SignedUploadBrokerException(_functionErrorMessage(e));
    }
  }
}

String _functionErrorMessage(FunctionException error) {
  final details = error.details;
  if (details is Map) {
    final code = details['error'] ?? details['code'];
    final message = details['message'] ?? details['detail'];
    if (code != null && message != null) {
      return '$code: $message';
    }
    if (code != null) return code.toString();
    if (message != null) return message.toString();
  }
  return error.toString();
}
