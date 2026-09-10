import 'package:flutter/material.dart';

// Shared passenger palette: information remains readable without colour cues.
class GuideColors {
  static const ink = Color(0xFF142C36);
  static const primary = Color(0xFF005B50);
  static const background = Color(0xFFF4F6F2);
  static const muted = Color(0xFF465D64);
  static const line = Color(0xFFB5C5C1);
  static const soft = Color(0xFFE4EFEA);
  static const yellow = Color(0xFFFFDA62);
}

ThemeData guideTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: GuideColors.primary).copyWith(
    primary: GuideColors.primary,
    onPrimary: Colors.white,
    surface: Colors.white,
    onSurface: GuideColors.ink,
    secondary: GuideColors.ink,
    outline: GuideColors.line,
    error: const Color(0xFFA32624),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));
  final button = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(64, 68)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 24, vertical: 18),
    ),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(
        fontFamily: 'sans-serif',
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
    ),
    shape: WidgetStatePropertyAll(shape),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'sans-serif',
    scaffoldBackgroundColor: GuideColors.background,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 22, height: 1.5, color: GuideColors.ink),
      bodyMedium: TextStyle(fontSize: 20, height: 1.5, color: GuideColors.ink),
      bodySmall: TextStyle(fontSize: 18, height: 1.5, color: GuideColors.muted),
      titleLarge: TextStyle(
        fontSize: 28,
        height: 1.35,
        fontWeight: FontWeight.w800,
        color: GuideColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 24,
        height: 1.4,
        fontWeight: FontWeight.w700,
        color: GuideColors.ink,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: GuideColors.background,
      foregroundColor: GuideColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 80,
      titleTextStyle: TextStyle(
        fontFamily: 'sans-serif',
        fontSize: 25,
        fontWeight: FontWeight.w800,
        color: GuideColors.ink,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button.copyWith(
        side: const WidgetStatePropertyAll(
          BorderSide(color: GuideColors.primary, width: 1.5),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: button),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(64, 64))),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.all(22),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: GuideColors.muted),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: GuideColors.muted),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: GuideColors.primary, width: 3),
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: GuideColors.line),
      ),
    ),
  );
}

class GuideBody extends StatelessWidget {
  const GuideBody({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          children: children,
        ),
      ),
    ),
  );
}

class GuideCard extends StatelessWidget {
  const GuideCard({super.key, required this.child, this.color = Colors.white});
  final Widget child;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: color == Colors.white ? GuideColors.line : color,
      ),
    ),
    child: child,
  );
}

class GuideHeading extends StatelessWidget {
  const GuideHeading(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
}

class GuideAction extends StatelessWidget {
  const GuideAction(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon = Icons.arrow_forward,
    this.secondary = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;
  final bool secondary;
  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 28),
        const SizedBox(width: 12),
        Flexible(child: Text(label, textAlign: TextAlign.center)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: double.infinity,
        child: secondary
            ? OutlinedButton(onPressed: onPressed, child: child)
            : FilledButton(onPressed: onPressed, child: child),
      ),
    );
  }
}

class GuideFact extends StatelessWidget {
  const GuideFact(this.label, this.value, {super.key});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

class GuideTestBadge extends StatelessWidget {
  const GuideTestBadge({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: GuideCard(
      color: GuideColors.yellow,
      child: Text(
        '테스트 모드 · 실제 탑승을 가정합니다.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ),
  );
}

double guideToolbarHeight(BuildContext context) => (MediaQuery.textScalerOf(context).scale(25) * 3 + 16).clamp(80.0, 200.0);
