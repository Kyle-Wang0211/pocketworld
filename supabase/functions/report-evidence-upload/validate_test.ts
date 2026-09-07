import { assertEquals } from "jsr:@std/assert@1.0.19";
import { validateEvidence } from "./validate.ts";

const validPng = decodeBase64(
  "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4AWP8DwQMQMDEAAUAPfgEADYYS7QAAAAASUVORK5CYII=",
);
const validJpeg = decodeBase64(
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD6pooooA//2Q==",
);

Deno.test("decodes complete metadata-free JPEG and PNG", async () => {
  assertEquals(await validateEvidence(validJpeg, "image/jpeg", "jpg"), {
    ok: true,
    width: 2,
    height: 2,
  });
  assertEquals(await validateEvidence(validPng, "image/png", "png"), {
    ok: true,
    width: 2,
    height: 2,
  });
});

Deno.test("rejects truncated containers that only advertise dimensions", async () => {
  const fakeJpeg = new Uint8Array([
    0xff,
    0xd8,
    0xff,
    0xc0,
    0,
    7,
    8,
    0,
    2,
    0,
    2,
  ]);
  const fakePng = validPng.slice(0, 33);
  assertEquals(
    (await validateEvidence(fakeJpeg, "image/jpeg", "jpg")).ok,
    false,
  );
  assertEquals((await validateEvidence(fakePng, "image/png", "png")).ok, false);
});

Deno.test("rejects oversized JPEG dimensions before full decode", async () => {
  const oversized = new Uint8Array(validJpeg);
  const sof = findMarker(oversized, 0xc0);
  oversized[sof + 6] = 0x10;
  oversized[sof + 7] = 0x00;
  const verdict = await validateEvidence(oversized, "image/jpeg", "jpg");
  assertEquals(verdict.ok, false);
  if (!verdict.ok) assertEquals(verdict.reason, "dimensions_too_large");
});

Deno.test("rejects metadata and trailing bytes", async () => {
  const jpegWithExif = new Uint8Array([
    ...validJpeg.slice(0, 2),
    0xff,
    0xe1,
    0,
    4,
    1,
    2,
    ...validJpeg.slice(2),
  ]);
  const pngWithTrailing = new Uint8Array([...validPng, 1]);
  assertEquals(
    (await validateEvidence(jpegWithExif, "image/jpeg", "jpg")).ok,
    false,
  );
  assertEquals(
    (await validateEvidence(pngWithTrailing, "image/png", "png")).ok,
    false,
  );
});

Deno.test("rejects type, extension, and size mismatches", async () => {
  assertEquals(
    (await validateEvidence(validJpeg, "image/png", "png")).ok,
    false,
  );
  assertEquals(
    (await validateEvidence(validJpeg, "image/jpeg", "png")).ok,
    false,
  );
  assertEquals(
    (await validateEvidence(
      new Uint8Array(5 * 1024 * 1024 + 1),
      "image/jpeg",
      "jpg",
    )).ok,
    false,
  );
});

function decodeBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function findMarker(bytes: Uint8Array, marker: number): number {
  for (let i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] === 0xff && bytes[i + 1] === marker) return i + 1;
  }
  throw new Error("marker not found");
}
