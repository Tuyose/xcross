import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Groups `.ipa` packaging.
@internal
final class IpaPackager {
  const IpaPackager({required this.host, this.renameFileForTesting});

  /// Injects file move failures in tests; production uses File.rename.
  @visibleForTesting
  final Future<File> Function(File file, String destination)?
  renameFileForTesting;

  Future<File> _renameFile(File file, String destination) =>
      renameFileForTesting?.call(file, destination) ?? file.rename(destination);

  final PlatformHostInterface host;

  /// Package an `.app` into an `.ipa` (`Payload/<app>` zipped), pure Dart.
  ///
  /// Symlinks are dereferenced (iOS `.app` bundles are flat and codesign
  /// rejects interior symlinks, so this matches `zip` without `-y`). Unix
  /// file modes are recorded on each entry. Returns the `.ipa` path.
  Future<String> package(String appPath) async {
    final paths = host.paths.context;
    final appDir = host.fileSystem.directory(appPath);
    final appName = paths.basename(appPath);
    final ipaPath = paths.join(
      paths.dirname(appPath),
      '${paths.basenameWithoutExtension(appPath)}.ipa',
    );
    final ipaFile = host.fileSystem.file(ipaPath);

    final archive = Archive();
    // list() follows symlinks by default → they resolve to real files/dirs.
    final files = <File>[
      await for (final entity in appDir.list(recursive: true))
        if (entity is File) entity,
    ]..sort((a, b) => a.path.compareTo(b.path));

    for (final entity in files) {
      final rel = paths.relative(entity.path, from: appDir.path);
      final entryName = p.posix.joinAll([
        'Payload',
        appName,
        ...paths.split(rel),
      ]);
      final bytes = await entity.readAsBytes();
      final file = ArchiveFile.bytes(entryName, bytes);

      file.mode = entryMode(entity.statSync().mode, bytes);
      archive.addFile(file);
    }

    final zipBytes = ZipEncoder().encode(archive);

    // Stage the complete archive before touching a previous IPA.
    final stagingDir = await host.fileSystem
        .directory(paths.dirname(ipaPath))
        .createTemp('.xcross-ipa-');

    var preserveRecoveryFiles = false;

    try {
      final staged = host.fileSystem.file(
        paths.join(stagingDir.path, 'new.ipa'),
      );
      final backup = host.fileSystem.file(
        paths.join(stagingDir.path, 'previous.ipa'),
      );

      await staged.writeAsBytes(zipBytes, flush: true);

      if (ipaFile.existsSync()) {
        await _renameFile(ipaFile, host.paths.ioPath(backup.path));
      }

      try {
        await _renameFile(staged, host.paths.ioPath(ipaFile.path));
      } catch (publishError, publishTrace) {
        if (backup.existsSync()) {
          try {
            await _renameFile(backup, host.paths.ioPath(ipaFile.path));
          } catch (restoreError) {
            // Never delete the only surviving copy of the previous IPA.
            preserveRecoveryFiles = true;

            throw FileSystemException(
              'IPA publishing and rollback both failed. '
              'Previous IPA preserved at "${backup.path}". '
              'Publish error: $publishError; '
              'restore error: $restoreError',
              ipaPath,
            );
          }
        }

        Error.throwWithStackTrace(publishError, publishTrace);
      }
    } finally {
      if (!preserveRecoveryFiles) {
        await stagingDir.delete(recursive: true);
      }
    }

    return ipaPath;
  }

  /// Unix mode recorded for an IPA entry.
  ///
  /// Windows `stat` has no exec bit (and reports `0666`-style modes), so a
  /// Mach-O main executable or framework binary would land in the IPA
  /// non-executable and installd would refuse to launch it. Mach-O files are
  /// therefore always `0755`; other files keep their host mode, falling back
  /// to `0644` when the host reports none.
  @visibleForTesting
  static int entryMode(int statMode, List<int> bytes) {
    if (_isMachO(bytes)) return 0x1ED; // 0755
    final mode = statMode & 0x1FF;
    return mode == 0 ? 0x1A4 : mode;
  }

  static bool _isMachO(List<int> b) {
    if (b.length < 4) return false;
    final be = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    return be == 0xFEEDFACE ||
        be == 0xFEEDFACF ||
        be == 0xCEFAEDFE ||
        be == 0xCFFAEDFE ||
        be == 0xCAFEBABE ||
        be == 0xCAFEBABF;
  }
}
