import 'dart:math' as math;

import 'package:flutter/material.dart';

class LoracordLogo extends StatelessWidget {
  const LoracordLogo({super.key, this.size = 42, this.showWordmark = false});

  final double size;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LoracordMarkPainter()),
    );
    if (!showWordmark) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 10),
        Text(
          'Loracord',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _LoracordMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final shortest = math.min(size.width, size.height);
    final scale = shortest / 64;
    canvas.scale(scale);

    final bg = Paint()..color = const Color(0xff15a06d);
    final dark = Paint()..color = const Color(0xff101217);
    final light = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(3, 3, 58, 58),
        const Radius.circular(15),
      ),
      bg,
    );

    final bubble = Path()
      ..moveTo(17, 21)
      ..quadraticBezierTo(17, 14, 25, 14)
      ..lineTo(43, 14)
      ..quadraticBezierTo(51, 14, 51, 22)
      ..lineTo(51, 34)
      ..quadraticBezierTo(51, 42, 43, 42)
      ..lineTo(33, 42)
      ..lineTo(24, 50)
      ..lineTo(26, 42)
      ..lineTo(25, 42)
      ..quadraticBezierTo(17, 42, 17, 34)
      ..close();
    canvas.drawPath(bubble, dark);

    canvas.drawLine(const Offset(30, 34), const Offset(30, 22), light);
    canvas.drawLine(const Offset(30, 34), const Offset(39, 34), light);

    final radio = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(const Rect.fromLTWH(9, 20, 14, 18), -1.1, 2.2, false, radio);
    canvas.drawArc(
      const Rect.fromLTWH(5, 16, 22, 26),
      -1.05,
      2.1,
      false,
      radio,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
