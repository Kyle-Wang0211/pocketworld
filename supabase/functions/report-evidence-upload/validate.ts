export const MAX_EVIDENCE_BYTES = 5 * 1024 * 1024;
export const MAX_EVIDENCE_DIMENSION = 2048;

export type EvidenceVerdict =
  | { ok: true; width: number; height: number }
  | { ok: false; reason: string };

export async function validateEvidence(
  bytes: Uint8Array,
  contentType: unknown,
  extension: unknown,
): Promise<EvidenceVerdict> {
  if (bytes.length === 0) return reject("empty");
  if (bytes.length > MAX_EVIDENCE_BYTES) return reject("too_large");
  if (contentType === "image/jpeg" && extension === "jpg") {
    return await validateDecodedImage(bytes, "image/jpeg", validateJpeg(bytes));
  }
  if (contentType === "image/png" && extension === "png") {
    return await validateDecodedImage(bytes, "image/png", validatePng(bytes));
  }
  return reject("type_extension_mismatch");
}

function validateJpeg(bytes: Uint8Array): EvidenceVerdict {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    return reject("not_jpeg");
  }
  let offset = 2;
  let dimensions: { width: number; height: number } | null = null;
  let sawScan = false;
  while (offset + 1 < bytes.length) {
    // Some valid encoders place padding bytes between marker segments. The
    // platform decoder below remains the authority for syntactic validity.
    if (bytes[offset] !== 0xff) {
      offset++;
      continue;
    }
    while (offset < bytes.length && bytes[offset] === 0xff) offset++;
    if (offset >= bytes.length) return reject("malformed_jpeg");
    const marker = bytes[offset++];
    if (marker === 0xd9) break;
    if (marker === 0xda) {
      sawScan = true;
      break;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) return reject("truncated_jpeg");
    const length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) {
      return reject("truncated_jpeg");
    }
    if ((marker >= 0xe1 && marker <= 0xef) || marker === 0xfe) {
      return reject("metadata_not_allowed");
    }
    if (isStartOfFrame(marker)) {
      if (length < 8) return reject("malformed_jpeg_dimensions");
      dimensions = {
        height: (bytes[offset + 3] << 8) | bytes[offset + 4],
        width: (bytes[offset + 5] << 8) | bytes[offset + 6],
      };
      const dimensionVerdict = validateDimensions(
        dimensions.width,
        dimensions.height,
      );
      if (!dimensionVerdict.ok) return dimensionVerdict;
    }
    offset += length;
  }
  if (!dimensions) return reject("missing_dimensions");
  if (!sawScan) return reject("missing_scan");
  if (
    bytes.length < 2 || bytes[bytes.length - 2] !== 0xff ||
    bytes[bytes.length - 1] !== 0xd9
  ) return reject("missing_eoi");
  return { ok: true, width: dimensions.width, height: dimensions.height };
}

function validatePng(bytes: Uint8Array): EvidenceVerdict {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 || !signature.every((value, i) => bytes[i] === value)) {
    return reject("not_png");
  }
  let offset = 8;
  let dimensions: { width: number; height: number } | null = null;
  let sawImageData = false;
  let sawEnd = false;
  const forbidden = new Set([
    "tEXt",
    "zTXt",
    "iTXt",
    "eXIf",
    "iCCP",
    "tIME",
    "pHYs",
    "sPLT",
  ]);
  while (offset + 12 <= bytes.length) {
    const length = readUint32(bytes, offset);
    if (length > bytes.length - offset - 12) return reject("truncated_png");
    const type = new TextDecoder().decode(
      bytes.subarray(offset + 4, offset + 8),
    );
    if (forbidden.has(type)) return reject("metadata_not_allowed");
    if (type === "IHDR") {
      if (offset !== 8 || length !== 13) return reject("malformed_png_header");
      dimensions = {
        width: readUint32(bytes, offset + 8),
        height: readUint32(bytes, offset + 12),
      };
    }
    if (type === "IDAT") sawImageData = true;
    offset += 12 + length;
    if (type === "IEND") {
      if (length !== 0) return reject("malformed_png_end");
      sawEnd = true;
      break;
    }
  }
  if (!dimensions) return reject("missing_dimensions");
  if (!sawImageData) return reject("missing_image_data");
  if (!sawEnd) return reject("missing_png_end");
  if (offset !== bytes.length) return reject("trailing_data");
  return validateDimensions(dimensions.width, dimensions.height);
}

async function validateDecodedImage(
  bytes: Uint8Array,
  contentType: string,
  structural: EvidenceVerdict,
): Promise<EvidenceVerdict> {
  if (!structural.ok) return structural;
  try {
    const bitmap = await createImageBitmap(
      new Blob([new Uint8Array(bytes)], { type: contentType }),
    );
    const decoded = { width: bitmap.width, height: bitmap.height };
    bitmap.close();
    if (
      structural.width > 0 &&
      (decoded.width !== structural.width ||
        decoded.height !== structural.height)
    ) return reject("dimension_mismatch");
    return validateDimensions(decoded.width, decoded.height);
  } catch {
    return reject("decode_failed");
  }
}

function validateDimensions(width: number, height: number): EvidenceVerdict {
  if (width < 1 || height < 1) return reject("invalid_dimensions");
  if (width > MAX_EVIDENCE_DIMENSION || height > MAX_EVIDENCE_DIMENSION) {
    return reject("dimensions_too_large");
  }
  return { ok: true, width, height };
}

function readUint32(bytes: Uint8Array, offset: number): number {
  return new DataView(bytes.buffer, bytes.byteOffset + offset, 4).getUint32(0);
}

function isStartOfFrame(marker: number): boolean {
  return marker >= 0xc0 && marker <= 0xcf &&
    ![0xc4, 0xc8, 0xcc].includes(marker);
}

function reject(reason: string): EvidenceVerdict {
  return { ok: false, reason };
}
