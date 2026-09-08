import 'package:final_project/ui/app_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('only the latest notification appears above navigation', (
    tester,
  ) async {
    late BuildContext messageContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          snackBarTheme: const SnackBarThemeData(
            behavior: SnackBarBehavior.floating,
          ),
        ),
        home: Scaffold(
          extendBody: true,
          bottomNavigationBar: const SizedBox(
            height: 100,
            child: Text('Navigation'),
          ),
          body: Builder(
            builder: (context) {
              messageContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    for (final message in [
      'Old message',
      'Another message',
      'Latest message',
    ]) {
      showLatestSnackBar(messageContext, SnackBar(content: Text(message)));
    }
    await tester.pumpAndSettle();
    expect(find.text('Old message'), findsNothing);
    expect(find.text('Another message'), findsNothing);
    expect(find.text('Latest message'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(SnackBar)).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.text('Navigation')).dy),
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}
