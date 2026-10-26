import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/school_erp_mobile_shared.dart';
import 'package:school_erp_mobile_shared/src/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'hosted parent has the four V3 destinations and linked-child summaries',
    (tester) async {
      await tester.pumpWidget(_parentApp());

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Home'), findsWidgets);
      expect(find.text('Learn+'), findsOneWidget);
      expect(find.text('Shop'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Mira Shah'), findsOneWidget);
      expect(find.text('Class 3 · A · Aster School'), findsOneWidget);
      expect(find.textContaining('Stale ·'), findsOneWidget);
      expect(
        find.text('Offline · showing the last saved school information.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('learning navigation opens a published homework detail', (
    tester,
  ) async {
    await tester.pumpWidget(_parentApp());
    await tester.tap(find.text('Learn+'));
    await tester.pumpAndSettle();

    expect(find.text('Mira Shah · Aster School'), findsOneWidget);
    await _scrollUntilVisible(tester, find.textContaining('School schedule ·'));
    expect(find.textContaining('School schedule ·'), findsOneWidget);
    await _scrollUntilVisible(tester, find.text('Timetable'));
    expect(find.text('Timetable'), findsOneWidget);
    await _scrollUntilVisible(tester, find.text('Open class'));
    expect(find.text('Open class'), findsOneWidget);
    await _scrollUntilVisible(tester, find.text('Homework'));
    expect(find.text('Homework'), findsOneWidget);
    await _scrollUntilVisible(tester, find.text('Math practice'));
    expect(find.text('Math practice'), findsOneWidget);
    expect(find.textContaining('Rina Patel'), findsOneWidget);
    expect(find.textContaining('Samir Khan'), findsNothing);

    await _scrollToTop(tester);
    await tester.ensureVisible(find.text('Week'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    await _scrollUntilVisible(tester, find.textContaining('Samir Khan'));
    expect(find.textContaining('Samir Khan'), findsOneWidget);

    await tester.ensureVisible(find.text('Math practice'));
    await tester.tap(find.text('Math practice'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Complete pages 4–5.'), findsOneWidget);
  });

  testWidgets('parents can turn off a notification category from Settings', (
    tester,
  ) async {
    String? changedCategory;
    bool? changedValue;
    await tester.pumpWidget(
      _parentApp(
        onNotificationPreferenceChanged: (change) {
          changedCategory = change.key;
          changedValue = change.value;
        },
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await _scrollUntilVisible(tester, find.text('School announcements'));
    expect(find.text('School announcements'), findsOneWidget);
    await _scrollUntilVisible(
      tester,
      find.text('Timetable and calendar updates'),
    );
    expect(find.text('Timetable and calendar updates'), findsOneWidget);
    await _scrollUntilVisible(tester, find.text('New homework'));
    expect(find.text('New homework'), findsOneWidget);
    await tester.tap(
      find.ancestor(
        of: find.text('New homework'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(changedCategory, 'homework_update');
    expect(changedValue, isFalse);
  });

  testWidgets('parents can adjust in-app text size from Settings', (
    tester,
  ) async {
    double? selectedScale;
    await tester.pumpWidget(
      _parentApp(onTextScaleChanged: (value) => selectedScale = value),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Text size · 100%'), findsOneWidget);
    await tester.ensureVisible(find.byType(Slider));
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(1.25);
    expect(selectedScale, 1.25);
  });

  testWidgets('parents can review current privacy and data behavior', (
    tester,
  ) async {
    await tester.pumpWidget(_parentApp());
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await _scrollUntilVisible(tester, find.text('Privacy and data'));
    await tester.tap(find.text('Privacy and data'));
    await tester.pumpAndSettle();

    expect(find.text('School records'), findsOneWidget);
    expect(find.text('Google Drive backups'), findsOneWidget);
    expect(find.text('Advertising'), findsOneWidget);
    expect(
      find.textContaining('does not currently upload its records'),
      findsOneWidget,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(find.text('Fees and app purchases'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(find.text('Optional diagnostics'), findsOneWidget);
  });

  testWidgets('hosted parent sees school calendar events in Learn+', (
    tester,
  ) async {
    await tester.pumpWidget(
      _parentApp(
        schoolCalendar: [
          {
            'id': 18,
            'schoolId': 'aster-school',
            'schoolName': 'Aster School',
            'title': 'Annual day',
            'eventType': 'event',
            'startDate': '2026-11-20',
            'endDate': '2026-11-20',
            'notes': 'Arrive by 9 AM',
          },
        ],
      ),
    );
    await tester.tap(find.text('Learn+'));
    await tester.pumpAndSettle();

    expect(find.text('Family calendar'), findsOneWidget);
    expect(find.text('Annual day'), findsOneWidget);
    expect(
      find.textContaining('Aster School · Event · Arrive by 9 AM'),
      findsOneWidget,
    );
  });

  testWidgets('parent can review school attendance records from Learn+', (
    tester,
  ) async {
    await tester.pumpWidget(_parentApp());
    await tester.tap(find.text('Learn+'));
    await tester.pumpAndSettle();

    await _scrollUntilVisible(tester, find.text('Attendance'));
    expect(find.text('Attendance'), findsOneWidget);
    await _scrollUntilVisible(
      tester,
      find.textContaining('Status: Present · Full day'),
    );
    expect(find.textContaining('Status: Present · Full day'), findsOneWidget);
    await _scrollUntilVisible(
      tester,
      find.textContaining('Stale · 23/10/2026 at'),
    );
    expect(find.textContaining('Stale · 23/10/2026 at'), findsOneWidget);
    expect(find.text('23/10/2026'), findsOneWidget);
    await tester.ensureVisible(find.text('23/10/2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('23/10/2026'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('this view does not change attendance'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await _scrollUntilVisible(
      tester,
      find.textContaining('Status: Medical leave · Period 2'),
    );
    expect(
      find.textContaining('Status: Medical leave · Period 2'),
      findsOneWidget,
    );
  });

  testWidgets('parent can submit a leave request with only a start date', (
    tester,
  ) async {
    Map<String, String>? submitted;
    await tester.pumpWidget(
      _parentApp(onSubmitRequest: (value) => submitted = value),
    );
    await tester.ensureVisible(find.text('Request · Mira'));
    await tester.tap(find.text('Request · Mira'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('parent-request-start-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).last,
      'Medical appointment',
    );
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    expect(submitted?['startsOn'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(submitted?['endsOn'], isEmpty);
    expect(submitted?['message'], 'Medical appointment');
  });

  testWidgets(
    'parent can request data deletion without automatic record changes',
    (tester) async {
      Map<String, String>? submitted;
      await tester.pumpWidget(
        _parentApp(onSubmitRequest: (value) => submitted = value),
      );
      await tester.ensureVisible(find.text('Request · Mira'));
      await tester.tap(find.text('Request · Mira'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete my child’s data').last);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('does not automatically change or delete records'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('parent-request-start-date')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('parent-request-end-date')),
        findsNothing,
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'Please review my child data deletion request.',
      );
      await tester.tap(find.text('Submit'));
      await tester.pumpAndSettle();

      expect(submitted?['requestType'], 'data_deletion');
      expect(submitted?['startsOn'], isEmpty);
      expect(submitted?['endsOn'], isEmpty);
    },
  );

  testWidgets('parent request inbox explains pending and resolved outcomes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _parentApp(
        commands: [
          {'status': 'accepted', 'operationId': 'req-1'},
          {'status': 'request_approved', 'operationId': 'req-2'},
          {'status': 'needs_info', 'operationId': 'req-3'},
        ],
      ),
    );
    await tester.tap(find.text('Learn+'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Notices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notices'));
    await tester.pumpAndSettle();
    await _scrollUntilVisible(
      tester,
      find.text('Received · awaiting school review'),
    );
    expect(find.text('Received · awaiting school review'), findsOneWidget);
    await _scrollUntilVisible(tester, find.text('Approved by the school'));
    expect(find.text('Approved by the school'), findsOneWidget);
    await _scrollUntilVisible(
      tester,
      find.text('The school needs more information'),
    );
    expect(find.text('The school needs more information'), findsOneWidget);

    await tester.pumpWidget(
      _parentApp(
        commands: [
          {'status': 'request_rejected', 'operationId': 'req-4'},
        ],
      ),
    );
    await tester.tap(find.text('Learn+'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Notices'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notices'));
    await tester.pumpAndSettle();
    await _scrollUntilVisible(tester, find.text('Declined by the school'));
    expect(find.text('Declined by the school'), findsOneWidget);
  });

  testWidgets(
    'schedule-only access is clearly labelled and shows no private counts',
    (tester) async {
      await tester.pumpWidget(_parentApp(scheduleOnly: true));
      expect(
        find.text('Schedule-only access · timetable details only'),
        findsOneWidget,
      );
      expect(find.textContaining('Attendance'), findsNothing);
      expect(find.textContaining('Fee records'), findsNothing);
      await tester.tap(find.text('Learn+'));
      await tester.pumpAndSettle();
      expect(find.text('Attendance'), findsNothing);
      expect(find.text('Homework'), findsNothing);
      expect(find.text('Published results'), findsNothing);
      expect(find.textContaining('Request ·'), findsNothing);
    },
  );

  testWidgets('opening a schedule notification selects Learn+', (tester) async {
    await tester.pumpWidget(_parentApp());
    await tester.pumpWidget(
      _parentApp(
        notificationRevision: 1,
        notificationType: 'schedule_update',
        notificationOpened: true,
      ),
    );

    final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navigation.selectedIndex, 1);
  });

  testWidgets('opening a homework notification selects Learn+', (tester) async {
    await tester.pumpWidget(_parentApp());
    await tester.pumpWidget(
      _parentApp(
        notificationRevision: 1,
        notificationType: 'homework_update',
        notificationOpened: true,
      ),
    );

    final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navigation.selectedIndex, 1);
  });
}

Widget _parentApp({
  bool scheduleOnly = false,
  ValueChanged<Map<String, String>>? onSubmitRequest,
  List<Map<String, dynamic>> commands = const [],
  List<Map<String, dynamic>> schoolCalendar = const [],
  int notificationRevision = 0,
  String? notificationType,
  bool notificationOpened = false,
  ValueChanged<MapEntry<String, bool>>? onNotificationPreferenceChanged,
  ValueChanged<double>? onTextScaleChanged,
}) => MaterialApp(
  home: HostedParentNavigation(
    role: MobileRole.parent,
    user: {'name': 'Parent', 'email': 'parent@example.test'},
    api: ApiClient(),
    supportTickets: const [],
    supportAvailable: true,
    cacheCleared: false,
    children: [
      {
        'studentPublicId': 'f09d1716-604c-46b0-b163-2a286c97148e',
        'schoolName': 'Aster School',
        'schoolId': 'aster-school',
        'schoolCalendar': schoolCalendar,
        'schoolCalendarProjectedAt': DateTime.now().toUtc().toIso8601String(),
        'linkStatus': 'linked',
        'accessLevel': scheduleOnly ? 'schedule_only' : 'full',
        'projectedAt':
            DateTime.now()
                .toUtc()
                .subtract(const Duration(days: 2))
                .toIso8601String(),
        'snapshot': {
          'student': {
            'fullName': 'Mira Shah',
            'className': 'Class 3',
            'sectionName': 'A',
          },
          'attendance': [
            {
              'date': '2026-10-23',
              'period': 0,
              'status': 'present',
              'statusLabel': 'Present',
              'revision': 2,
              'updatedAt': '2026-10-23T12:30:00.000Z',
            },
            {
              'date': '2026-10-22',
              'period': 2,
              'status': 'medical_leave',
              'statusLabel': 'Medical leave',
              'revision': 1,
              'updatedAt': '2026-10-22T12:30:00.000Z',
            },
          ],
          'timetable': [
            {
              'weekday': DateTime.now().weekday,
              'period': 1,
              'startTime': '08:00',
              'endTime': '08:40',
              'subjectName': 'Mathematics',
              'teacherName': 'Rina Patel',
              'room': 'Room 4',
              'meetingLink': 'https://meet.example.test/class-3a-math',
            },
            {
              'weekday': DateTime.now().weekday == 1 ? 2 : 1,
              'period': 2,
              'startTime': '08:45',
              'endTime': '09:25',
              'subjectName': 'English',
              'teacherName': 'Samir Khan',
              'room': 'Room 2',
            },
          ],
          'homework': [
            {
              'title': 'Math practice',
              'dueOn': '2026-10-27',
              'details': 'Complete pages 4–5.',
              'subjectName': 'Mathematics',
            },
          ],
          'announcements': [
            {
              'title': 'Library day',
              'message': 'Bring your library book.',
              'publishOn': '2026-10-23',
            },
          ],
          'results': <Map<String, dynamic>>[],
          'fees': [
            {'feeName': 'Tuition', 'amount': 5000, 'status': 'due'},
          ],
        },
      },
    ],
    commands: commands,
    analyticsConsent: false,
    isOffline: true,
    working: false,
    showWelcomeCard: true,
    onEnableNotifications: () {},
    notificationPreferences: const {
      'school_notice': true,
      'schedule_update': true,
      'homework_update': true,
    },
    onNotificationPreferenceChanged:
        (category, enabled) =>
            onNotificationPreferenceChanged?.call(MapEntry(category, enabled)),
    textScale: 1.0,
    onTextScaleChanged: onTextScaleChanged ?? (_) {},
    onConsentChanged: (_) {},
    onRefresh: () {},
    onSubmitRequest: onSubmitRequest ?? (_) {},
    onSubmitSupportTicket: (_) async {},
    onClearCache: () async {},
    onSignOut: () {},
    onChangeServer: () {},
    biometricEnabled: false,
    onBiometricChanged: (_) {},
    notificationRevision: notificationRevision,
    notificationType: notificationType,
    notificationOpened: notificationOpened,
  ),
);

Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  final scrollable = find.descendant(
    of: find.byType(ListView).last,
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(finder, 240, scrollable: scrollable);
  await tester.pumpAndSettle();
}

Future<void> _scrollToTop(WidgetTester tester) async {
  final scrollable = find.descendant(
    of: find.byType(ListView).last,
    matching: find.byType(Scrollable),
  );
  await tester.drag(scrollable, const Offset(0, 1000));
  await tester.pumpAndSettle();
}
