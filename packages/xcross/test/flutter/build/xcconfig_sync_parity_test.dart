import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/xcconfig_resolver.dart';

void main() {
  test('sync and async xcconfig readers produce equivalent versions', () async {
    final root = Directory.systemTemp.createTempSync('xcross-xcconfig-parity-');

    addTearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    final flutter = Directory(p.join(root.path, 'ios', 'Flutter'))
      ..createSync(recursive: true);

    final generated = File(p.join(flutter.path, 'Generated.xcconfig'))
      ..writeAsStringSync(
        'FLUTTER_BUILD_NAME=1.0.0\n'
        'FLUTTER_BUILD_NUMBER=7\n',
      );

    File(p.join(flutter.path, 'Nested.xcconfig')).writeAsStringSync(
      'FLUTTER_BUILD_NUMBER[sdk=iphoneos*]=9\n'
      r'CUSTOM_REF=$(FLUTTER_BUILD_NUMBER)'
      '\n',
    );

    final debug = File(p.join(flutter.path, 'Debug.xcconfig'))
      ..writeAsStringSync(
        '#include "Generated.xcconfig"\n'
        '#include? "OptionalMissing.xcconfig"\n'
        '#include "Nested.xcconfig"\n',
      );

    final PlatformHostInterface host = Platform.isWindows
        ? WindowsHost(
            currentDirectory: root.path,
            temporaryDirectory: root.path,
          )
        : LinuxHost(currentDirectory: root.path, temporaryDirectory: root.path);

    final resolver = XcconfigResolver(host.fileSystem, host.paths.context);

    Future<void> check(
      String expected, {
      Map<String, String> overrides = const {},
    }) async {
      final syncValues = resolver.readDebugConfigurationSync(
        debugPath: debug.path,
        generatedPath: generated.path,
        overrides: overrides,
      );

      final asyncValues = await resolver.readDebugConfiguration(
        debugPath: debug.path,
        generatedPath: generated.path,
        overrides: overrides,
      );

      expect(syncValues, asyncValues);
      expect(syncValues['FLUTTER_BUILD_NUMBER'], expected);
      expect(syncValues['FLUTTER_BUILD_NAME'], '1.0.0');
    }

    // Nested include and conditional configuration.
    await check('9');

    // Explicit override must win.
    await check('11', overrides: {'FLUTTER_BUILD_NUMBER': '11'});

    // Missing Debug.xcconfig must fall back to Generated.xcconfig.
    debug.deleteSync();

    await check('7');
  });
}
