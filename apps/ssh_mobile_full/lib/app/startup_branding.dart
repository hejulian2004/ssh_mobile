import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Runtime-independent branding shared by the bootstrap and initial route.
class StartupBranding extends StatelessWidget {
  const StartupBranding({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shortSide = math.min(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final logoSize = (shortSide * .25).clamp(64.0, 128.0);
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: constraints.maxWidth,
                minHeight: constraints.maxHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SvgPicture.asset(
                      'assets/app_icon.svg',
                      width: logoSize,
                      height: logoSize,
                      fit: BoxFit.contain,
                      excludeFromSemantics: true,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'SSH Mobile',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF1E293B),
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.4,
                      ),
                    ),
                    const SizedBox(height: 28),
                    const SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        color: Color(0xFF2563EB),
                        backgroundColor: Color(0xFFEFF6FF),
                        strokeWidth: 2.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
