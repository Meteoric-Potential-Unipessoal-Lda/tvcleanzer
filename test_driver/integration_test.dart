import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Saves binding.takeScreenshot() images to build/store_shots/.
Future<void> main() => integrationDriver(
      onScreenshot: (name, bytes, [args]) async {
        final f = File('build/store_shots/$name.png');
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
        return true;
      },
    );
