import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/cli/shared/ipa_packager.dart';

void main() {
  final host = Platform.isWindows ? WindowsHost() : LinuxHost();

  late Directory temp;
  late String appPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xcross_signed_ipa_');
    appPath = p.join(temp.path, 'Runner.app');
    Directory(appPath).createSync();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  void write(String relativePath, List<int> bytes) {
    final file = File(p.joinAll([appPath, ...p.posix.split(relativePath)]));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  test('preserves all signing artifacts byte-for-byte', () async {
    final contents = <String, List<int>>{
      'Info.plist': utf8.encode('<plist>Runner</plist>'),
      'Runner': [0, 1, 2, 3, 255],
      'embedded.mobileprovision': [10, 20, 30, 40],
      '_CodeSignature/CodeResources': [50, 60, 70, 80],
      'Frameworks/App.framework/App': [90, 100, 110],
      'Frameworks/App.framework/_CodeSignature/CodeResources': [120, 130, 140],
    };

    for (final entry in contents.entries) {
      write(entry.key, entry.value);
    }

    final ipaPath = await IpaPackager(host: host).package(appPath);

    final archive = ZipDecoder().decodeBytes(File(ipaPath).readAsBytesSync());

    expect(archive.files, hasLength(contents.length));

    for (final entry in contents.entries) {
      final expectedName = 'Payload/Runner.app/${entry.key}';

      final packaged = archive.files.singleWhere(
        (file) => file.name == expectedName,
      );

      expect(
        packaged.content,
        equals(entry.value),
        reason: 'Modified IPA entry: $expectedName',
      );
    }
  });

  test('repackaging removes obsolete entries', () async {
    write('Runner', [1, 2, 3]);
    write('obsolete.txt', [9, 9, 9]);

    await IpaPackager(host: host).package(appPath);

    File(p.join(appPath, 'obsolete.txt')).deleteSync();

    write('Runner', [4, 5, 6]);
    write('embedded.mobileprovision', [7, 8, 9]);
    write('_CodeSignature/CodeResources', [10, 11, 12]);

    final ipaPath = await IpaPackager(host: host).package(appPath);

    final archive = ZipDecoder().decodeBytes(File(ipaPath).readAsBytesSync());

    final names = archive.files.map((e) => e.name).toSet();

    expect(names, {
      'Payload/Runner.app/Runner',
      'Payload/Runner.app/embedded.mobileprovision',
      'Payload/Runner.app/_CodeSignature/CodeResources',
    });

    final runner = archive.files.singleWhere(
      (e) => e.name == 'Payload/Runner.app/Runner',
    );

    expect(runner.content, [4, 5, 6]);
  });
  test('failure preserves previous IPA', () async {
    write('Runner', [1, 2, 3]);

    final packager = IpaPackager(host: host);
    final previousIpa = await packager.package(appPath);
    final previousBytes = File(previousIpa).readAsBytesSync();

    Directory(appPath).deleteSync(recursive: true);

    await expectLater(
      packager.package(appPath),
      throwsA(isA<FileSystemException>()),
    );

    expect(File(previousIpa).readAsBytesSync(), previousBytes);
  });
  test('restores previous IPA when publishing fails', () async {
    write('Runner', [1, 2, 3]);

    final previousPath = await IpaPackager(host: host).package(appPath);

    final originalBytes = File(previousPath).readAsBytesSync();

    write('Runner', [4, 5, 6]);

    var renames = 0;

    final failingPackager = IpaPackager(
      host: host,
      renameFileForTesting: (file, destination) {
        renames++;

        if (renames == 2) {
          throw const FileSystemException('Injected publishing failure');
        }

        return file.rename(destination);
      },
    );

    await expectLater(
      failingPackager.package(appPath),
      throwsA(isA<FileSystemException>()),
    );

    expect(renames, 3);
    expect(File(previousPath).readAsBytesSync(), originalBytes);

    final recoveryDirs = temp.listSync().whereType<Directory>().where(
      (dir) => p.basename(dir.path).startsWith('.xcross-ipa-'),
    );

    expect(recoveryDirs, isEmpty);
  });

  test('preserves recovery backup when rollback fails', () async {
    write('Runner', [1, 2, 3]);

    final previousPath = await IpaPackager(host: host).package(appPath);

    final originalBytes = File(previousPath).readAsBytesSync();

    write('Runner', [4, 5, 6]);

    var renames = 0;

    final failingPackager = IpaPackager(
      host: host,
      renameFileForTesting: (file, destination) {
        renames++;

        if (renames >= 2) {
          throw const FileSystemException(
            'Injected publishing or rollback failure',
          );
        }

        return file.rename(destination);
      },
    );

    await expectLater(
      failingPackager.package(appPath),
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.message,
          'message',
          contains('rollback both failed'),
        ),
      ),
    );

    expect(renames, 3);

    final recoveryDirs = temp
        .listSync()
        .whereType<Directory>()
        .where((dir) => p.basename(dir.path).startsWith('.xcross-ipa-'))
        .toList();

    expect(recoveryDirs, hasLength(1));

    final backup = File(p.join(recoveryDirs.single.path, 'previous.ipa'));

    expect(backup.existsSync(), isTrue);
    expect(backup.readAsBytesSync(), originalBytes);

    // Publishing failed, but the old IPA is recoverable.
    expect(File(previousPath).existsSync(), isFalse);
  });
}
