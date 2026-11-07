import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

/// Moves an existing IPA out of the current build output before signing.
@internal
final class AppStoreIpaOutputGuard {
  const AppStoreIpaOutputGuard({required this.host});

  final PlatformHostInterface host;

  Future<String?> archiveExisting({
    required String outputDirectory,
    required String appName,
  }) async {
    final paths = host.paths.context;

    final ipaPath = paths.join(outputDirectory, '$appName.ipa');
    final existing = host.fileSystem.file(ipaPath);

    if (!existing.existsSync()) return null;

    final archiveRoot = host.fileSystem.directory(
      paths.join(outputDirectory, 'previous-ipas'),
    );

    await archiveRoot.create(recursive: true);

    // Unique directory: never overwrite a previous successful build.
    final archiveDir = await archiveRoot.createTemp('$appName-');

    final archivedPath = paths.join(archiveDir.path, '$appName.ipa');

    try {
      await existing.rename(host.paths.ioPath(archivedPath));
    } on FileSystemException {
      try {
        await archiveDir.delete();
      } on FileSystemException {
        // Preserve the original move failure.
      }
      rethrow;
    }

    return archivedPath;
  }
}
