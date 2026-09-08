import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_slot_naming.dart';

void main() {
  test('补拍序号必须接在已有最大值之后', () {
    expect(maxFrameSeqInNames(const []), 0);
    expect(maxFrameSeqInNames(const ['cell_1_slot_0_tap-7.jpg']), 7);
    // .json 伴生名同基名,不能因为扩展名不同就漏掉
    expect(maxFrameSeqInNames(const ['cell_1_slot_0_tap-7.json']), 7);
    // tap/cap 共用一个序号空间,取全局最大
    expect(
      maxFrameSeqInNames(const [
        'cell_1_slot_0_tap-7.jpg',
        'cell_2_slot_1_cap-19.jpg',
        'cell_3_slot_2_tap-4.jpg',
      ]),
      19,
    );
    // 认不出的名字记 0 而不是崩 —— 一个陌生文件不该让补拍失败
    expect(
      maxFrameSeqInNames(const [
        'cell_1_slot_0.jpg', // 老式名
        'thumb.png',
        '.DS_Store',
        'cell_1_slot_0_tap-3.jpg',
      ]),
      3,
    );
    // 多位数不能被截断
    expect(maxFrameSeqInNames(const ['cell_0_slot_0_cap-1234.jpg']), 1234);
  });
}
