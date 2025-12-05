import 'package:flutter/material.dart';
import 'package:final_project/models/position_3d.dart';
import 'package:final_project/models/speaker_data.dart';
import 'package:final_project/ui/connect_speaker_page.dart';
import 'dart:math' as math;

class LocationViewPage extends StatefulWidget {
  final Position3D? userPosition;
  final List<SpeakerData> speakers;

  const LocationViewPage({
    super.key,
    this.userPosition,
    this.speakers = const [],
  });

  @override
  State<LocationViewPage> createState() => _LocationViewPageState();
}

class _LocationViewPageState extends State<LocationViewPage> {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Background + content
        Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0d121c),
          ),
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
                          userPosition: widget.userPosition,
                          speakers: widget.speakers,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),

        // Floating icon ABOVE EVERYTHING (highest z-index)
        Positioned(
          right: 24,
          top: 60,   // adjust because header text is at 60px
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

  LocationPainter({
    this.userPosition,
    required this.speakers,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // World-space bounds in X/Z (floor plane)
    double minX = 0, maxX = 300;
    double minZ = 0, maxZ = 300;

    if (speakers.isNotEmpty) {
      // Base bounds on speakers
      minX = speakers.map((s) => s.position.x).reduce(math.min);
      maxX = speakers.map((s) => s.position.x).reduce(math.max);
      minZ = speakers.map((s) => s.position.z).reduce(math.min);
      maxZ = speakers.map((s) => s.position.z).reduce(math.max);

      // Include user position in bounds if present
      if (userPosition != null) {
        minX = math.min(minX, userPosition!.x);
        maxX = math.max(maxX, userPosition!.x);
        minZ = math.min(minZ, userPosition!.z);
        maxZ = math.max(maxZ, userPosition!.z);
      }

      // Compute world width/height before padding, avoid degenerate size
      var worldWidth = maxX - minX;
      var worldHeight = maxZ - minZ;
      if (worldWidth == 0) worldWidth = 1;
      if (worldHeight == 0) worldHeight = 1;

      // Add padding in world space
      final paddingX = worldWidth * 0.2;
      final paddingZ = worldHeight * 0.2;
      minX -= paddingX;
      maxX += paddingX;
      minZ -= paddingZ;
      maxZ += paddingZ;
    }

    // Recompute world size after padding
    var worldWidth = maxX - minX;
    var worldHeight = maxZ - minZ;
    if (worldWidth <= 0) worldWidth = 1;
    if (worldHeight <= 0) worldHeight = 1;

    // Uniform scale to preserve distances
    final scale = math.min(
      size.width / worldWidth,
      size.height / worldHeight,
    );

    // Center the world rect in the canvas
    final offsetX = (size.width - worldWidth * scale) / 2;
    final offsetY = (size.height - worldHeight * scale) / 2;

    // Convert 3D position (X/Z plane) to 2D screen coordinates
    Offset toScreen(Position3D pos) {
      final x = offsetX + (pos.x - minX) * scale;

      // Flip vertically: larger Z goes "up" on the screen
      final y = size.height - (offsetY + (pos.z - minZ) * scale);

      return Offset(x, y);
    }

    // Draw connection lines from speakers to user
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

    // Draw speakers
    for (int i = 0; i < speakers.length; i++) {
      final speaker = speakers[i];
      final offset = toScreen(speaker.position);

      // Speaker icon circle background
      final bgPaint = Paint()
        ..color = const Color(0xFFd4af37)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(offset, 20, bgPaint);

      // Draw speaker icon
      _drawSpeakerIcon(canvas, offset);

      // Draw label
      final textPainter = TextPainter(
        text: TextSpan(
          text: 'Speaker ${i + 1}',
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

    // Draw user position
    if (userPosition != null) {
      final userOffset = toScreen(userPosition!);

      // Glow effect
      final glowPaint = Paint()
        ..color = const Color(0xFFd4af37).withValues(alpha: 0.1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawCircle(userOffset, 32, glowPaint);

      // User icon
      _drawPersonIcon(canvas, userOffset);
    }
  }


  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashWidth = 4;
    const dashSpace = 6;
    final distance = (end - start).distance;
    final dashCount = (distance / (dashWidth + dashSpace)).floor();

    for (int i = 0; i < dashCount; i++) {
      final startT = i * (dashWidth + dashSpace) / distance;
      final endT = (i * (dashWidth + dashSpace) + dashWidth) / distance;
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

    // Simple speaker shape
    final path = Path();
    path.moveTo(center.dx - 6, center.dy - 8);
    path.lineTo(center.dx - 6, center.dy + 8);
    path.lineTo(center.dx + 2, center.dy + 4);
    path.lineTo(center.dx + 2, center.dy - 4);
    path.close();
    canvas.drawPath(path, paint);

    // Sound waves
    canvas.drawArc(
      Rect.fromCircle(center: Offset(center.dx + 6, center.dy), radius: 4),
      -math.pi / 4,
      math.pi / 2,
      false,
      paint..style = PaintingStyle.stroke..strokeWidth = 1.5,
    );
  }

  void _drawPersonIcon(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = const Color(0xFFf0e68c)
      ..style = PaintingStyle.fill;

    // Head
    canvas.drawCircle(Offset(center.dx, center.dy - 10), 8, paint);

    // Body
    final bodyPath = Path();
    bodyPath.moveTo(center.dx, center.dy - 2);
    bodyPath.lineTo(center.dx, center.dy + 10);

    // Arms
    bodyPath.moveTo(center.dx - 8, center.dy + 2);
    bodyPath.lineTo(center.dx + 8, center.dy + 2);

    // Legs
    bodyPath.moveTo(center.dx, center.dy + 10);
    bodyPath.lineTo(center.dx - 6, center.dy + 20);
    bodyPath.moveTo(center.dx, center.dy + 10);
    bodyPath.lineTo(center.dx + 6, center.dy + 20);

    canvas.drawPath(bodyPath, paint..style = PaintingStyle.stroke..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(LocationPainter oldDelegate) {
    return oldDelegate.userPosition != userPosition ||
        oldDelegate.speakers != speakers;
  }
}
