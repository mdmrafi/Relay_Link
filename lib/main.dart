// RelayLink — Ticket #01 scaffold home screen.
//
// This is a placeholder home screen so the scaffold compiles and runs. Later
// tickets (#38-#42) will replace this with the actual navigation surface.

import 'package:flutter/material.dart';

void main() {
  runApp(const RelayLinkApp());
}

class RelayLinkApp extends StatelessWidget {
  const RelayLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RelayLink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4FC3F7),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            color: Color(0xFFE6EAF2),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ),
      home: const RelayLinkHome(),
    );
  }
}

class RelayLinkHome extends StatelessWidget {
  const RelayLinkHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'RelayLink',
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontSize: 56,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Offline mesh messaging · End-to-end encrypted',
                style: TextStyle(
                  color: const Color(0xFF9AA4B2),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}