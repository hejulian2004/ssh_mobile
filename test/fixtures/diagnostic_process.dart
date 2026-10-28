import 'dart:convert';
import 'dart:io';

// Synthetic private-file transport; never contacts a device or reads user data.
Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == 'run') {
    final component = arguments.contains('./cmd/relay')
        ? 'relay'
        : arguments.contains('./cmd/admin')
        ? 'admin'
        : arguments.contains('dev')
        ? 'front'
        : 'app';
    final run = Platform.environment['SSH_MOBILE_LOG_RUN_ID']!;
    stdout.writeln(
      jsonEncode({
        'schema_version': 1,
        'run_id': run,
        'instance_id': 'fixture',
        'component': component,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'level': 'info',
        'message': 'fixture_ready',
        'event': 'fixture_ready',
        'trace_id': 'fixture-trace',
        'error_code': 'FIXTURE',
        'details': 'password=fixture-value',
        'error': 'token=fixture-value',
        'stack': 'token=fixture-value',
        'attributes': {'duration_ms': 5},
      }),
    );
    stdout.writeln('public unstructured fixture output');
    if (component == 'front') {
      for (final event in ['browser_ready', 'diagnostic_dropped']) {
        stdout.writeln(
          jsonEncode({
            'schema_version': 1,
            'run_id': run,
            'instance_id': 'fixture',
            'component': component,
            'occurred_at': DateTime.now().toUtc().toIso8601String(),
            'level': 'info',
            'message': event,
            'event': event,
            'attributes': {'count': 1},
          }),
        );
      }
    }
    stderr.writeln('public unstructured stderr fixture');
    if (component == 'app') {
      await stdin
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((line) => line == 'q');
    } else {
      final port = component == 'front'
          ? int.parse(Platform.environment['FRONT_DEV_PORT']!)
          : int.parse(
              Platform
                  .environment[component == 'relay'
                      ? 'RELAY_ADDR'
                      : 'ADMIN_ADDR']!
                  .split(':')
                  .last,
            );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      await for (final request in server) {
        request.response.statusCode = 204;
        await request.response.close();
        if (request.uri.path == '/__agent_stop') {
          await server.close(force: true);
          break;
        }
        if (component != 'front') {
          await server.close(force: true);
          break;
        }
      }
    }
    return;
  }
  if (arguments.contains('offline')) {
    exitCode = 1;
    return;
  }
  if (arguments.contains('find')) {
    final base = arguments[arguments.indexOf('find') + 1];
    stdout.writeln('$base/flutter-instance.jsonl');
    stdout.writeln('$base/flutter-instance.health.json');
  } else if (arguments.contains('cat')) {
    if (arguments.last.endsWith('.health.json')) {
      stdout.writeln(
        jsonEncode({
          'written': 1,
          'dropped': 0,
          'failed': 0,
          'closed': true,
          'updated_at': 'private-value',
          'payload': 'private-value',
        }),
      );
      return;
    }
    final run = arguments.last.split('/')[2];
    stdout.writeln(
      jsonEncode({
        'schema_version': 1,
        'run_id': run,
        'instance_id': 'instance',
        'component': 'flutter',
        'occurred_at': '2026-01-01T00:00:00Z',
        'level': 'error',
        'message': 'password=fixture-value',
        'attributes': {},
      }),
    );
    stdout.write('{"incomplete":');
  }
}
