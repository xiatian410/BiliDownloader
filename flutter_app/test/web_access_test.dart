import 'dart:convert';
import 'dart:io';

import 'package:bili_downloader/server/access_policy.dart';
import 'package:bili_downloader/server/web_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'web_service_test.dart' show ServiceFixtureApi;

void main() {
  final key = List.filled(64, 'a').join();
  final nextKey = List.filled(64, 'b').join();
  late Directory temp;
  late WebService service;
  late HttpClient client;
  var cookie = '';
  var now = DateTime.utc(2026, 10, 28);

  AccessPolicy policy({
    String? secret,
    Duration? lifetime,
    bool remote = false,
  }) => AccessPolicy(
    key: secret ?? key,
    publicOrigin: remote ? Uri.parse('https://download.example.test') : null,
    now: () => now,
    lifetime: lifetime ?? const Duration(hours: 12),
  );
  Future<void> start(AccessPolicy access) async {
    service = WebService(
      webRoot: '${temp.path}/web',
      downloadRoot: '${temp.path}/data',
      access: access,
      apiFactory: () => ServiceFixtureApi('http://127.0.0.1/unused'),
    );
    await service.start(port: 0);
  }

  Future<(int, Map<String, dynamic>, HttpHeaders)> request(
    String route, {
    Map<String, dynamic>? body,
    String? owner,
    String? host,
    String? origin,
    String method = 'POST',
    bool header = true,
  }) async {
    final r = await client.openUrl(
      method,
      Uri.parse('${service.origin}$route'),
    );
    if (header) r.headers.set('X-Bili-Client', '1');
    r.headers.set('Cookie', owner ?? cookie);
    if (host != null) r.headers.set('Host', host);
    if (origin != null) r.headers.set('Origin', origin);
    if (method == 'POST') {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body ?? {}));
    }
    final response = await r.close();
    final text = await utf8.decoder.bind(response).join();
    return (
      response.statusCode,
      jsonDecode(text) as Map<String, dynamic>,
      response.headers,
    );
  }

  Future<Map<String, dynamic>> unlock({String? secret}) async {
    final result = await request(
      '/api/access/unlock',
      body: {'key': secret ?? key},
    );
    expect(result.$1, 200);
    cookie = result.$3.value('set-cookie')!.split(';').first;
    return result.$2;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bili-access-test-');
    await Directory('${temp.path}/web').create();
    await File('${temp.path}/web/index.html').writeAsString('fixture');
    cookie = '';
    now = DateTime.utc(2026, 10, 28);
    client = HttpClient();
    await start(policy());
  });
  tearDown(() async {
    client.close(force: true);
    await service.close();
    await temp.delete(recursive: true);
  });

  test('unauthenticated bootstrap creates no workspace and private routes reject access', () async {
    final session = await request('/api/session');
    expect(session.$2, {'accessRequired': true, 'accessGranted': false});
    expect(session.$3.value('set-cookie'), isNull);
    expect(
      (await request('/api/session', body: {'existingWorkspace': true})).$1,
      401,
    );
    expect(
      (await Directory(
        '${temp.path}/data/.state',
      ).list().toList()).where((f) => f.path.endsWith('.json')),
      isEmpty,
    );
    expect((await request('/api/resolve', body: {'input': 'av1'})).$1, 401);
    expect((await request('/api/files/private/0', method: 'GET')).$1, 401);
    expect((await request('/api/cover/private', method: 'GET')).$1, 401);
    expect(
      (await request('/api/access/unlock', body: {'key': 'wrong'})).$1,
      403,
    );
    expect(
      (await request(
        '/api/access/unlock',
        body: {'key': key},
        header: false,
      )).$1,
      403,
    );
    expect(
      (await request(
        '/api/access/unlock',
        body: {'key': key},
        origin: 'https://evil.test',
      )).$1,
      403,
    );
  });

  test('locking and expiry preserve ownership while login rotates the bearer token', () async {
    final first = await unlock();
    final oldCookie = cookie;
    await request('/api/settings', body: {'concurrency': 2});
    final socket = await WebSocket.connect(
      '${service.origin.replaceFirst('http', 'ws')}/api/events',
      headers: {'Cookie': cookie},
    );
    final closed = socket.drain<void>();
    expect((await request('/api/access/lock')).$1, 200);
    await closed.timeout(const Duration(seconds: 2));
    expect(socket.closeCode, 4001);
    expect((await request('/api/session')).$2['accessGranted'], false);
    expect((await request('/api/settings', body: {'concurrency': 3})).$1, 401);
    final restored = await unlock();
    expect(restored['workspace'], first['workspace']);
    expect(restored['concurrency'], 2);
    expect(cookie, isNot(oldCookie));
    expect((await request('/api/session', owner: oldCookie)).$1, 401);
    now = now.add(const Duration(hours: 13));
    expect((await request('/api/session')).$2['accessGranted'], false);
    expect((await unlock())['workspace'], first['workspace']);
  });

  test(
    'an idle socket closes at the access deadline without polling',
    () async {
      await service.close();
      await start(policy(lifetime: const Duration(milliseconds: 500)));
      await unlock();
      final socket = await WebSocket.connect(
        '${service.origin.replaceFirst('http', 'ws')}/api/events',
        headers: {'Cookie': cookie},
      );
      await socket.drain<void>().timeout(const Duration(seconds: 3));
      expect(socket.closeCode, 4001);
    },
  );

  test('restart preserves access, rotating the operator key revokes access but retains the workspace', () async {
    final first = await unlock();
    await request('/api/settings', body: {'concurrency': 2});
    await service.close();
    await start(policy());
    expect((await request('/api/session')).$2['workspace'], first['workspace']);
    await service.close();
    await start(policy(secret: nextKey));
    expect((await request('/api/session')).$2['accessGranted'], false);
    expect((await request('/api/access/unlock', body: {'key': key})).$1, 403);
    final restored = await unlock(secret: nextKey);
    expect(restored['workspace'], first['workspace']);
    expect(restored['concurrency'], 2);
    final state = await Directory('${temp.path}/data/.state')
        .list()
        .where((f) => f.path.endsWith('.json'))
        .toList();
    for (final f in state) {
      final text = await File(f.path).readAsString();
      expect(text.contains(key), false);
      expect(text.contains(nextKey), false);
      expect(text.contains(cookie.split('=').last), false);
    }
  });

  test('unknown ownership is not silently replaced and separate browsers get separate workspaces', () async {
    final first = await unlock();
    final owner = cookie;
    cookie = 'bili_session=${List.filled(64, 'c').join()}';
    expect((await request('/api/session')).$1, 401);
    expect((await request('/api/access/unlock', body: {'key': key})).$1, 401);
    final replacement = await request(
      '/api/access/unlock',
      body: {'key': key, 'newWorkspace': true},
    );
    expect(replacement.$1, 200);
    expect(replacement.$2['workspace'], isNot(first['workspace']));
    expect(
      (await request('/api/session', owner: owner)).$2['workspace'],
      first['workspace'],
    );
  });

  test(
    'recovering an older history generation never restores revoked access',
    () async {
      await unlock();
      await request('/api/access/lock');
      await service.close();
      final files = await Directory('${temp.path}/data/.state')
          .list()
          .where((file) => file.path.endsWith('.json'))
          .toList();
      final generations = <(int, File)>[];
      for (final entry in files) {
        final file = File(entry.path);
        final envelope = jsonDecode(await file.readAsString()) as Map;
        generations.add((envelope['generation'] as int, file));
      }
      generations.sort((a, b) => b.$1.compareTo(a.$1));
      await generations.first.$2.writeAsString('interrupted-record');
      await start(policy());
      expect((await request('/api/session')).$2['accessGranted'], false);
      final restored = await unlock();
      expect(restored['recovered'], true);
    },
  );

  test('remote mode accepts only the configured host and origin and uses a host-only Secure cookie', () async {
    await service.close();
    await start(policy(remote: true));
    expect((await request('/api/session')).$1, 403);
    expect(
      (await request(
        '/api/access/unlock',
        body: {'key': key},
        host: 'download.example.test',
        origin: 'http://download.example.test',
      )).$1,
      403,
    );
    final result = await request(
      '/api/access/unlock',
      body: {'key': key},
      host: 'download.example.test',
      origin: 'https://download.example.test',
    );
    expect(result.$1, 200);
    final header = result.$3.value('set-cookie')!;
    expect(header, startsWith('__Host-bili_session='));
    expect(header, contains('; Secure'));
    expect(header, contains('HttpOnly'));
    expect(header, contains('SameSite=Strict'));
    expect(header, isNot(contains('Domain=')));
  });

  test('key generation is exclusive and loading rejects public files and insecure origins', () async {
    final path = '${temp.path}/access.key';
    await AccessPolicy.generateKey(path);
    await expectLater(
      AccessPolicy.generateKey(path),
      throwsA(isA<FileSystemException>()),
    );
    final loaded = await AccessPolicy.load(
      keyFile: path,
      webRoot: '${temp.path}/web',
      publicOrigin: 'https://download.example.test',
    );
    expect(loaded.accepts((await File(path).readAsString()).trim()), true);
    expect(
      () => AccessPolicy(
        key: key,
        publicOrigin: Uri.parse('http://download.example.test'),
      ),
      throwsArgumentError,
    );
    expect(
      () => AccessPolicy(
        key: key,
        publicOrigin: Uri.parse('https://download.example.test/path'),
      ),
      throwsArgumentError,
    );
    await AccessPolicy.generateKey('${temp.path}/web/public.key');
    await expectLater(
      AccessPolicy.load(
        keyFile: '${temp.path}/web/public.key',
        webRoot: '${temp.path}/web',
      ),
      throwsArgumentError,
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['644', path]);
      await expectLater(
        AccessPolicy.load(keyFile: path, webRoot: '${temp.path}/web'),
        throwsArgumentError,
      );
    }
  });
}
