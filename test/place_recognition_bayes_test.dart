// 似然归一化 + 贝叶斯滤波(RTAB-Map 复刻)。
//
// 这一层存在的理由:2026-09-10 未命名(5) 真机实测 —— 同场有 17 对真实重访
// (最近的 0.23 m / 5.5° / 间隔 8.5 s),而共享词比例中位 3.7%、最高 20.8%,
// 拿 stella 的 0.9 去卡它一次都开不了火。信号有(最高比中位高 5.6 倍),
// 错的是门的位置:0.9 是给「地图路标跟踪」定的,不是给「词袋共享词比例」定的。
// 补完这一层,用的就是 RTAB-Map 自己的 `LoopThr = 0.11`(它卡的是**后验**)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/place_recognition_bayes.dart';
import 'package:pocketworld_flutter/official_capture/visual_word_dictionary.dart';

void main() {
  group('常数与结构(先自证,再谈行为)', () {
    test('PredictionLC 是 Gaussian-like 且首项是虚拟地点概率', () {
      expect(kBayesPredictionLC.length, 18);
      expect(kBayesPredictionLC[0], 0.1, reason: 'VirtualPlaceProb');
      expect(kBayesPredictionLC[1], 0.36, reason: 'LoopClosureProb(留在原地)');
      expect(kBayesPredictionLC[2], 0.30, reason: '第 1 层邻居');
      // 单调下降(除首项),sigma=1.6 的形状。
      for (var i = 2; i < kBayesPredictionLC.length; i++) {
        expect(kBayesPredictionLC[i], lessThan(kBayesPredictionLC[i - 1]));
      }
      expect(kBayesVirtualPlacePrior, 0.9);
      expect(kRtabmapLoopThreshold, 0.11);
    });

    test('每一列都是概率分布(和为 1)', () {
      final m = PlacePredictionModel();
      for (final n in <int>[1, 2, 5, 20]) {
        final ids = <int>[for (var i = 1; i <= n; i++) i];
        final v = m.buildVirtualPlaceColumn(n + 1);
        expect(
          v.reduce((a, b) => a + b),
          closeTo(1.0, 1e-4),
          reason: '虚拟地点那一列,n=$n',
        );
        for (var i = 0; i < n; i++) {
          final c = m.buildColumn(ids, i);
          expect(
            c.reduce((a, b) => a + b),
            closeTo(1.0, 1e-3),
            reason: '第 $i 列(共 $n 个地点)',
          );
          expect(c[0], kBayesPredictionLC[0], reason: '首位固定是虚拟地点概率');
        }
      }
    });

    test('留在原地的概率最高,越远越低(链状图)', () {
      final m = PlacePredictionModel();
      final ids = <int>[1, 2, 3, 4, 5, 6, 7];
      final c = m.buildColumn(ids, 3); // 站在第 4 个地点
      expect(c[4], greaterThan(c[3]), reason: '原地 > 相邻');
      expect(c[3], greaterThan(c[2]), reason: '第1层 > 第2层');
      expect(c[2], greaterThan(c[1]));
    });
  });

  group('adjustLikelihood(Rtabmap.cpp:5725)', () {
    test('平庸的观测被压到 1,突出的那个才抬起来', () {
      // 造一组:一堆低值 + 一个高值。
      final raw = <int, double>{
        for (var i = 1; i <= 10; i++) i: 0.01,
        11: 0.20,
      };
      final adj = adjustLikelihood(raw);
      for (var i = 1; i <= 10; i++) {
        expect(adj[i], 1.0, reason: '没超过 mean+stdDev 的一律记 1');
      }
      expect(adj[11], greaterThan(1.0), reason: '超出的那个应当被抬起来');
      expect(adj.containsKey(-1), isTrue, reason: '虚拟地点必须在');
      expect(adj[-1], greaterThan(0), reason: 'mean/stdDev + 1');
    });

    test('全都一样时没有赢家(阳性对照:别无中生有)', () {
      final raw = <int, double>{for (var i = 1; i <= 8; i++) i: 0.05};
      final adj = adjustLikelihood(raw);
      for (var i = 1; i <= 8; i++) {
        expect(adj[i], 1.0, reason: '毫无区分度时谁都不该被抬起来');
      }
    });
  });

  group('贝叶斯后验 + LoopThr=0.11', () {
    /// 造一场:走过 n 个地点,然后**回到**第 [revisit] 个。
    /// 似然用真机量到的量级:命中 ~0.20,其余 ~0.01(未命名(5) 的中位 3.7% /
    /// 最高 20.8%,这里按同一比例造)。
    LoopHypothesis walkThenRevisit({
      required int places,
      required int revisit,
      required int ticksAtRevisit,
    }) {
      final f = PlaceBayesFilter();
      LoopHypothesis? h;
      // 走过去:每一步都是"新地方",没有哪张老照片突出。
      for (var k = 1; k <= places; k++) {
        h = f.update(<int, double>{for (var i = 1; i <= k; i++) i: 0.01});
      }
      // 回到 revisit:那一张的似然明显高于其余(但远低于 0.9 的"比例")。
      for (var t = 0; t < ticksAtRevisit; t++) {
        h = f.update(<int, double>{
          for (var i = 1; i <= places; i++) i: i == revisit ? 0.20 : 0.01,
        });
      }
      return h!;
    }

    test('🎯 真实量级的重访:20.8% 的共享词也能过 0.11 的后验门', () {
      final h = walkThenRevisit(places: 12, revisit: 3, ticksAtRevisit: 3);
      // ignore: avoid_print
      print(
        '  重访后验 = ${h.bestPosterior.toStringAsFixed(4)}'
        '(门 ${kRtabmapLoopThreshold}),命中 id=${h.bestSignatureId},'
        ' 虚拟地点 ${h.virtualPlacePosterior.toStringAsFixed(4)}',
      );
      expect(h.bestSignatureId, 3, reason: '应当指向真正重访的那一张');
      expect(
        h.isLoopClosure,
        isTrue,
        reason: '这正是 0.9 那道门永远够不到、而 0.11 后验门够得到的那一格',
      );
    });

    test('阳性对照:一直走新地方 ⇒ 不该判回环', () {
      final f = PlaceBayesFilter();
      LoopHypothesis? h;
      for (var k = 1; k <= 12; k++) {
        h = f.update(<int, double>{for (var i = 1; i <= k; i++) i: 0.01});
      }
      // ignore: avoid_print
      print(
        '  一直走新地方:最高后验 ${h!.bestPosterior.toStringAsFixed(4)},'
        '虚拟地点 ${h.virtualPlacePosterior.toStringAsFixed(4)}',
      );
      expect(h.isLoopClosure, isFalse, reason: '没有重访就不该判回环');
    });

    test('单次噪声不足以翻案(递归贝叶斯的价值)', () {
      final one = walkThenRevisit(places: 12, revisit: 3, ticksAtRevisit: 1);
      final many = walkThenRevisit(places: 12, revisit: 3, ticksAtRevisit: 5);
      // ignore: avoid_print
      print(
        '  1 tick 后验 ${one.bestPosterior.toStringAsFixed(4)} → '
        '5 tick ${many.bestPosterior.toStringAsFixed(4)}',
      );
      expect(
        many.bestPosterior,
        greaterThan(one.bestPosterior),
        reason: '连续观测应当越来越确信 —— 这就是滤波比单帧阈值稳的地方',
      );
    });
  });

  group('接进判决路径的契约', () {
    final gov = File('lib/official_capture/auto_capture_governor.dart');
    final ctl = File('lib/official_capture/auto_capture_controller.dart');
    String code(File f) => f
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('回环判定是**独立一路**,没有去污染 almost_all 那个比例', () {
      final g = code(gov);
      expect(g.contains('bool placeAlreadyPhotographed'), isTrue);
      expect(
        g.contains(
          'if (placeAlreadyPhotographed) return AutoCaptureDecision.skipRedundant;',
        ),
        isTrue,
        reason: '它应当自成一道闸,与 almost_all 并排',
      );
      // 两家各用各的门:0.9 只许出现在 stella 那个常数里,0.11 只在 RTAB-Map 这边。
      expect(
        g.contains('kStellaLmsRatioThrAlmostAllLmsAreTracked'),
        isTrue,
        reason: 'stella 的 0.9 还在原位,没被改动',
      );
    });

    test('控制器把后验接进去,且只喂更早的那些照片', () {
      final c = code(ctl);
      expect(c.contains('_placeBayes.update('), isTrue);
      expect(
        c.contains('placeAlreadyPhotographed: _lastLoop?.isLoopClosure'),
        isTrue,
      );
      // 🔴 钉的是**整个 STM 被排除**,不只是末号那一张。
      // 上游 `Rtabmap::process` 的候选来自 `getWorkingMem()`,而一个地点要等
      // STM 满(`Mem/STMSize = 10`)才转进工作记忆。漏掉这层的后果实测过:
      // 单向前进、从不回头的轨迹上判出 **113 次**回环(最高后验 0.641),
      // 补上之后 **0 次**(最高后验 0.096,在 0.11 门下)。
      expect(
        c.contains('final wmCutoff = _placeSignatureSeq - kRtabmapStmSize;'),
        isTrue,
        reason: '必须按工作记忆截断,不能只排除末号那一张',
      );
      expect(c.contains('if (e.key <= wmCutoff)'), isTrue);
      expect(kRtabmapStmSize, 10, reason: 'Mem/STMSize —— 改它就是自定阈值');
    });

    test('阈值只有一个出处,没有被我改过', () {
      expect(
        kRtabmapLoopThreshold,
        0.11,
        reason: 'Rtabmap/LoopThr —— 改它就是自定阈值',
      );
      expect(
        kBayesVirtualPlacePrior,
        0.9,
        reason: 'Bayes/VirtualPlacePriorThr',
      );
      expect(kBayesPredictionLC.first, 0.1);
    });
  });
}
