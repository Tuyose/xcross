import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/shared/ipa_packager.dart';

void main() {
  test(
    'Windows IPA preserves executable permissions for Mach-O binaries',
    () async {
      final temp = Directory.systemTemp.createTempSync('xcross_ipa_mode_');
      addTearDown(() => temp.deleteSync(recursive: true));

      final appPath = p.join(temp.path, 'Runner.app');
      Directory(appPath).createSync();

      final binaries = [
        'Runner',
        'Frameworks/App.framework/App',
        'Frameworks/Flutter.framework/Flutter',
        'Frameworks/libExample.dylib',
      ];

      for (final relative in binaries) {
        final file = File(p.joinAll([appPath, ...p.posix.split(relative)]));
        file.parent.createSync(recursive: true);

        // Mach-O 64-bit little-endian magic.
        file.writeAsBytesSync([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]);
      }

      final ipaPath = await IpaPackager(host: WindowsHost()).package(appPath);

      final archive = ZipDecoder().decodeBytes(File(ipaPath).readAsBytesSync());

      for (final relative in binaries) {
        final name = 'Payload/Runner.app/$relative';
        final entry = archive.files.singleWhere((file) => file.name == name);

        expect(
          entry.mode & 0x49,
          isNot(0),
          reason: '$name has no executable permission',
        );
      }
    },
    skip: !Platform.isWindows,
  );
}
