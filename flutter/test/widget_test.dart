import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legoagent/main.dart';
import 'package:legoagent/build_info.dart';

void main() {
  testWidgets('idle screen renders with Scan button', (tester) async {
    await tester.pumpWidget(const LegoAgentApp());
    expect(find.text('Scan'), findsOneWidget);
  });

  testWidgets(
    'small portrait drive is visible without scrolling and stops on release and tab',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sent = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            testSend: (line) async {
              sent.add(line);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsNothing);
      for (final icon in [
        Icons.arrow_upward,
        Icons.arrow_downward,
        Icons.arrow_back,
        Icons.arrow_forward,
        Icons.keyboard_double_arrow_left,
        Icons.keyboard_double_arrow_right,
      ]) {
        final rect = tester.getRect(find.byIcon(icon));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(568));
        final detector = find
            .ancestor(
              of: find.byIcon(icon),
              matching: find.byType(GestureDetector),
            )
            .first;
        final hitRect = tester.getRect(detector);
        expect(hitRect.width, greaterThanOrEqualTo(48));
        expect(hitRect.height, greaterThanOrEqualTo(48));
      }
      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.arrow_upward)),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.up();
      await tester.pump();
      expect(sent, containsAllInOrder(['drv fwd', 'drv stp']));
      sent.clear();
      await tester.tap(find.text('피아노'));
      await tester.pumpAndSettle();
      expect(sent, containsAllInOrder(['drv stp', 'aux stp']));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('piano and text send bounded single-line commands', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          testSend: (line) async {
            sent.add(line);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('피아노'));
    await tester.pumpAndSettle();
    sent.clear();
    for (final note in ['C4', 'D4', 'E4', 'F4', 'G4', 'A4', 'B4', 'C5']) {
      await tester.tap(find.byKey(ValueKey('note-$note')));
      await tester.pump();
    }
    expect(sent, [
      'snd note C4 200',
      'snd note D4 200',
      'snd note E4 200',
      'snd note F4 200',
      'snd note G4 200',
      'snd note A4 200',
      'snd note B4 200',
      'snd note C5 200',
    ]);
    await tester.tap(find.text('글자'));
    await tester.pumpAndSettle();
    sent.clear();
    await tester.enterText(find.byType(TextField), 'HELLO');
    await tester.tap(find.text('보여주기'));
    await tester.pump();
    expect(sent, ['dsp text HELLO']);
    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'HI\ndrv fwd';
    await tester.tap(find.text('보여주기'));
    await tester.pump();
    expect(find.text('지원하지 않는 글자가 있어요'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ABCDEFGHIJ');
    await tester.tap(find.text('보여주기'));
    await tester.pump();
    expect(find.text('글자가 너무 길어요'), findsOneWidget);
    await tester.tap(find.text('지우기'));
    await tester.pump();
    expect(sent, ['dsp text HELLO', 'dsp clear']);
    await tester.enterText(find.byType(TextField), '  A  ~! ');
    await tester.tap(find.text('보여주기'));
    await tester.pump();
    expect(sent.last, 'dsp text A ~!');
    await tester.enterText(find.byType(TextField), '한글');
    await tester.tap(find.text('보여주기'));
    await tester.pump();
    expect(find.text('지원하지 않는 글자가 있어요'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '123456789');
    await tester.tap(find.text('보여주기'));
    await tester.pump();
    expect(sent.last, 'dsp text 123456789');
  });

  testWidgets(
    'all play tabs fit small portrait; text buttons remain above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(testSend: (_) async {})),
      );
      await tester.pumpAndSettle();
      for (final tab in ['운전', '피아노', '글자', '조명']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(find.byType(SingleChildScrollView), findsNothing, reason: tab);
        expect(tester.takeException(), isNull, reason: tab);
        if (tab == '피아노') {
          for (final note in ['C4', 'D4', 'E4', 'F4', 'G4', 'A4', 'B4', 'C5']) {
            final rect = tester.getRect(find.byKey(ValueKey('note-$note')));
            expect(rect.width, greaterThan(30));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.bottom, lessThanOrEqualTo(568));
          }
        }
      }
      await tester.tap(find.text('글자'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pumpAndSettle();
      for (final label in ['보여주기', '지우기']) {
        final rect = tester.getRect(find.text(label));
        expect(rect.bottom, lessThanOrEqualTo(318));
        await tester.tap(find.text(label));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings shows build history and manual battery, safe to leave during refresh',
    (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            testSend: (line) async {
              sent.add(line);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Status / connection'));
      await tester.pumpAndSettle();
      expect(sent, containsAllInOrder(['drv stp', 'aux stp']));
      expect(sent, isNot(contains('bat')));
      expect(find.text('리모컨 설정'), findsOneWidget);
      expect(find.textContaining('연결: Test hub'), findsOneWidget);
      await tester.tap(find.text('🔄 Battery'));
      await tester.pump();
      expect(sent, contains('bat'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Status / connection'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('변경 이력'), 250);
      expect(find.text('버전: $appVersion'), findsOneWidget);
      expect(find.text('빌드 시각: $buildTime'), findsOneWidget);
      expect(find.text('2026-11-08 · 1.1.1+3'), findsOneWidget);
      expect(find.text('2026-11-08 · 1.1.0+2'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('2026-11-03 · 기존 리모컨'), 100);
      expect(find.text('2026-11-03 · 기존 리모컨'), findsOneWidget);
      const suppliedVersion = String.fromEnvironment('APP_VERSION');
      const suppliedBuildTime = String.fromEnvironment('BUILD_TIME');
      expect(appVersion, suppliedVersion.isEmpty ? '개발 빌드' : suppliedVersion);
      expect(
        buildTime,
        suppliedBuildTime.isEmpty ? '빌드 시각 미기록' : suppliedBuildTime,
      );
    },
  );

  testWidgets(
    'piano keys have independent hit targets in portrait and landscape',
    (tester) async {
      final sent = <String>[];
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            testSend: (line) async {
              sent.add(line);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('피아노'));
      await tester.pumpAndSettle();
      sent.clear();
      for (final note in ['C#4', 'D#4', 'F#4', 'G#4', 'A#4']) {
        final finder = find.byKey(ValueKey('note-$note'));
        final rect = tester.getRect(finder);
        expect(rect.width, closeTo(22.8, 0.2));
        final gesture = await tester.startGesture(rect.center);
        await tester.pump(const Duration(milliseconds: 150));
        expect(sent.last, 'snd note $note 200');
        expect(
          find.descendant(
            of: finder,
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).color == Colors.orange,
            ),
          ),
          findsOneWidget,
        );
        await gesture.up();
        await tester.pump();
      }
      expect(sent.length, 5);
      final white = tester.getRect(find.byKey(const ValueKey('note-C4')));
      await tester.tapAt(Offset(white.right - 2, white.bottom - 10));
      await tester.pump();
      expect(sent.length, 6);
      expect(sent.last, 'snd note C4 200');
      tester.view.physicalSize = const Size(568, 320);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('note-C#4'))).width,
        greaterThan(40),
      );
      for (final tab in ['운전', '글자', '피아노']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
        expect(find.byType(SingleChildScrollView), findsNothing);
        if (tab == '운전') {
          final detector = find
              .ancestor(
                of: find.byIcon(Icons.arrow_upward),
                matching: find.byType(GestureDetector),
              )
              .first;
          final rect = tester.getRect(detector);
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
      }
    },
  );

  testWidgets('each emergency stop is attempted after a write failure', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          testSend: (line) async {
            sent.add(line);
            if (line == 'drv stp') throw Exception('write failed');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('피아노'));
    await tester.pumpAndSettle();
    expect(sent, containsAllInOrder(['drv stp', 'aux stp']));
  });
}
