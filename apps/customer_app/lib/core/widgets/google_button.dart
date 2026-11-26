import 'dart:math' as math;

import 'package:flutter/material.dart';

/// "Continue with Google" button following Google's branding rules (neutral surface, multicolour "G", plain label).
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.busy = false,
    this.label = 'Continue with Google',
  });

  /// null disables the button (e.g. while another sign-in is running).
  final VoidCallback? onPressed;
  final bool busy;
  final String label;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: label,
      child: OutlinedButton(
        onPressed: busy ? null : onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          backgroundColor: dark ? const Color(0xFF131314) : Colors.white,
          foregroundColor: dark
              ? const Color(0xFFE3E3E3)
              : const Color(0xFF1F1F1F),
          disabledBackgroundColor: dark
              ? const Color(0xFF131314)
              : Colors.white,
          side: BorderSide(
            color: dark ? const Color(0xFF8E918F) : const Color(0xFF747775),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CustomPaint(painter: _GoogleGPainter()),
                  ),
                  const SizedBox(width: 12),
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                ],
              ),
      ),
    );
  }
}

/// A labelled "or" separator between the e-mail form and the Google button.
class OrDivider extends StatelessWidget {
  const OrDivider({super.key});
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('or', style: TextStyle(color: muted)),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// The four-colour Google "G", drawn as vector arcs so no image asset is needed.
class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();
  static const _blue = Color(0xFF4285F4),
      _red = Color(0xFFEA4335),
      _yellow = Color(0xFFFBBC05),
      _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = s * 0.22;
    final rect = Rect.fromCircle(
      center: Offset(s / 2, s / 2),
      radius: (s - stroke) / 2,
    );
    Paint p(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    // Flutter angles: radians, clockwise from 3 o'clock, so -90 degrees is 12 o'clock.
    const deg = math.pi / 180;
    canvas.drawArc(rect, -135 * deg, 90 * deg, false, p(_red)); // top
    canvas.drawArc(rect, 135 * deg, 90 * deg, false, p(_yellow)); // left
    canvas.drawArc(rect, 45 * deg, 90 * deg, false, p(_green)); // bottom
    canvas.drawArc(rect, 0, 45 * deg, false, p(_blue)); // lower right
    // The crossbar of the G.
    canvas.drawRect(
      Rect.fromLTWH(s / 2, s / 2 - stroke / 2, s / 2 - stroke * 0.05, stroke),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
