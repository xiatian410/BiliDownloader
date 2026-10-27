import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:bili_downloader/platform/platform.dart' as platform;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'isolated Linux keyring stores, reads and deletes a session',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      const fixture = '{"SESSDATA":"integration-fixture-only"}';
      try {
        expect(await platform.readLinuxCredentials(), isNull);
        await platform.writeLinuxCredentials(fixture);
        expect(await platform.readLinuxCredentials(), fixture);
        await platform.writeLinuxCredentials(null);
        expect(await platform.readLinuxCredentials(), isNull);
      } finally {
        await platform.writeLinuxCredentials(null);
      }
    },
    // Only the wrapper starts a private D-Bus service and temporary keyring.
    skip:
        !platform.isLinux ||
        !const bool.fromEnvironment('BILI_ISOLATED_KEYRING'),
  );
}
