import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:final_project/providers/services_providers.dart';
import 'package:final_project/providers/app_state_providers.dart';
import 'package:final_project/models/distance_item.dart';
import 'dart:math' as math;

class ConnectSpeakerPage extends ConsumerWidget {
  const ConnectSpeakerPage({super.key});

  String? _getClosestSpeaker(List<DistanceItem> distanceItems) {
    if (distanceItems.isEmpty) return null;

    var closest = distanceItems.reduce((a, b) =>
      a.distance < b.distance ? a : b
    );

    // Only return if distance is close to 0 (within 10cm)
    if (closest.distance <= 500) {
      return closest.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final distanceItems = ref.watch(distanceItemsProvider);
    final closestSpeakerId = _getClosestSpeaker(distanceItems);

    return Scaffold(
      backgroundColor: const Color(0xFF0d121c),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, size: 28),
                    color: Colors.white,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  ShaderMask(
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
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                        color: Colors.white,
                        fontFamily: 'serif',
                      ),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 48), // Balance the close button
                ],
              ),
            ),

            // Main content
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    children: [
                      // Rings visualization
                      SizedBox(
                        width: 300,
                        height: 300,
                        child: CustomPaint(
                          painter: RingsPainter(
                            closestDistance: distanceItems.isNotEmpty
                              ? distanceItems.map((e) => e.distance).reduce(math.min)
                              : 300.0,
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),

                  // Title
                  const Text(
                    'Place Speaker for',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w400,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const Text(
                    'Mapping',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w400,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 24),

                  // Description
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40.0),
                    child: Text(
                      'Place your phone on the speaker you want to register. The rings will get stronger as you get closer.',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withValues(alpha: 0.6),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Distance readings
                  if (distanceItems.isNotEmpty) ...[
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 40),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFd4af37).withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(
                            'SENSOR DISTANCES',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2,
                              color: const Color(0xFFd4af37).withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(height: 12),
                          ...distanceItems.map((item) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  item.id,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  '${item.distance.toStringAsFixed(1)} mm',
                                  style: TextStyle(
                                    color: item.distance <= 500
                                      ? const Color(0xFF4ade80)
                                      : Colors.white,
                                    fontSize: 14,
                                    fontWeight: item.distance <= 500
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Connect button
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: closestSpeakerId != null
                          ? () async {
                              final mqttService = ref.read(mqttServiceProvider);
                              final success = mqttService.connectSpeaker(closestSpeakerId!);

                              if (context.mounted) {
                                if (success) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text("Speaker $closestSpeakerId connected for mapping!"),
                                      backgroundColor: const Color(0xFFd4af37),
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  );
                                  Navigator.pop(context);
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text("Failed to connect. Check MQTT connection."),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            }
                          : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: closestSpeakerId != null
                            ? const Color(0xFFd4af37)
                            : Colors.grey.withValues(alpha: 0.3),
                          foregroundColor: closestSpeakerId != null
                            ? const Color(0xFF0a101f)
                            : Colors.grey,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: closestSpeakerId != null ? 8 : 0,
                          shadowColor: const Color(0xFFd4af37).withValues(alpha: 0.3),
                        ),
                        child: Container(
                          width: double.infinity,
                          alignment: Alignment.center,
                          child: Text(
                            closestSpeakerId != null
                                ? 'CONNECT SPEAKER $closestSpeakerId'
                                : 'GET CLOSER TO A SPEAKER',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 80), // Bottom spacing
                ],
              ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RingsPainter extends CustomPainter {
  final double closestDistance;

  RingsPainter({required this.closestDistance});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Calculate alpha based on distance (closer = more opaque)
    // Distance range: 0-300cm, alpha range: 1.0-0.1
    final normalizedDistance = (closestDistance / 300).clamp(0.0, 1.0);
    final baseAlpha = 1.0 - (normalizedDistance * 0.9); // 1.0 to 0.1

    // Draw multiple concentric rings
    final rings = [
      {'radius': 140.0, 'color': const Color(0xFF3d4a35), 'alpha': 0.8},
      {'radius': 105.0, 'color': const Color(0xFF5c6b48), 'alpha': 0.9},
      {'radius': 70.0, 'color': const Color(0xFF8a9a5f), 'alpha': 1.0},
      {'radius': 35.0, 'color': const Color(0xFFb8b872), 'alpha': 1.0},
    ];

    for (var ring in rings) {
      final paint = Paint()
        ..color = (ring['color'] as Color).withValues(
          alpha: (ring['alpha'] as double) * baseAlpha,
        )
        ..style = PaintingStyle.fill;

      canvas.drawCircle(center, ring['radius'] as double, paint);
    }

    // Draw center icon (RSS/speaker waves)
    final iconPaint = Paint()
      ..color = const Color(0xFFd4af37).withValues(alpha: baseAlpha)
      ..style = PaintingStyle.fill;

    // Center dot
    canvas.drawCircle(center, 6, iconPaint);

    // Arc waves
    final arcPaint = Paint()
      ..color = const Color(0xFFd4af37).withValues(alpha: baseAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    // First arc
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 14),
      -math.pi / 4,
      math.pi / 2,
      false,
      arcPaint,
    );

    // Second arc
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 22),
      -math.pi / 4,
      math.pi / 2,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(RingsPainter oldDelegate) {
    return oldDelegate.closestDistance != closestDistance;
  }
}
