import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/internal/xcconfig_resolver.dart';
import 'package:xcross/src/shared/flutter/project/ios_bundle_versions_resolver.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';

void main() {
  late Directory root;
  late IosBundleVersionsResolver resolver;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross-build-config-');

    final flutter = Directory(p.join(root.path, 'ios', 'Flutter'))
      ..createSync(recursive: true);

    File(p.join(flutter.path, 'Generated.xcconfig')).writeAsStringSync(
      'FLUTTER_BUILD_NAME=0.1.0\n'
      'FLUTTER_BUILD_NUMBER=7\n',
    );

    final configurations = {
      'Debug': ('1.1.0', '11'),
      'Release': ('2.2.0', '22'),
      'Profile': ('3.3.0', '33'),
    };

    for (final entry in configurations.entries) {
      File(p.join(flutter.path, '${entry.key}.xcconfig')).writeAsStringSync(
        '#include "Generated.xcconfig"\n'
        'FLUTTER_BUILD_NAME=${entry.value.$1}\n'
        'FLUTTER_BUILD_NUMBER=${entry.value.$2}\n',
      );
    }

    final PlatformHostInterface host = Platform.isWindows
        ? WindowsHost(
            currentDirectory: root.path,
            temporaryDirectory: root.path,
          )
        : LinuxHost(currentDirectory: root.path, temporaryDirectory: root.path);

    resolver = IosBundleVersionsResolver(
      host.fileSystem,
      PbxProjectReader(host.fileSystem, host.paths.context),
    );
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('Debug uses Debug xcconfig', () {
    final versions = resolver.resolve(root.path);

    expect(versions.shortVersion, '1.1.0');
    expect(versions.bundleVersion, '11');
  });

  test('Release uses Release xcconfig', () {
    final versions = resolver.resolve(root.path, baseConfiguration: 'Release');

    expect(versions.shortVersion, '2.2.0');
    expect(versions.bundleVersion, '22');
  });

  test('Profile uses Profile xcconfig', () {
    final versions = resolver.resolve(root.path, baseConfiguration: 'Profile');

    expect(versions.shortVersion, '3.3.0');
    expect(versions.bundleVersion, '33');
  });
  test('Release-staging uses flavor-conditioned xcconfig', () {
    final configFile = File(
      p.join(root.path, 'ios', 'Flutter', 'Release.xcconfig'),
    );

    configFile.writeAsStringSync(
      '#include "Generated.xcconfig"\n'
      'FLUTTER_BUILD_NAME=2.2.0\n'
      'FLUTTER_BUILD_NUMBER=22\n'
      'FLUTTER_BUILD_NAME[config=Release-staging]=4.4.0\n'
      'FLUTTER_BUILD_NUMBER[config=Release-staging]=44\n',
    );

    final projectFile = File(
      p.join(root.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
    )..createSync(recursive: true);

    projectFile.writeAsStringSync('''
{
  archiveVersion = 1;
  classes = {};
  objectVersion = 50;
  objects = {
    PP01 = {
      isa = PBXProject;
      targets = (AA01,);
      buildConfigurationList = LL01;
    };
    AA01 = {
      isa = PBXNativeTarget;
      name = Runner;
      productType = "com.apple.product-type.application";
      buildConfigurationList = LL01;
    };
    LL01 = {
      isa = XCConfigurationList;
      buildConfigurations = (CC01,);
    };
    CC01 = {
      isa = XCBuildConfiguration;
      name = "Release-staging";
      buildSettings = {};
    };
  };
  rootObject = PP01;
}
''');

    final PlatformHostInterface host = Platform.isWindows
        ? WindowsHost(
            currentDirectory: root.path,
            temporaryDirectory: root.path,
          )
        : LinuxHost(currentDirectory: root.path, temporaryDirectory: root.path);

    final reader = PbxProjectReader(host.fileSystem, host.paths.context);

    final pbxprojPath = reader.findPbxproj(root.path);
    expect(pbxprojPath, isNotNull);

    final project = reader.parseFile(pbxprojPath!);

    expect(project?.configurationName('Release', 'staging'), 'Release-staging');

    final config = XcconfigResolver(host.fileSystem, host.paths.context)
        .readDebugConfigurationSync(
          debugPath: p.join(root.path, 'ios', 'Flutter', 'Release.xcconfig'),
          generatedPath: p.join(
            root.path,
            'ios',
            'Flutter',
            'Generated.xcconfig',
          ),
          configuration: 'Release-staging',
        );

    expect(config['FLUTTER_BUILD_NAME'], '4.4.0');
    expect(config['FLUTTER_BUILD_NUMBER'], '44');

    final versions = resolver.resolve(
      root.path,
      baseConfiguration: 'Release',
      flavor: 'staging',
    );

    expect(versions.shortVersion, '4.4.0');
    expect(versions.bundleVersion, '44');
  });
}
