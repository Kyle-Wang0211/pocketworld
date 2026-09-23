// pw_dense_frame_v3_test.dart — the layout gate for `pwdense_frame_v3_t` (vendor/pw_dense/include/pwdense_c.h,
// ABI v3 2026-09-16). Dart's FFI struct is hand-written, so nothing but this test stands between a reordered
// field and the C++ reading garbage pointers. The offsets below are the C layout on every 64-bit ABI we ship:
//   frame_id 0 (+4 pad) | fx 8 fy 16 cx 24 cy 32 | image_w 40 image_h 48 | q_wxyz[4] 56 | t[3] 88
//   jpeg_path 112 | nv12_path 120 | nv12_width 128 | nv12_height 132 | nv12_matrix 136 | reserved0 140 -> 144
// The first 11 members must stay byte-for-byte pwdense_frame_t, so a v3 struct is a v2 struct plus a tail.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/pw_dense_ffi.dart';

const int _oFrameId = 0;
const int _oFx = 8, _oFy = 16, _oCx = 24, _oCy = 32;
const int _oImageW = 40, _oImageH = 48;
const int _oQ = 56, _oT = 88;
const int _oJpegPath = 112, _oNv12Path = 120;
const int _oNv12Width = 128, _oNv12Height = 132, _oNv12Matrix = 136, _oReserved0 = 140;
const int _sizeOfFrameV3 = 144;

PwDenseFrame _frame({String jpegPath = '/a.jpg', String? nv12Path, int? w, int? h}) => PwDenseFrame(
      frameId: 0x11223344,
      fx: 1.5,
      fy: 2.5,
      cx: 3.5,
      cy: 4.5,
      imageW: 1920,
      imageH: 1440,
      qWxyz: const [0.25, 0.5, 0.75, 1.25],
      t: const [-1.5, -2.5, -3.5],
      jpegPath: jpegPath,
      nv12Path: nv12Path,
      nv12Width: w,
      nv12Height: h,
    );

void main() {
  test('the v3 struct is 144 bytes and every field sits where pwdense_c.h puts it', () {
    final m = debugMarshalPwDenseFrameV3(_frame(jpegPath: '', nv12Path: '/tmp/f.nv12', w: 1920, h: 1440));
    expect(m.structSize, _sizeOfFrameV3);
    expect(m.bytes.length, _sizeOfFrameV3);
    final b = ByteData.sublistView(m.bytes);
    expect(b.getInt32(_oFrameId, Endian.host), 0x11223344);
    expect(b.getFloat64(_oFx, Endian.host), 1.5);
    expect(b.getFloat64(_oFy, Endian.host), 2.5);
    expect(b.getFloat64(_oCx, Endian.host), 3.5);
    expect(b.getFloat64(_oCy, Endian.host), 4.5);
    expect(b.getFloat64(_oImageW, Endian.host), 1920);
    expect(b.getFloat64(_oImageH, Endian.host), 1440);
    for (var k = 0; k < 4; k++) {
      expect(b.getFloat64(_oQ + 8 * k, Endian.host), const [0.25, 0.5, 0.75, 1.25][k]);
    }
    for (var k = 0; k < 3; k++) {
      expect(b.getFloat64(_oT + 8 * k, Endian.host), const [-1.5, -2.5, -3.5][k]);
    }
    expect(b.getInt32(_oNv12Width, Endian.host), 1920);
    expect(b.getInt32(_oNv12Height, Endian.host), 1440);
    expect(b.getInt32(_oNv12Matrix, Endian.host), kPwvaNv12Matrix);
    expect(b.getInt32(_oReserved0, Endian.host), 0, reason: 'reserved0 must be 0 (pwdense_c.h)');
    expect(b.getUint64(_oJpegPath, Endian.host), 0, reason: 'empty jpegPath must marshal as NULL');
    expect(b.getUint64(_oNv12Path, Endian.host), isNot(0));
  });

  test('the nv12 matrix constant is the one the host probe pinned', () {
    // Pinned 2026-09-16 by the host probe (nv12_matrix_probe.mm): Apple tags the transferred 420f buffer
    // ITU_R_709_2 and libyuv kYvuF709Constants matches Apple's own decode within mean 0.03 / max 1.
    expect(kPwvaNv12Matrix, 1); // 0 = BT.601 full range, 1 = BT.709 full range
  });

  test('an NV12 frame carries path + size and NULLs jpeg_path', () {
    final m = debugMarshalPwDenseFrameV3(_frame(jpegPath: '', nv12Path: '/tmp/cache/abc_0007.jpg.nv12', w: 640, h: 480));
    expect(m.jpegPath, isNull);
    expect(m.nv12Path, '/tmp/cache/abc_0007.jpg.nv12');
    final b = ByteData.sublistView(m.bytes);
    expect(b.getInt32(_oNv12Width, Endian.host), 640);
    expect(b.getInt32(_oNv12Height, Endian.host), 480);
    expect(b.getInt32(_oNv12Matrix, Endian.host), kPwvaNv12Matrix);
  });

  test('a JPEG frame (the v1/v2 case) keeps jpeg_path and leaves the whole nv12 tail zero', () {
    final m = debugMarshalPwDenseFrameV3(_frame(jpegPath: '/var/photos/0001.jpg'));
    expect(m.jpegPath, '/var/photos/0001.jpg');
    expect(m.nv12Path, isNull);
    final b = ByteData.sublistView(m.bytes);
    expect(b.getUint64(_oJpegPath, Endian.host), isNot(0));
    expect(b.getUint64(_oNv12Path, Endian.host), 0);
    expect(b.getInt32(_oNv12Width, Endian.host), 0);
    expect(b.getInt32(_oNv12Height, Endian.host), 0);
    expect(b.getInt32(_oNv12Matrix, Endian.host), 0);
    expect(b.getInt32(_oReserved0, Endian.host), 0);
  });

  test('hasNv12 is what decides run3-vs-run2, and an empty path is not an NV12 source', () {
    expect(_frame().hasNv12, isFalse);
    expect(_frame(nv12Path: '').hasNv12, isFalse);
    expect(_frame(nv12Path: '/tmp/f.nv12').hasNv12, isTrue);
  });

  test('the binding now accepts ABI 3 (and still 1 and 2)', () {
    expect(pwDenseAbiVersionMin, 1);
    expect(pwDenseAbiVersionMax, 3);
  });
}
