import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/info_plist.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xml/xml.dart';

import '../../host_operations_fixtures.dart';
import '../flutter_test_runtime.dart';

void main() {
  test('app plist version policy matches resolved extension version', () async {
    final root = Directory.systemTemp.createTempSync('xcross-plist-match-');

    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final fs = FixtureMappedFileSystem(root);

    void write(String path, String contents) {
      fs.file(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    fs.directory('/selected-temp').createSync();

    write(
      '/selected-project/pubspec.yaml',
      'name: fixture\nversion: 1.0.0+42\n',
    );

    write(
      '/selected-project/ios/Runner/Info.plist',
      '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '<key>CFBundleIdentifier</key><string>com.example.fixture</string>\n'
          '<key>CFBundleShortVersionString</key><string>1.0.0</string>\n'
          '<key>CFBundleVersion</key><string>1</string>\n'
          '</dict>\n'
          '</plist>\n',
    );

    write('/selected-input/App.framework/App', 'kernel');
    write('/selected-input/Runner', 'runner');
    write('/selected-input/Native.framework/Native', 'native');

    write(
      '/selected-input/Flutter.xcframework/'
          'ios-arm64/Flutter.framework/Flutter',
      'engine',
    );

    final host = LinuxHost(
      fileSystem: fs,
      currentDirectory: '/selected-project',
      temporaryDirectory: '/selected-temp',
    );

    final runtime = testFlutterRuntime(IPhoneFlutterTarget(IPhoneTarget(host)));

    final request = FlutterBuildRequest(
      runtime: runtime,
      projectRoot: '/selected-project',
      bundleId: 'com.example.fixture',
      options: const FlutterBuildOptions(pub: false),
    );

    final context = FlutterBuildContext(
      request: request,
      flutterRoot: '/unused',
    );

    expect(context.versions.bundleVersion, '42');

    final assembler = FlutterBundleAssembler(context);

    final xml = assembler.alignAppBundleVersions(
      InfoPlist.expandXmlVars(
        fs.file('/selected-project/ios/Runner/Info.plist').readAsStringSync(),
        await assembler.buildSubstitutionMap(),
      ),
    );

    final elements = XmlDocument.parse(
      xml,
    ).findAllElements('dict').first.childElements.toList();

    String? value(String key) {
      for (var i = 0; i < elements.length - 1; i++) {
        if (elements[i].name.local == 'key' && elements[i].innerText == key) {
          return elements[i + 1].innerText;
        }
      }
      return null;
    }

    final actual = value('CFBundleVersion');

    expect(value('CFBundleShortVersionString'), '1.0.0');
    expect(actual, context.versions.bundleVersion);
  });
}
