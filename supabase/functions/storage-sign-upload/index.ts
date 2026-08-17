// storage-sign-upload
// ----------------------------------------------------------------------
// Authenticated short-lived upload credential broker.
//
// The Flutter app must not create Storage signed-upload URLs directly.
// Instead it calls this function with the intended bucket/path/role.
// The function verifies the user's JWT, checks ownership and path shape,
// then uses the service role to mint a one-shot Supabase Storage upload
// token. Storage insert/update RLS for brokered buckets can therefore be
// closed to clients while the app still uploads raw captures efficiently.

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';

const EXPIRES_IN_SECONDS = 60;

type JsonBody = Record<string, unknown>;

type UploadRequest = {
  bucket: string;
  path: string;
  contentType: string;
  bytes: number;
  role: string;
  scanId: string | null;
  clientCaptureId: string | null;
  sha256: string | null;
  workId: string | null;
};

type ValidatedRequest = UploadRequest & {
  auditTargetId: string | null;
};

class RequestError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      throw new RequestError(
        500,
        'server_misconfigured',
        'Supabase service environment is missing.',
      );
    }

    const jwt = bearerToken(req);
    const supabase = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    });
    const { data: userData, error: userError } = await supabase.auth.getUser(
      jwt,
    );
    const user = userData.user;
    if (userError || !user) {
      throw new RequestError(401, 'unauthorized', 'Invalid user session.');
    }

    let body: JsonBody;
    try {
      body = await req.json();
    } catch {
      throw new RequestError(400, 'invalid_json', 'Request body is not JSON.');
    }

    const uploadRequest = parseBody(body);
    const validated = await validateUploadRequest(
      supabase,
      user.id,
      uploadRequest,
    );

    const { data, error } = await supabase.storage
      .from(validated.bucket)
      .createSignedUploadUrl(validated.path);
    if (error || !data) {
      throw new RequestError(
        502,
        'storage_sign_failed',
        error?.message ?? 'Storage did not return a credential.',
      );
    }

    await insertAuditLog(supabase, user.id, validated);

    return jsonResponse({
      bucket: validated.bucket,
      path: validated.path,
      token: data.token,
      signed_url: data.signedUrl,
      expires_in_seconds: EXPIRES_IN_SECONDS,
    });
  } catch (error) {
    if (error instanceof RequestError) {
      return jsonResponse(
        { error: error.code, message: error.message },
        error.status,
      );
    }
    return jsonResponse(
      { error: 'unexpected_error', message: String(error) },
      500,
    );
  }
});

function bearerToken(req: Request): string {
  const header = req.headers.get('Authorization') ?? '';
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match?.[1]) {
    throw new RequestError(401, 'missing_authorization', 'Missing bearer JWT.');
  }
  return match[1].trim();
}

function parseBody(body: JsonBody): UploadRequest {
  const bucket = requiredString(body, 'bucket');
  const path = requiredString(body, 'path');
  const contentType = normalizeContentType(requiredString(body, 'content_type'));
  const bytes = requiredSafeInteger(body, 'bytes');
  const role = requiredString(body, 'role');

  if (path.startsWith('/') || path.includes('..') || path.includes('//')) {
    throw new RequestError(400, 'invalid_path', 'Storage path is invalid.');
  }
  if (bytes <= 0) {
    throw new RequestError(400, 'invalid_size', 'Object size must be positive.');
  }

  return {
    bucket,
    path,
    contentType,
    bytes,
    role,
    scanId: optionalString(body, 'scan_id'),
    clientCaptureId: optionalString(body, 'client_capture_id'),
    sha256: optionalString(body, 'sha256'),
    workId: optionalString(body, 'work_id'),
  };
}

async function validateUploadRequest(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  request: UploadRequest,
): Promise<ValidatedRequest> {
  if (request.bucket === 'scans') {
    return await validateScanUpload(supabase, userId, request);
  }
  if (request.bucket === 'thumbnails') {
    return await validateThumbnailUpload(supabase, userId, request);
  }
  throw new RequestError(
    403,
    'bucket_not_brokered',
    'This bucket is not upload-broker enabled.',
  );
}

async function validateScanUpload(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  request: UploadRequest,
): Promise<ValidatedRequest> {
  const scanId = request.scanId;
  if (!scanId || !isUuid(scanId)) {
    throw new RequestError(400, 'invalid_scan_id', 'scan_id is required.');
  }
  if (!request.path.startsWith(`${userId}/${scanId}/`)) {
    throw new RequestError(
      403,
      'path_not_owned',
      'Scan upload path must be under the caller and scan id.',
    );
  }
  validateScanObjectShape(request);

  const { data, error } = await supabase
    .from('scans')
    .select('id,status')
    .eq('id', scanId)
    .eq('user_id', userId)
    .maybeSingle();
  if (error) {
    throw new RequestError(500, 'scan_lookup_failed', error.message);
  }
  if (!data) {
    throw new RequestError(
      404,
      'scan_not_found_or_not_owned',
      'Scan does not exist for this user.',
    );
  }
  if (data.status !== 'uploading') {
    throw new RequestError(
      409,
      'scan_not_uploading',
      'Signed upload credentials are only issued while a scan is uploading.',
    );
  }

  return { ...request, auditTargetId: scanId };
}

