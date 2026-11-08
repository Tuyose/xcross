import 'package:test/test.dart';
import 'package:xcross/src/shared/apple/asset_catalog/app_icon_stager.dart';
import 'package:xml/xml.dart';

void main() {
  const icons = AppIconPlist(
    cfBundleIcons: {
      'CFBundlePrimaryIcon': {
        'CFBundleIconName': 'AppIcon',
        'CFBundleIconFiles': ['AppIcon60x60'],
      },
    },
  );

  List<String> topLevelIconNames(String xml) {
    final root = XmlDocument.parse(xml).rootElement.getElement('dict')!;

    final children = root.childElements.toList();
    final names = <String>[];

    for (var i = 0; i < children.length - 1; i++) {
      if (children[i].name.local == 'key' &&
          children[i].innerText == 'CFBundleIconName') {
        names.add(children[i + 1].innerText);
      }
    }

    return names;
  }

  test('adds top-level CFBundleIconName', () {
    const input = '''
<plist>
<dict>
<key>CFBundleName</key>
<string>Runner</string>
</dict>
</plist>
''';

    final output = AppIconPlist.applyToInfoPlist(input, icons);

    expect(topLevelIconNames(output), ['AppIcon']);
  });

  test('updates stale icon name without duplicates', () {
    const input = '''
<plist>
<dict>
<key>CFBundleIconName</key>
<string>OldIcon</string>
</dict>
</plist>
''';

    final output = AppIconPlist.applyToInfoPlist(input, icons);

    expect(topLevelIconNames(output), ['AppIcon']);
  });
}
