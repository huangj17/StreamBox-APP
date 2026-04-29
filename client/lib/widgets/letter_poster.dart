import 'package:flutter/material.dart';

/// 字母海报：无封面时根据标题首字 + 种子哈希生成稳定的渐变色块。
///
/// 填充父容器尺寸。字号按父容器 shortestSide 自适应（默认 45%），
/// 可通过 [letterScale] 微调（如详情页大海报用 0.35，避免溢出）。
class LetterPoster extends StatelessWidget {
  final String title;
  final String seed;
  final double letterScale;

  const LetterPoster({
    super.key,
    required this.title,
    required this.seed,
    this.letterScale = 0.45,
  });

  /// 深色双色渐变（topLeft → bottomRight），白色字在任意组合上都可读。
  static const _gradients = <List<Color>>[
    [Color(0xFF4A148C), Color(0xFF311B92)], // 深紫 → 靛
    [Color(0xFFB71C1C), Color(0xFF880E4F)], // 深红 → 玫红
    [Color(0xFF1B5E20), Color(0xFF004D40)], // 深绿 → 青绿
    [Color(0xFF0D47A1), Color(0xFF4A148C)], // 深蓝 → 深紫
    [Color(0xFFE65100), Color(0xFFBF360C)], // 深橙
    [Color(0xFF004D40), Color(0xFF006064)], // 青 → 蓝青
    [Color(0xFF311B92), Color(0xFF4527A0)], // 靛 → 深紫
    [Color(0xFF3E2723), Color(0xFF212121)], // 棕 → 黑
    [Color(0xFF880E4F), Color(0xFFAD1457)], // 玫红
    [Color(0xFF1A237E), Color(0xFF0D47A1)], // 深蓝
    [Color(0xFF263238), Color(0xFF37474F)], // 石板
    [Color(0xFF4E342E), Color(0xFF6D4C41)], // 咖
  ];

  static String extractLetter(String title) {
    final t = title.trim();
    if (t.isEmpty) return '?';
    return t.characters.first.toUpperCase();
  }

  static List<Color> gradientFor(String seed) {
    final h = seed.hashCode & 0x7fffffff;
    return _gradients[h % _gradients.length];
  }

  @override
  Widget build(BuildContext context) {
    final colors = gradientFor(seed);
    final letter = extractLetter(title);

    return LayoutBuilder(
      builder: (context, constraints) {
        final shortest = constraints.biggest.shortestSide;
        final baseSize = shortest.isFinite ? shortest : 120.0;
        final fontSize = baseSize * letterScale;
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            letter,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: Colors.white.withAlpha(230),
              height: 1.0,
              letterSpacing: 0,
            ),
          ),
        );
      },
    );
  }
}
