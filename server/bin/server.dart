import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:mongo_dart/mongo_dart.dart' as mongo;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

/// QR thanh toán dùng chung: lấy từ bất kỳ user nào đã có `paymentQrBase64`.
Future<String?> _firstPaymentQrFromUsers(mongo.DbCollection usersColl) async {
  final users = await usersColl.find().toList();
  for (final u in users) {
    final raw = u['paymentQrBase64'];
    if (raw == null) continue;
    final qr = raw.toString().trim();
    if (qr.isNotEmpty) return qr;
  }
  return null;
}

Future<void> main(List<String> args) async {
  final envMongoUri = Platform.environment['MONGO_URI'];
  final mongoUri = (envMongoUri == null || envMongoUri.trim().isEmpty)
      ? 'mongodb://localhost:27017/duan1'
      : envMongoUri.trim();

  if (envMongoUri == null || envMongoUri.trim().isEmpty) {
    stdout.writeln(
      '⚠️ MONGO_URI chưa được set. Đang dùng mặc định: $mongoUri',
    );
  }

  final db = await mongo.Db.create(mongoUri);
  await db.open();
  stdout.writeln('✅ Connected to MongoDB at $mongoUri');

  final projectsColl = db.collection('projects');
  final transactionsColl = db.collection('transactions');
  final usersColl = db.collection('users');
  final notesColl = db.collection('project_notes');

  await _migrateUsers(usersColl);

  await _seedIfEmpty(
    projectsColl: projectsColl,
    transactionsColl: transactionsColl,
    usersColl: usersColl,
    notesColl: notesColl,
  );

  final app = Router();

  // ---- Auth routes ----

  app.post('/api/auth/register', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final phone = (data['phone'] ?? '').toString().trim();
    final password = (data['password'] ?? '').toString();
    final name = (data['name'] ?? '').toString().trim();

    if (phone.isEmpty || password.isEmpty) {
      return Response(
        400,
        body: jsonEncode({'error': 'phone_and_password_required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final existing = await usersColl.findOne({'phone': phone});
    if (existing != null) {
      return Response(
        409,
        body: jsonEncode({'error': 'phone_exists'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final id = 'u_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(const Duration(days: 30));

    final userDoc = {
      '_id': id,
      'phone': phone,
      'passwordHash': _hashPassword(phone, password),
      'name': name.isEmpty ? 'Người dùng mới' : name,
      'email': '',
      'role': 'user',
      'isActive': true,
      'createdAt': now,
      'expiresAt': expiresAt,
    };

    await usersColl.insert(userDoc);

    // User mới: gán QR chung nếu hệ thống đã có (tránh user đăng ký sau không có mã).
    final sharedQr = await _firstPaymentQrFromUsers(usersColl);
    if (sharedQr != null) {
      await usersColl.update(
        whereId(id),
        {r'$set': {'paymentQrBase64': sharedQr}},
      );
      userDoc['paymentQrBase64'] = sharedQr;
    }

    final json = _userToJson(userDoc);
    return Response.ok(
      jsonEncode(json),
      headers: {'content-type': 'application/json'},
    );
  });

  app.post('/api/auth/login', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final phone = (data['phone'] ?? '').toString().trim();
    final password = (data['password'] ?? '').toString();

    if (phone.isEmpty || password.isEmpty) {
      return Response(
        400,
        body: jsonEncode({'error': 'phone_and_password_required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final user = await usersColl.findOne({'phone': phone});
    if (user == null) {
      return Response(
        404,
        body: jsonEncode({'error': 'user_not_found'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final expectedHash = user['passwordHash']?.toString() ?? '';
    if (expectedHash.isEmpty ||
        expectedHash != _hashPassword(phone, password)) {
      return Response(
        401,
        body: jsonEncode({'error': 'invalid_credentials'}),
        headers: {'content-type': 'application/json'},
      );
    }

    if (user['isActive'] == false) {
      return Response(
        403,
        body: jsonEncode({'error': 'user_blocked'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final expiresAt = user['expiresAt'] as DateTime?;
    if (expiresAt != null && expiresAt.isBefore(DateTime.now().toUtc())) {
      return Response(
        403,
        body: jsonEncode({'error': 'subscription_expired'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final qrExisting = user['paymentQrBase64']?.toString().trim() ?? '';
    if (qrExisting.isEmpty) {
      final sharedQr = await _firstPaymentQrFromUsers(usersColl);
      if (sharedQr != null) {
        await usersColl.update(
          whereId(user['_id']),
          {r'$set': {'paymentQrBase64': sharedQr}},
        );
      }
    }

    final fresh = await usersColl.findOne({'phone': phone});
    final json = _userToJson(fresh ?? user);
    return Response.ok(
      jsonEncode(json),
      headers: {'content-type': 'application/json'},
    );
  });

  app.post('/api/auth/change_password', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final phone = (data['phone'] ?? '').toString().trim();
    final oldPassword = (data['oldPassword'] ?? '').toString();
    final newPassword = (data['newPassword'] ?? '').toString();

    if (phone.isEmpty || oldPassword.isEmpty || newPassword.isEmpty) {
      return Response(
        400,
        body: jsonEncode({'error': 'missing_fields'}),
        headers: {'content-type': 'application/json'},
      );
    }
    if (newPassword.length < 4) {
      return Response(
        400,
        body: jsonEncode({'error': 'weak_password'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final user = await usersColl.findOne({'phone': phone});
    if (user == null) {
      return Response(
        404,
        body: jsonEncode({'error': 'user_not_found'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final expectedHash = user['passwordHash']?.toString() ?? '';
    if (expectedHash.isEmpty ||
        expectedHash != _hashPassword(phone, oldPassword)) {
      return Response(
        401,
        body: jsonEncode({'error': 'invalid_credentials'}),
        headers: {'content-type': 'application/json'},
      );
    }

    await usersColl.update(
      whereId(user['_id'].toString()),
      {
        r'$set': {'passwordHash': _hashPassword(phone, newPassword)}
      },
    );

    return Response.ok(
      jsonEncode({'success': true}),
      headers: {'content-type': 'application/json'},
    );
  });

  // Admin set a user's new password directly (no old password needed).
  app.post('/api/users/<id>/change-password', (Request req, String id) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final newPassword = (data['newPassword'] ?? '').toString();

    if (id.isEmpty || newPassword.isEmpty) {
      return Response(
        400,
        body: jsonEncode({'error': 'missing_fields'}),
        headers: {'content-type': 'application/json'},
      );
    }
    if (newPassword.length < 4) {
      return Response(
        400,
        body: jsonEncode({'error': 'weak_password'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final user = await usersColl.findOne(whereId(id));
    if (user == null) {
      return Response(
        404,
        body: jsonEncode({'error': 'user_not_found'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final phone = user['phone']?.toString().trim() ?? '';
    if (phone.isEmpty) {
      return Response(
        400,
        body: jsonEncode({'error': 'missing_phone'}),
        headers: {'content-type': 'application/json'},
      );
    }

    await usersColl.update(
      whereId(id),
      {
        r'$set': {'passwordHash': _hashPassword(phone, newPassword)}
      },
    );

    return Response.ok(
      jsonEncode({'success': true}),
      headers: {'content-type': 'application/json'},
    );
  });

  /// Mã QR thanh toán dùng chung — không cần đăng nhập (vd: user hết hạn vẫn xem được).
  app.get('/api/payment-qr', (Request req) async {
    final qr = await _firstPaymentQrFromUsers(usersColl);
    return Response.ok(
      jsonEncode({'paymentQrBase64': qr}),
      headers: {'content-type': 'application/json'},
    );
  });

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
        final amount = _toDouble(t['amount']);
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
        'ownerPhone': p['ownerPhone'] ?? '',
        'totalIncome': income,
        'totalExpense': expense,
        if (p['createdAt'] != null)
          'createdAt':
              (p['createdAt'] as DateTime).toUtc().toIso8601String(),
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
    final createdAt = DateTime.now().toUtc();

    final doc = {
      '_id': id,
      'name': data['name'],
      'description': data['description'] ?? '',
      'createdAt': createdAt,
      if (data['ownerPhone'] != null)
        'ownerPhone': (data['ownerPhone'] as String).trim(),
    };

    await projectsColl.insert(doc);

    return Response.ok(
      jsonEncode({
        'id': id,
        'name': doc['name'],
        'description': doc['description'],
        'ownerPhone': doc['ownerPhone'] ?? '',
        'totalIncome': 0,
        'totalExpense': 0,
        'createdAt': createdAt.toIso8601String(),
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

  app.delete('/api/projects/<id>', (Request req, String id) async {
    // cascade delete
    await transactionsColl.remove({'projectId': id});
    await notesColl.remove({'projectId': id});
    await projectsColl.remove(whereId(id));

    return Response.ok(
      jsonEncode({'success': true}),
      headers: {'content-type': 'application/json'},
    );
  });

  // Transactions for a project
  app.get('/api/projects/<id>/transactions', (Request req, String id) async {
    final txs = await transactionsColl
        .find(mongo.where.eq('projectId', id).sortBy('date'))
        .toList();

    final result = txs
        .map((t) => {
              'id': t['_id'],
              'amount': _toDouble(t['amount']),
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
      'amount': _toDouble(data['amount']),
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
      'amount': _toDouble(data['amount']),
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
        'amount': _toDouble(updated['amount']),
        'isIncome': updated['isIncome'],
        'note': updated['note'] ?? '',
        'date': (updated['date'] as DateTime).toIso8601String(),
        'imageBase64': updated['imageBase64'],
        'imageContentType': updated['imageContentType'],
      }),
      headers: {'content-type': 'application/json'},
    );
  });

  app.delete('/api/projects/<projectId>/transactions/<txId>',
      (Request req, String projectId, String txId) async {
    await transactionsColl.remove(
      mongo.where.eq('_id', txId).eq('projectId', projectId),
    );
    return Response.ok(
      jsonEncode({'success': true}),
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

  /// Sao lưu JSON: dự án + giao dịch + nhật ký của user (xác thực mật khẩu).
  /// Admin: toàn bộ dự án hệ thống. User thường: chỉ dự án có ownerPhone trùng SĐT.
  /// Cho phép kể cả khi gói hết hạn (chỉ chặn tài khoản bị khóa).
  app.post('/api/backup/export', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final phone = (data['phone'] ?? '').toString().trim();
    final password = (data['password'] ?? '').toString();

    if (phone.isEmpty || password.isEmpty) {
      return Response(
        400,
        body: jsonEncode({'error': 'phone_and_password_required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final user = await usersColl.findOne({'phone': phone});
    if (user == null) {
      return Response(
        404,
        body: jsonEncode({'error': 'user_not_found'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final expectedHash = user['passwordHash']?.toString() ?? '';
    if (expectedHash.isEmpty ||
        expectedHash != _hashPassword(phone, password)) {
      return Response(
        401,
        body: jsonEncode({'error': 'invalid_credentials'}),
        headers: {'content-type': 'application/json'},
      );
    }

    if (user['isActive'] == false) {
      return Response(
        403,
        body: jsonEncode({'error': 'user_blocked'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final isAdmin = (user['role'] ?? 'user').toString() == 'admin';
    final List<Map<String, dynamic>> projectDocs;
    if (isAdmin) {
      projectDocs = await projectsColl.find().toList();
    } else {
      projectDocs = await projectsColl.find({'ownerPhone': phone}).toList();
    }

    final exportedProjects = <Map<String, dynamic>>[];
    for (final p in projectDocs) {
      final projectId = p['_id'] as String;
      final txs =
          await transactionsColl.find({'projectId': projectId}).toList();
      final notes =
          await notesColl.find({'projectId': projectId}).toList();

      exportedProjects.add({
        'id': projectId,
        'name': p['name'],
        'description': p['description'] ?? '',
        'ownerPhone': p['ownerPhone'] ?? '',
        if (p['createdAt'] != null)
          'createdAt':
              (p['createdAt'] as DateTime).toUtc().toIso8601String(),
        'transactions': txs.map((t) {
          return {
            'id': t['_id'],
            'amount': _toDouble(t['amount']),
            'isIncome': t['isIncome'],
            'note': t['note'] ?? '',
            'date': (t['date'] as DateTime).toIso8601String(),
            'imageBase64': t['imageBase64'],
            'imageContentType': t['imageContentType'],
          };
        }).toList(),
        'notes': notes.map((n) {
          return {
            'id': n['_id'],
            'content': n['content'] ?? '',
            'date': (n['date'] as DateTime).toIso8601String(),
            'imageBase64': n['imageBase64'],
            'imageContentType': n['imageContentType'],
          };
        }).toList(),
      });
    }

    final payload = {
      'format': 'qlduancanhan_backup_v1',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'user': {
        'phone': phone,
        'name': user['name'] ?? '',
        'role': user['role'] ?? 'user',
      },
      'projects': exportedProjects,
    };

    return Response.ok(
      jsonEncode(payload),
      headers: {'content-type': 'application/json'},
    );
  });

  // ---- User admin routes ----

  app.get('/api/users', (Request req) async {
    final users = await usersColl.find().toList();
    final result = users.map(_userToJson).toList();

    return Response.ok(
      jsonEncode(result),
      headers: {'content-type': 'application/json'},
    );
  });

  app.post('/api/users', (Request req) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final id = 'u_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(const Duration(days: 30));

    final userDoc = {
      '_id': id,
      'phone': data['phone'] ?? '',
      'passwordHash': data['passwordHash'] ?? '',
      'name': data['name'] ?? '',
      'email': data['email'] ?? '',
      'role': data['role'] ?? 'user',
      'isActive': data['isActive'] ?? true,
      'createdAt': now,
      'expiresAt': expiresAt,
    };

    await usersColl.insert(userDoc);

    final sharedQr = await _firstPaymentQrFromUsers(usersColl);
    if (sharedQr != null) {
      await usersColl.update(
        whereId(id),
        {r'$set': {'paymentQrBase64': sharedQr}},
      );
      userDoc['paymentQrBase64'] = sharedQr;
    }

    return Response.ok(
      jsonEncode(_userToJson(userDoc)),
      headers: {'content-type': 'application/json'},
    );
  });

  app.put('/api/users/<id>', (Request req, String id) async {
    final body = await req.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    // If admin updates payment QR, propagate the same QR to all users.
    // Safety: only propagate when the request body contains only
    // `paymentQrBase64` (so other user updates won't accidentally clear QR).
    if (data.containsKey('paymentQrBase64') && data.keys.length == 1) {
      final qrRaw = data['paymentQrBase64'];
      final String? paymentQrBase64 =
          qrRaw == null ? null : qrRaw.toString();

      final allUsers = await usersColl.find().toList();
      for (final u in allUsers) {
        final userId = u['_id']?.toString();
        if (userId == null || userId.isEmpty) continue;
        await usersColl.update(
          whereId(userId),
          {r'$set': {'paymentQrBase64': paymentQrBase64}},
        );
      }
    }

    final update = <String, dynamic>{};
    if (data.containsKey('name')) update['name'] = data['name'];
    if (data.containsKey('email')) update['email'] = data['email'];
    if (data.containsKey('role')) update['role'] = data['role'];
    if (data.containsKey('isActive')) update['isActive'] = data['isActive'];
    if (data.containsKey('expiresInDays')) {
      final days = (data['expiresInDays'] as num).toInt();
      final now = DateTime.now().toUtc();
      update['expiresAt'] = now.add(Duration(days: days));
    }
    if (data.containsKey('addDays')) {
      final addDays = (data['addDays'] as num).toInt();
      if (addDays != 0) {
        final user = await usersColl.findOne(whereId(id));
        final now = DateTime.now().toUtc();
        late DateTime base;
        if (user != null && user['expiresAt'] != null) {
          final current = user['expiresAt'] as DateTime;
          if (addDays > 0) {
            // Gia hạn: cộng từ ngày hết hạn hiện tại (nếu còn hạn) hoặc từ hôm nay
            base = current.isAfter(now) ? current : now;
          } else {
            // Trừ ngày: luôn lùi từ ngày hết hạn đã lưu (dù còn hạn hay đã hết)
            base = current;
          }
        } else {
          base = now;
        }
        update['expiresAt'] = base.add(Duration(days: addDays));
      }
    }

    if (update.isNotEmpty) {
      await usersColl.update(
        whereId(id),
        {
          r'$set': update,
        },
      );
    }

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
    mongo.where.eq('_id', id);

double _toDouble(dynamic value) {
  if (value == null) return 0.0;
  if (value is num) return value.toDouble();

  // mongo_dart may decode BSON int64 as some Int64 type (not a Dart `num`).
  // Instead of referencing a concrete type, try `toInt()` dynamically.
  try {
    final i = (value as dynamic).toInt();
    return i.toDouble();
  } catch (_) {
    return double.tryParse(value.toString()) ?? 0.0;
  }
}

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
      'createdAt': DateTime.now().toUtc(),
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
    final now = DateTime.now().toUtc();
    await usersColl.insertMany([
      {
        '_id': 'u_admin',
        'phone': 'admin',
        'passwordHash': _hashPassword('admin', 'admin123'),
        'name': 'Quản trị viên',
        'email': 'admin@example.com',
        'role': 'admin',
        'isActive': true,
        'createdAt': now,
        'expiresAt': now.add(const Duration(days: 3650)),
      },
      {
        '_id': 'u_user1',
        'phone': '0900000000',
        'passwordHash': _hashPassword('0900000000', '123456'),
        'name': 'Người dùng 1',
        'email': 'user1@example.com',
        'role': 'user',
        'isActive': true,
        'createdAt': now,
        'expiresAt': now.add(const Duration(days: 30)),
      },
    ]);
  }
}

Future<void> _migrateUsers(mongo.DbCollection usersColl) async {
  // Nếu bạn đã seed user theo schema cũ (không có phone/passwordHash/expiresAt),
  // ta sẽ cập nhật để tương thích đăng nhập mới.
  final now = DateTime.now().toUtc();

  // 1) Đảm bảo admin cũ có đủ field
  final admin = await usersColl.findOne(whereId('u_admin'));
  if (admin != null) {
    final update = <String, dynamic>{};
    update.putIfAbsent('phone', () => admin['phone'] ?? 'admin');
    update.putIfAbsent('passwordHash', () {
      // default admin password: admin123
      return _hashPassword('admin', 'admin123');
    });
    update.putIfAbsent('createdAt', () => admin['createdAt'] ?? now);
    update.putIfAbsent(
      'expiresAt',
      () => admin['expiresAt'] ?? now.add(const Duration(days: 3650)),
    );
    update.putIfAbsent('isActive', () => admin['isActive'] ?? true);
    update.putIfAbsent('role', () => admin['role'] ?? 'admin');
    update.putIfAbsent('name', () => admin['name'] ?? 'Quản trị viên');
    update.putIfAbsent('email', () => admin['email'] ?? 'admin@example.com');

    await usersColl.update(
      whereId('u_admin'),
      {
        r'$set': update,
      },
    );
  }

  // 2) Với các user cũ không có phone/passwordHash/expiresAt:
  // - gán phone = email nếu email giống số điện thoại, ngược lại dùng _id
  // - passwordHash để trống -> sẽ không đăng nhập được cho tới khi set lại
  final cursor = usersColl.find({
    r'$or': [
      {'phone': {r'$exists': false}},
      {'expiresAt': {r'$exists': false}},
      {'createdAt': {r'$exists': false}},
    ]
  });

  await for (final u in cursor) {
    final id = u['_id']?.toString() ?? '';
    if (id.isEmpty) continue;

    final email = (u['email'] ?? '').toString().trim();
    final existingPhone = (u['phone'] ?? '').toString().trim();

    String phone = existingPhone;
    if (phone.isEmpty) {
      // Nếu email là số điện thoại (chỉ digits), dùng email làm phone
      final digitsOnly = RegExp(r'^\d{8,15}$');
      if (digitsOnly.hasMatch(email)) {
        phone = email;
      } else {
        phone = id; // fallback
      }
    }

    final update = <String, dynamic>{
      if (u['phone'] == null) 'phone': phone,
      if (u['createdAt'] == null) 'createdAt': now,
      if (u['expiresAt'] == null) 'expiresAt': now.add(const Duration(days: 30)),
      if (u['isActive'] == null) 'isActive': true,
      if (u['role'] == null) 'role': 'user',
      if (u['passwordHash'] == null) 'passwordHash': '',
    };

    if (update.isNotEmpty) {
      await usersColl.update(whereId(id), {r'$set': update});
    }
  }
}

String _hashPassword(String phone, String password) {
  final input = '$phone::$password::qlduancanhan_salt';
  final bytes = utf8.encode(input);
  return crypto.sha256.convert(bytes).toString();
}

Map<String, dynamic> _userToJson(Map<String, dynamic> u) {
  final expiresAt = u['expiresAt'] as DateTime?;
  int remainingDays = 0;
  if (expiresAt != null) {
    final now = DateTime.now().toUtc();
    remainingDays = expiresAt.isBefore(now)
        ? 0
        : expiresAt.difference(now).inDays;
  }

  return {
    'id': u['_id'],
    'phone': u['phone'] ?? '',
    'name': u['name'] ?? '',
    'email': u['email'] ?? '',
    'role': u['role'] ?? 'user',
    'isActive': u['isActive'] ?? true,
    'expiresAt': expiresAt?.toIso8601String(),
    'remainingDays': remainingDays,
    'paymentQrBase64': u['paymentQrBase64'] as String?,
  };
}

