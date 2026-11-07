import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/flutter/app_store_ipa_output_guard.dart';

void main() {
  final host = Platform.isWindows ? WindowsHost() : LinuxHost();

  late Directory temp;
  late AppStoreIpaOutputGuard guard;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xcross_ipa_guard_');
    guard = AppStoreIpaOutputGuard(host: host);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('does nothing when no previous IPA exists', () async {
    final archived = await guard.archiveExisting(
      outputDirectory: temp.path,
      appName: 'Runner',
    );

    expect(archived, isNull);
  });

  test('archives old IPA without leaving a stale current IPA', () async {
    final current = File(p.join(temp.path, 'Runner.ipa'));
    current.writeAsBytesSync([1, 2, 3]);

    final archived = await guard.archiveExisting(
      outputDirectory: temp.path,
      appName: 'Runner',
    );

    expect(archived, isNotNull);
    expect(current.existsSync(), isFalse);
    expect(File(archived!).readAsBytesSync(), [1, 2, 3]);

    // A later successful build can create a new current IPA.
    current.writeAsBytesSync([4, 5, 6]);

    final second = await guard.archiveExisting(
      outputDirectory: temp.path,
      appName: 'Runner',
    );

    expect(second, isNotNull);
    expect(second, isNot(archived));

    expect(File(archived).readAsBytesSync(), [1, 2, 3]);
    expect(File(second!).readAsBytesSync(), [4, 5, 6]);
    expect(current.existsSync(), isFalse);
  });
}