function validateScanObjectShape(request: UploadRequest) {
  const role = request.role;
  const path = request.path;
  switch (role) {
    case 'frame_image':
      requireContentType(request, 'image/jpeg');
      requireMaxBytes(request, 30 * 1024 * 1024);
      requirePath(path.includes('/frames/') && /\.(jpe?g)$/i.test(path));
      break;
    case 'frame_metadata':
      requireContentType(request, 'application/json');
      requireMaxBytes(request, 2 * 1024 * 1024);
      requirePath(path.includes('/frames/') && path.endsWith('.json'));
      break;
    case 'cover_thumbnail':
      requireContentType(request, 'image/jpeg');
      requireMaxBytes(request, 30 * 1024 * 1024);
      requirePath(path.endsWith('/preview/cover.jpg'));
      break;
    case 'cloud_manifest':
      requireContentType(request, 'application/json');
      requireMaxBytes(request, 20 * 1024 * 1024);
      requirePath(path.endsWith('/manifest/capture_manifest.json'));
      break;
    default:
      throw new RequestError(
        400,
        'invalid_role',
        'Unsupported scan upload role.',
      );
  }
}

async function validateThumbnailUpload(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  request: UploadRequest,
): Promise<ValidatedRequest> {
  const workId = request.workId;
  if (!workId || !isUuid(workId)) {
    throw new RequestError(400, 'invalid_work_id', 'work_id is required.');
  }
  if (request.role !== 'auto_thumbnail') {
    throw new RequestError(
      400,
      'invalid_role',
      'Unsupported thumbnail upload role.',
    );
  }
  // PublishService ships the capture route's official_sparse_thumb.png
  // verbatim (image/png) since 2026-08-16; bake-style callers still send
  // JPEG. Accept exactly those two, and pin the path extension to the
  // declared content type so the stored object never lies about its
  // bytes. (jpeg-only here silently killed every published thumbnail:
  // the client's catch ate the 415 and publish still reported success.)
  const thumbnailExtByContentType: Record<string, string> = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
  };
  const thumbnailExt = thumbnailExtByContentType[request.contentType];
  if (!thumbnailExt) {
    throw new RequestError(
      415,
      'unsupported_content_type',
      'Expected image/jpeg or image/png.',
    );
  }
  requireMaxBytes(request, 10 * 1024 * 1024);
  if (request.path !== `${userId}/${workId}.${thumbnailExt}`) {
    throw new RequestError(
      403,
      'path_not_owned',
      'Thumbnail upload path must match the caller and work id.',
    );
  }

  const { data, error } = await supabase
    .from('works')
    .select('id')
    .eq('id', workId)
    .eq('user_id', userId)
    .maybeSingle();
  if (error) {
    throw new RequestError(500, 'work_lookup_failed', error.message);
  }
  if (!data) {
    throw new RequestError(
      404,
      'work_not_found_or_not_owned',
      'Work does not exist for this user.',
    );
  }

  return { ...request, auditTargetId: workId };
}

async function insertAuditLog(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  request: ValidatedRequest,
) {
  try {
    await supabase.from('audit_logs').insert({
      actor_id: userId,
      action: 'storage.signed_upload_issued',
      target_type: 'storage',
      target_id: request.auditTargetId,
      metadata: {
        bucket: request.bucket,
        path: request.path,
        role: request.role,
        bytes: request.bytes,
        content_type: request.contentType,
        scan_id: request.scanId,
        client_capture_id: request.clientCaptureId,
        sha256: request.sha256,
        work_id: request.workId,
        expires_in_seconds: EXPIRES_IN_SECONDS,
        credential_strategy: 'edge_broker_signed_upload_url_v1',
      },
    });
  } catch (error) {
    console.warn('storage-sign-upload audit insert failed', error);
  }
}

function requiredString(body: JsonBody, key: string): string {
  const value = body[key];
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new RequestError(400, 'invalid_input', `${key} is required.`);
  }
  return value.trim();
}

function optionalString(body: JsonBody, key: string): string | null {
  const value = body[key];
  if (value == null) return null;
  if (typeof value !== 'string') {
    throw new RequestError(400, 'invalid_input', `${key} must be a string.`);
  }
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

function requiredSafeInteger(body: JsonBody, key: string): number {
  const value = body[key];
  if (
    typeof value !== 'number' ||
    !Number.isSafeInteger(value)
  ) {
    throw new RequestError(400, 'invalid_input', `${key} must be an integer.`);
  }
  return value;
}

function normalizeContentType(contentType: string): string {
  return contentType.split(';', 1)[0].trim().toLowerCase();
}

function requireContentType(request: UploadRequest, expected: string) {
  if (request.contentType !== expected) {
    throw new RequestError(
      415,
      'unsupported_content_type',
      `Expected ${expected}.`,
    );
  }
}

function requireMaxBytes(request: UploadRequest, maxBytes: number) {
  if (request.bytes > maxBytes) {
    throw new RequestError(
      413,
      'object_too_large',
      `Object is larger than ${maxBytes} bytes.`,
    );
  }
}

function requirePath(ok: boolean) {
  if (!ok) {
    throw new RequestError(
      400,
      'invalid_path_for_role',
      'Storage path does not match the declared role.',
    );
  }
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
