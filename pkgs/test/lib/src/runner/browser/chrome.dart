// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pedantic/pedantic.dart';
import 'package:test_api/src/backend/runtime.dart'; // ignore: implementation_imports
import 'package:test_core/src/util/io.dart'; // ignore: implementation_imports
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

import '../executable_settings.dart';
import 'browser.dart';
import 'default_settings.dart';

// TODO(nweiz): move this into its own package?
/// A class for running an instance of Chrome.
///
/// Most of the communication with the browser is expected to happen via HTTP,
/// so this exposes a bare-bones API. The browser starts as soon as the class is
/// constructed, and is killed when [close] is called.
///
/// Any errors starting or running the process are reported through [onExit].
class Chrome extends Browser {
  @override
  final name = 'Chrome';

  @override
  final Future<Uri> remoteDebuggerUrl;

  final Future<WipConnection> _tabConnection;
  final Map<String, String> _idsToScripts;

  /// Starts a new instance of Chrome open to the given [url], which may be a
  /// [Uri] or a [String].
  factory Chrome(Uri url, {ExecutableSettings settings, bool debug = false}) {
    settings ??= defaultSettings[Runtime.chrome];
    var remoteDebuggerCompleter = Completer<Uri>.sync();
    var tabConnectionCompleter = Completer<WipConnection>();
    var idsToScripts = <String, String>{};
    return Chrome._(
      () async {
        var tryPort = ([int port]) async {
          var dir = createTempDir();
          var args = [
            '--user-data-dir=$dir',
            url.toString(),
            '--disable-extensions',
            '--disable-popup-blocking',
            '--bwsi',
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-default-apps',
            '--disable-translate',
            '--disable-dev-shm-usage',
          ];

          if (!debug && settings.headless) {
            args.addAll([
              '--headless',
              '--disable-gpu',
              // We don't actually connect to the remote debugger, but Chrome will
              // close as soon as the page is loaded if we don't turn it on.
              '--remote-debugging-port=0'
            ]);
          }

          args.addAll(settings.arguments);

          // Currently, Chrome doesn't provide any way of ensuring that this port
          // was successfully bound. It produces an error if the binding fails,
          // but without a reliable and fast way to tell if it succeeded that
          // doesn't provide us much. It's very unlikely that this port will fail,
          // though.
          if (port != null) args.add('--remote-debugging-port=$port');

          var process = await Process.start(settings.executable, args);

          if (port != null) {
            remoteDebuggerCompleter.complete(
                getRemoteDebuggerUrl(Uri.parse('http://localhost:$port')));
            await process.stderr
                .transform(utf8.decoder)
                .transform(LineSplitter())
                .firstWhere((line) => line.startsWith('DevTools listening'))
                .timeout(Duration(seconds: 10));
            var chromeConnection = ChromeConnection('localhost', port);
            var tab = (await chromeConnection.getTabs()).first;
            var tabConnection = await tab.connect();
            await tabConnection.debugger.enable();
            tabConnection.debugger.onScriptParsed.listen((data) {
              if (data.script.url.isNotEmpty) {
                idsToScripts[data.script.scriptId] = data.script.url;
              }
            });
            await tabConnection.debugger.connection
                .sendCommand('Profiler.enable', {});
            await tabConnection.debugger.connection.sendCommand(
                'Profiler.startPreciseCoverage',
                {'detailed': true, 'callCount': false});
            tabConnectionCompleter.complete(tabConnection);
          } else {
            remoteDebuggerCompleter.complete(null);
          }

          unawaited(process.exitCode
              .then((_) => Directory(dir).deleteSync(recursive: true)));

          return process;
        };

        if (!debug) return tryPort();
        return getUnusedPort<Process>(tryPort);
      },
      remoteDebuggerCompleter.future,
      tabConnectionCompleter.future,
      idsToScripts,
    );
  }

  Future<void> gatherCoverage(String coverage) async {
    var tabConnection = await _tabConnection;
    var response = await tabConnection.debugger.connection
        .sendCommand('Profiler.takePreciseCoverage', {});
    var result = response.result['result'];
    for (var entry in result) {
      var scriptId = entry['scriptId'];
      var script = _idsToScripts[scriptId];
      if (script != null) {
        print(script);
      }
    }
  }

  Chrome._(Future<Process> Function() startBrowser, this.remoteDebuggerUrl,
      this._tabConnection, this._idsToScripts)
      : super(startBrowser);
}
