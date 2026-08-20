import 'dart:math' as math;

import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/speaker_data.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/ui/connect_speaker_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LocationViewPage extends ConsumerWidget {
  const LocationViewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userPosition = ref.watch(userPositionProvider);
    final speakers = ref.watch(speakersListProvider);
    return Stack(
      children: [
        // Background + content
        Container(
          decoration: const BoxDecoration(color: Color(0xFF0d121c)),
          child: Column(
            children: [
              // Header text (NO icon inside here)
              Padding(
                padding: const EdgeInsets.only(top: 60, bottom: 16),
                child: Center(
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [
                        Color(0xFFf0e68c),
                        Color(0xFFd4af37),
                        Color(0xFFc19a27),
                      ],
                    ).createShader(bounds),
                    child: const Text(
                      'SYREN APP',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 8,
                        color: Colors.white,
                        fontFamily: 'serif',
                      ),
                    ),
                  ),
                ),
              ),

              // Canvas
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 140),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return CustomPaint(
                        size: Size(constraints.maxWidth, constraints.maxHeight),
                        painter: LocationPainter(
                          userPosition: userPosition,
                          speakers: speakers,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),

        // The add button stays above the canvas.
        Positioned(
          right: 24,
          top: 60, // adjust because header text is at 60px
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(25),
              border: Border.all(
                color: const Color(0xFFd4af37).withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: IconButton(
              icon: const Icon(Icons.add, size: 18),
              padding: EdgeInsets.zero,
              color: const Color(0xFFf0e68c),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ConnectSpeakerPage(),
                    fullscreenDialog: true,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class LocationPainter extends CustomPainter {
  final Position3D? userPosition;
  final List<SpeakerData> speakers;

  LocationPainter({this.userPosition, required this.speakers});

  @override
  void paint(Canvas canvas, Size size) {
    double minX = 0, maxX = 300;
    double minY = 0, maxY = 300;
    final positions = <Position3D>[
      for (final speaker in speakers) speaker.position,
      if (userPosition != null) userPosition!,
    ];
    if (positions.isNotEmpty) {
      minX = maxX = positions.first.x;
      minY = maxY = positions.first.y;
      for (final position in positions.skip(1)) {
        minX = math.min(minX, position.x);
        maxX = math.max(maxX, position.x);
        minY = math.min(minY, position.y);
        maxY = math.max(maxY, position.y);
      }
      var worldWidth = maxX - minX;
      var worldHeight = maxY - minY;
      if (worldWidth == 0) {
        worldWidth = 1;
      }
      if (worldHeight == 0) {
        worldHeight = 1;
      }
      final paddingX = worldWidth * 0.2;
      final paddingY = worldHeight * 0.2;
      minX -= paddingX;
      maxX += paddingX;
      minY -= paddingY;
      maxY += paddingY;
    }

    var worldWidth = maxX - minX;
    var worldHeight = maxY - minY;
    if (worldWidth <= 0) worldWidth = 1;
    if (worldHeight <= 0) worldHeight = 1;

    final scale = math.min(size.width / worldWidth, size.height / worldHeight);

    final offsetX = (size.width - worldWidth * scale) / 2;
    final offsetY = (size.height - worldHeight * scale) / 2;

    Offset toScreen(Position3D position) {
      final x = offsetX + (position.x - minX) * scale;
      final y = size.height - (offsetY + (position.y - minY) * scale);

      return Offset(x, y);
    }

    if (userPosition != null) {
      final userOffset = toScreen(userPosition!);
      final linePaint = Paint()
        ..color = const Color(0xFFd4af37).withValues(alpha: 0.5)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;

      for (final speaker in speakers) {
        final speakerOffset = toScreen(speaker.position);
        _drawDashedLine(canvas, speakerOffset, userOffset, linePaint);
      }
    }

    for (var index = 0; index < speakers.length; index++) {
      final speaker = speakers[index];
      final offset = toScreen(speaker.position);

      final bgPaint = Paint()
        ..color = const Color(0xFFd4af37)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(offset, 20, bgPaint);

      _drawSpeakerIcon(canvas, offset);

      final textPainter = TextPainter(
        text: TextSpan(
          text: 'Speaker ${index + 1}',
          style: const TextStyle(
            color: Color(0xFFf0e68c),
            fontSize: 10,
            fontWeight: FontWeight.w300,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(offset.dx - textPainter.width / 2, offset.dy + 25),
      );
    }

    if (userPosition != null) {
      final userOffset = toScreen(userPosition!);

      final glowPaint = Paint()
        ..color = const Color(0xFFd4af37).withValues(alpha: 0.1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawCircle(userOffset, 32, glowPaint);

      _drawPersonIcon(canvas, userOffset);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashWidth = 4;
    const dashSpace = 6;
    final distance = (end - start).distance;
    final dashCount = (distance / (dashWidth + dashSpace)).floor();

    for (var index = 0; index < dashCount; index++) {
      final startT = index * (dashWidth + dashSpace) / distance;
      final endT = (index * (dashWidth + dashSpace) + dashWidth) / distance;
      canvas.drawLine(
        Offset.lerp(start, end, startT)!,
        Offset.lerp(start, end, endT)!,
        paint,
      );
    }
  }

  void _drawSpeakerIcon(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = const Color(0xFF0a101f)
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(center.dx - 6, center.dy - 8);
    path.lineTo(center.dx - 6, center.dy + 8);
    path.lineTo(center.dx + 2, center.dy + 4);
    path.lineTo(center.dx + 2, center.dy - 4);
    path.close();
    canvas.drawPath(path, paint);

    canvas.drawArc(
      Rect.fromCircle(center: Offset(center.dx + 6, center.dy), radius: 4),
      -math.pi / 4,
      math.pi / 2,
      false,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _drawPersonIcon(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = const Color(0xFFf0e68c)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(center.dx, center.dy - 10), 8, paint);
    final bodyPath = Path();
    bodyPath.moveTo(center.dx, center.dy - 2);
    bodyPath.lineTo(center.dx, center.dy + 10);

    bodyPath.moveTo(center.dx - 8, center.dy + 2);
    bodyPath.lineTo(center.dx + 8, center.dy + 2);

    bodyPath.moveTo(center.dx, center.dy + 10);
    bodyPath.lineTo(center.dx - 6, center.dy + 20);
    bodyPath.moveTo(center.dx, center.dy + 10);
    bodyPath.lineTo(center.dx + 6, center.dy + 20);

    canvas.drawPath(
      bodyPath,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(LocationPainter oldDelegate) {
    return oldDelegate.userPosition != userPosition ||
        !listEquals(oldDelegate.speakers, speakers);
  }
}
