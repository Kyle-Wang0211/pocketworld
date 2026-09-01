// 这张表是脚本从上游 yaml 生成的,但生成脚本不在 CI 里跑。
// 这些测试守的是"生成物没被手改坏"以及"关键性质仍然成立"。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_extrinsics.dart';

void main() {
  test('q_bc 是上游 18 款 iPhone 逐位相同的那个值', () {
    // 若这条挂了,说明有人改了旋转 —— 那是灾难级字段。
    expect(kIosCameraImuQbc, <double>[-0.7071068, 0.7071068, 0.0, 0.0]);
  });

  test('q_bc 近似单位四元数(上游只写到 7 位小数)', () {
    final double n2 = kIosCameraImuQbc.fold<double>(
      0,
      (double a, double b) => a + b * b,
    );
    // 上游写的是 0.7071068,不是 0.70710678118…,所以平方和是 1.000000057。
    // 差 5.7e-8 —— 对应约 0.0000016 度的旋转误差,可忽略。
    // 容差不能收到 1e-9:那会把"照抄上游"判成失败。
    expect(n2, closeTo(1.0, 1e-6));
    expect(
      (n2 - 1.0).abs(),
      greaterThan(1e-9),
      reason:
          '若这条挂了,说明有人把上游的值"修正"成了精确值 —— '
          '那就不再是逐字复刻,应重新确认是否有意为之',
    );
  });

  test('q_bc 不是 identity —— 这正是之前的 bug', () {
    // identity 会让视觉-惯性对齐永远不收敛(真机 5731 帧零位姿)。
    expect(kIosCameraImuQbc, isNot(<double>[0.0, 0.0, 0.0, 1.0]));
  });

  test('表覆盖 20 个 hw.machine 标识符 / 18 款机型', () {
    expect(kIosCameraImuPbc.length, 20);
    expect(
      kIosCameraImuPbc.values
          .map((List<double> v) => v.join(','))
          .toSet()
          .length,
      17,
    ); // 上游 16e 复用了 14 Pro 的值
  });

  test('每个 p_bc 是 3 维且量级合理(< 10cm)', () {
    for (final MapEntry<String, List<double>> e in kIosCameraImuPbc.entries) {
      expect(e.value.length, 3, reason: e.key);
      for (final double v in e.value) {
        expect(v.abs(), lessThan(0.10), reason: '${e.key} 杠杆臂超过 10cm');
      }
    }
  });

  test('本机 iPhone 15,2 查得到上游标定值', () {
    final CameraImuExtrinsic e = CameraImuExtrinsic.forIosMachine('iPhone15,2');
    expect(e.pbc, <double>[0.03290364, -0.00696553, -0.00286231]);
    expect(e.provenance, FieldProvenance.deviceApi);
  });

  test('未知机型回退到中位数,且 provenance 可区分', () {
    final CameraImuExtrinsic e = CameraImuExtrinsic.forIosMachine('iPhone99,9');
    expect(e.pbc, kIosCameraImuPbcFallback);
    expect(e.provenance, FieldProvenance.sharedDefault);
    // 🔑 回退时旋转仍是正确的那个 —— 这是本设计的全部要点。
    expect(e.qbc, kIosCameraImuQbc);
  });

  test('16e 被标成非标定值(上游是 14 Pro 的逐字节拷贝)', () {
    expect(kIosCameraImuPbcCopied, contains('iPhone17,5'));
    final CameraImuExtrinsic e = CameraImuExtrinsic.forIosMachine('iPhone17,5');
    expect(
      e.provenance,
      FieldProvenance.placeholder,
      reason: '查得到值但不是该机型标定的 —— 遥测里必须与真标定可区分',
    );
    expect(e.qbc, kIosCameraImuQbc, reason: '旋转仍必须是正确的那个');
  });

  test('14 Pro 与 14 Pro Max 不是拷贝(证明其余 17 份是真标定)', () {
    final CameraImuExtrinsic a = CameraImuExtrinsic.forIosMachine('iPhone15,2');
    final CameraImuExtrinsic b = CameraImuExtrinsic.forIosMachine('iPhone15,3');
    expect(a.pbc, isNot(b.pbc));
    expect(a.provenance, FieldProvenance.deviceApi);
    expect(b.provenance, FieldProvenance.deviceApi);
  });

  test('machine 为 null 也不回到 identity', () {
    expect(CameraImuExtrinsic.forIosMachine(null).qbc, kIosCameraImuQbc);
  });
}
