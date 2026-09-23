import 'package:connexia/core/host_protocol.dart';
import 'package:connexia/core/remote/remote_session.dart';
import 'package:connexia/ui/screens/active_connections_screen.dart';
import 'package:connexia/ui/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('remote desktops list renders graphical sessions', (
    tester,
  ) async {
    final manager = RemoteSessionManager();
    manager.addSessionForTesting(
      RemoteSession(
          id: 'r1',
          title: 'Win Box',
          protocol: HostProtocol.rdp,
          width: 1280,
          height: 800,
        )
        ..address = '10.0.0.5'
        ..username = 'admin'
        ..status = RemoteStatus.connected,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [remoteManagerProvider.overrideWith((ref) => manager)],
        child: MaterialApp(
          home: Scaffold(
            body: ActiveConnectionsScreen(kind: ActiveConnectionKind.remotes),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Win Box'), findsOneWidget);
    expect(find.text('admin@10.0.0.5'), findsOneWidget);
  });

  testWidgets('remote desktops list shows an empty state without sessions', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remoteManagerProvider.overrideWith((ref) => RemoteSessionManager()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ActiveConnectionsScreen(kind: ActiveConnectionKind.remotes),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No active connections'), findsOneWidget);
  });
}
