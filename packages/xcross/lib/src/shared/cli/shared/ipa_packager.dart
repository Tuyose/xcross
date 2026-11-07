import 'dart:io';
import 'dart:typed_data';

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
    await for (final entity in appDir.list(recursive: true)) {
      if (entity is! File) continue; // dirs are implicit from entry paths
      final rel = paths.relative(entity.path, from: appDir.path);
      final entryName = p.posix.joinAll([
        'Payload',
        appName,
        ...paths.split(rel),
      ]);
      final bytes = await entity.readAsBytes();
      final file = ArchiveFile.bytes(entryName, bytes);

      // Windows does not report POSIX executable bits for Mach-O files.
      // Recognize Mach-O headers and store executable ZIP permissions.
      final isMachO =
          bytes.length >= 4 &&
          const <int>{
            0xCAFE_BABE,
            0xBEBA_FECA,
            0xFEED_FACE,
            0xCEFA_EDFE,
            0xFEED_FACF,
            0xCFFA_EDFE,
          }.contains(ByteData.sublistView(bytes).getUint32(0, Endian.little));

      file.mode = isMachO
          ? 0x1ED // Unix 0755: executable, not world-writable.
          : entity.statSync().mode & 0xFFF;
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
        await _renameFile(staged, host.paths.ioPath(ipaPath));
      } catch (publishError, publishTrace) {
        if (backup.existsSync()) {
          try {
            await _renameFile(backup, host.paths.ioPath(ipaPath));
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
}
