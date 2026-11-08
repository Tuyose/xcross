import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/flutter/app_store_ipa_signing_operation.dart';
import 'package:xcross/src/shared/errors/errors.dart';

void main() {
  final host = Platform.isWindows ? WindowsHost() : LinuxHost();

  late Directory temp;
  late String appPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xcross_appstore_id_');
    appPath = p.join(temp.path, 'Runner.app');
    Directory(appPath).createSync();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  void writeBundleId(String? id) {
    File(p.join(appPath, 'Info.plist')).writeAsStringSync(
      '<plist><dict>'
      '${id == null ? '' : '<key>CFBundleIdentifier</key><string>$id</string>'}'
      '</dict></plist>',
    );
  }

  Future<void> verify(String bundleId) =>
      AppStoreIpaSigningOperation.verifyBundleId(
        appPath: appPath,
        bundleId: bundleId,
        fileSystem: host.fileSystem,
        paths: host.paths,
      );

  test('accepts matching Bundle ID', () async {
    writeBundleId('com.example.app');
    await expectLater(verify('com.example.app'), completes);
  });

  test('rejects different Bundle ID', () async {
    writeBundleId('com.example.other');
    await expectLater(
      verify('com.example.app'),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('expected Bundle ID'),
        ),
      ),
    );
  });

  test('rejects missing Info.plist', () async {
    await expectLater(verify('com.example.app'), throwsA(isA<XcrossError>()));
  });

  test('rejects missing CFBundleIdentifier', () async {
    writeBundleId(null);
    await expectLater(verify('com.example.app'), throwsA(isA<XcrossError>()));
  });
}
