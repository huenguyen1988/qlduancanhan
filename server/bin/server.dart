import 'dart:convert';
import 'dart:io';

import 'package:mongo_dart/mongo_dart.dart' as mongo;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

Future<void> main(List<String> args) async {
  final mongoUri =
      Platform.environment['MONGO_URI'] ?? 'mongodb://localhost:27017/duan1';

  final db = await mongo.Db.create(mongoUri);
  await db.open();
  stdout.writeln('✅ Connected to MongoDB at $mongoUri');

  final projectsColl = db.collection('projects');
  final transactionsColl = db.collection('transactions');
  final usersColl = db.collection('users');
  final notesColl = db.collection('project_notes');

  await _seedIfEmpty(
    projectsColl: projectsColl,
    transactionsColl: transactionsColl,
    usersColl: usersColl,
    notesColl: notesColl,
  );

  final app = Router();

  // ---- Project routes ----

  app.get('/api/projects', (Request req) async {
    final projects = await projectsColl.find().toList();
    final result = <Map<String, dynamic>>[];

    for (final p in projects) {
      final projectId = p['_id'] as String;
      final txs =
          await transactionsColl.find({'projectId': projectId}).toList();

      double income = 0;
      double expense = 0;
      for (final t in txs) {
        final amount = (t['amount'] as num).toDouble();
        final isIncome = t['isIncome'] as bool;
        if (isIncome) {
          income += amount;
        } else {
          expense += amount;
        }
      }

      result.add({
        'id': projectId,
        'name': p['name'],
        'description': p['description'] ?? '',
        'totalIncome': income,
        'totalExpense': expense,
      });
    }

    return Response.ok(
      jsonEncode(result),
      headers: {'content-type': 'application/json'},
    );
  });

  app.post('/api/projects', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final id = 'p_${DateTime.now().microsecondsSinceEpoch}';

    final doc = {
      '_id': id,
      'name': data['name'],
      'description': data['description'] ?? '',
    };

    await projectsColl.insert(doc);

    return Response.ok(
      jsonEncode({
        'id': id,
        'name': doc['name'],
        'description': doc['description'],
        'totalIncome': 0,
        'totalExpense': 0,
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  app.put('/api/projects/<id>', (Request req, String id) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    await projectsColl.update(
      whereId(id),
      {
        r'$set': {
          'name': data['name'],
          'description': data['description'] ?? '',
        }
      },
    );

    return Response.ok(jsonEncode({'success': true}),
        headers: {'content-type': 'application/json'});
  });

  // Transactions for a project
  app.get('/api/projects/<id>/transactions', (Request req, String id) async {
    final txs = await transactionsColl
        .find(mongo.where.eq('projectId', id).sortBy('date'))
        .toList();

    final result = txs
        .map((t) => {
              'id': t['_id'],
              'amount': (t['amount'] as num).toDouble(),
              'isIncome': t['isIncome'],
              'note': t['note'] ?? '',
              'date': (t['date'] as DateTime).toIso8601String(),
              'imageBase64': t['imageBase64'],
              'imageContentType': t['imageContentType'],
            })
        .toList();

    return Response.ok(
      jsonEncode(result),
      headers: {'content-type': 'application/json'},
    );
  });

  app.post('/api/projects/<id>/transactions', (Request req, String id) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final txId = 't_${DateTime.now().microsecondsSinceEpoch}';

    final txDoc = {
      '_id': txId,
      'projectId': id,
      'amount': (data['amount'] as num).toDouble(),
      'isIncome': data['isIncome'] as bool,
      'note': data['note'] ?? '',
      'date': DateTime.now(),
      if (data['imageBase64'] != null) 'imageBase64': data['imageBase64'],
      if (data['imageContentType'] != null)
        'imageContentType': data['imageContentType'],
    };

    await transactionsColl.insert(txDoc);

    return Response.ok(
      jsonEncode({
        'id': txId,
        'amount': txDoc['amount'],
        'isIncome': txDoc['isIncome'],
        'note': txDoc['note'],
        'date': (txDoc['date'] as DateTime).toIso8601String(),
        'imageBase64': txDoc['imageBase64'],
        'imageContentType': txDoc['imageContentType'],
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  app.put('/api/projects/<projectId>/transactions/<txId>',
      (Request req, String projectId, String txId) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final updateData = <String, dynamic>{
      'amount': (data['amount'] as num).toDouble(),
      'isIncome': data['isIncome'] as bool,
      'note': data['note'] ?? '',
    };

    if (data.containsKey('imageBase64')) {
      updateData['imageBase64'] = data['imageBase64'];
    }
    if (data.containsKey('imageContentType')) {
      updateData['imageContentType'] = data['imageContentType'];
    }

    await transactionsColl.update(
      whereId(txId),
      {
        r'$set': updateData,
      },
    );

    final updated =
        await transactionsColl.findOne(whereId(txId)) as Map<String, dynamic>;

    return Response.ok(
      jsonEncode({
        'id': updated['_id'],
        'amount': (updated['amount'] as num).toDouble(),
        'isIncome': updated['isIncome'],
        'note': updated['note'] ?? '',
        'date': (updated['date'] as DateTime).toIso8601String(),
        'imageBase64': updated['imageBase64'],
        'imageContentType': updated['imageContentType'],
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // ---- Project diary / notes ----

  app.get('/api/projects/<id>/notes', (Request req, String id) async {
    final notes =
        await notesColl.find(mongo.where.eq('projectId', id).sortBy('date')).toList();

    final result = notes
        .map(
          (n) => {
            'id': n['_id'],
            'content': n['content'] ?? '',
            'date': (n['date'] as DateTime).toIso8601String(),
            'imageBase64': n['imageBase64'],
            'imageContentType': n['imageContentType'],
          },
        )
        .toList();

    return Response.ok(
      jsonEncode(result),
      headers: {'content-type': 'application/json'},
    );
  });

  app.post('/api/projects/<id>/notes', (Request req, String id) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final noteId = 'n_${DateTime.now().microsecondsSinceEpoch}';

    final noteDoc = {
      '_id': noteId,
      'projectId': id,
      'content': data['content'] ?? '',
      'date': DateTime.now(),
      if (data['imageBase64'] != null) 'imageBase64': data['imageBase64'],
      if (data['imageContentType'] != null)
        'imageContentType': data['imageContentType'],
    };

    await notesColl.insert(noteDoc);

    return Response.ok(
      jsonEncode({
        'id': noteId,
        'content': noteDoc['content'],
        'date': (noteDoc['date'] as DateTime).toIso8601String(),
        'imageBase64': noteDoc['imageBase64'],
        'imageContentType': noteDoc['imageContentType'],
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  // ---- User admin routes ----

  app.get('/api/users', (Request req) async {
    final users = await usersColl.find().toList();
    final result = users
        .map((u) => {
              'id': u['_id'],
              'name': u['name'],
              'email': u['email'],
              'role': u['role'],
              'isActive': u['isActive'] ?? true,
            })
        .toList();

    return Response.ok(
      jsonEncode(result),
      headers: {'content-type': 'application/json'},
    );
  });

  app.post('/api/users', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final id = 'u_${DateTime.now().microsecondsSinceEpoch}';

    final userDoc = {
      '_id': id,
      'name': data['name'],
      'email': data['email'],
      'role': data['role'] ?? 'user',
      'isActive': data['isActive'] ?? true,
    };

    await usersColl.insert(userDoc);

    return Response.ok(
      jsonEncode({
        'id': id,
        'name': userDoc['name'],
        'email': userDoc['email'],
        'role': userDoc['role'],
        'isActive': userDoc['isActive'],
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  app.put('/api/users/<id>', (Request req, String id) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    await usersColl.update(
      whereId(id),
      {
        r'$set': {
          'name': data['name'],
          'email': data['email'],
          'role': data['role'],
          'isActive': data['isActive'],
        }
      },
    );

    return Response.ok(jsonEncode({'success': true}),
        headers: {'content-type': 'application/json'});
  });

  app.delete('/api/users/<id>', (Request req, String id) async {
    await usersColl.remove(whereId(id));
    return Response.ok(jsonEncode({'success': true}),
        headers: {'content-type': 'application/json'});
  });

  // Wrap with CORS + log
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(
        corsHeaders(
          headers: {
            ACCESS_CONTROL_ALLOW_ORIGIN: '*',
            ACCESS_CONTROL_ALLOW_HEADERS: '*',
            ACCESS_CONTROL_ALLOW_METHODS: 'GET,POST,PUT,DELETE,OPTIONS',
          },
        ),
      )
      .addHandler(app);

  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  stdout.writeln('✅ Server listening on port ${server.port}');
}

mongo.SelectorBuilder whereId(String id) =>
    mongo.where.eq('_id', id) as mongo.SelectorBuilder;

Future<void> _seedIfEmpty({
  required mongo.DbCollection projectsColl,
  required mongo.DbCollection transactionsColl,
  required mongo.DbCollection usersColl,
  required mongo.DbCollection notesColl,
}) async {
  if (await projectsColl.count() == 0) {
    final projectId = 'p_seed_1';
    await projectsColl.insert({
      '_id': projectId,
      'name': 'Dự án mẫu',
      'description': 'Dự án demo có sẵn dữ liệu thu chi',
    });

    await transactionsColl.insertMany([
      {
        '_id': 't_seed_1',
        'projectId': projectId,
        'amount': 10000000,
        'isIncome': true,
        'note': 'Thanh toán hợp đồng',
        'date': DateTime.now().subtract(const Duration(days: 5)),
      },
      {
        '_id': 't_seed_2',
        'projectId': projectId,
        'amount': 3500000,
        'isIncome': false,
        'note': 'Chi phí nhân công',
        'date': DateTime.now().subtract(const Duration(days: 2)),
      },
    ]);
  }

  if (await usersColl.count() == 0) {
    await usersColl.insertMany([
      {
        '_id': 'u_admin',
        'name': 'Quản trị viên',
        'email': 'admin@example.com',
        'role': 'admin',
        'isActive': true,
      },
      {
        '_id': 'u_user1',
        'name': 'Người dùng 1',
        'email': 'user1@example.com',
        'role': 'user',
        'isActive': true,
      },
    ]);
  }
}

