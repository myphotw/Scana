import 'package:flutter/material.dart';

/// Root application shell. Feature screens will be added in later milestones.
class ScanaApp extends StatelessWidget {
  const ScanaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scana',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const Scaffold(body: SizedBox.shrink()),
    );
  }
}
