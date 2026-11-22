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
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
      '<plist version="1.0"><dict>'
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

  void writeExtension(String name, String? id) {
    final extensionPath = p.join(appPath, 'PlugIns', '$name.appex');
    Directory(extensionPath).createSync(recursive: true);
    File(p.join(extensionPath, 'Info.plist')).writeAsStringSync(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
      '<plist version="1.0"><dict>'
      '${id == null ? '' : '<key>CFBundleIdentifier</key><string>$id</string>'}'
      '</dict></plist>',
    );
  }

  test('discovers each embedded extension Bundle ID', () {
    writeExtension('Share', 'com.example.app.share');
    writeExtension('Widget', 'com.example.app.widget');

    expect(
      AppStoreIpaSigningOperation.embeddedExtensions(
        appPath: appPath,
        fileSystem: host.fileSystem,
        paths: host.paths,
      ),
      {
        'com.example.app.share': p.join(appPath, 'PlugIns', 'Share.appex'),
        'com.example.app.widget': p.join(appPath, 'PlugIns', 'Widget.appex'),
      },
    );
  });

  test('rejects an embedded extension without Info.plist', () {
    Directory(
      p.join(appPath, 'PlugIns', 'Widget.appex'),
    ).createSync(recursive: true);

    expect(
      () => AppStoreIpaSigningOperation.embeddedExtensions(
        appPath: appPath,
        fileSystem: host.fileSystem,
        paths: host.paths,
      ),
      throwsA(isA<XcrossError>()),
    );
  });
}
