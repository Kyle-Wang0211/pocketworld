// 法律文本的最小结构模型 —— 隐私政策与用户协议共用。
// =====================================================================
// 与 platform_rules_content.dart 的 RuleSection 不同处只有一个:
// `emphasized` 位。它不是排版偏好,是《民法典》第四百九十六条第二款的
// 硬性要求 —— 对"与对方有重大利害关系的条款"(免责、限责、管辖、权利许可),
// 提供格式条款的一方须"采取合理的方式提示对方注意",否则对方可以主张
// 该条款不成为合同的内容。2026-02-01 施行的市场监管总局、网信办令第116号
// 第八条更把方式逐字写成"以字体加粗等显著方式提示"。
// 渲染层(legal_doc_page.dart)把 emphasized 段落加粗展示,义务就落在这一位上。

class LegalParagraph {
  final String text;

  /// true = 免责/限责/管辖/权利许可等重大利害关系条款,渲染时必须加粗。
  final bool emphasized;

  const LegalParagraph(this.text, {this.emphasized = false});
}

class LegalSection {
  final String title;
  final List<LegalParagraph> paragraphs;
  const LegalSection(this.title, this.paragraphs);
}
