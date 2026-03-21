import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show rootBundle, TextInputFormatter, TextEditingValue, TextSelection;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'backup_download.dart' as backup_dl;

/// Gốc API. Trên web (Docker/CapRover): cùng origin → nginx proxy `/api` sang backend.
/// Mobile/desktop: `API_BASE_URL` khi build, mặc định localhost.
String get apiBaseUrl {
  if (kIsWeb) {
    return Uri.base.origin;
  }
  const fromEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');
  if (fromEnv.isNotEmpty) {
    return fromEnv.replaceAll(RegExp(r'/$'), '');
  }
  return 'http://localhost:8080';
}

/// Chuyển mã lỗi API (snake_case) sang thông báo tiếng Việt.
String apiErrorToVietnamese(Object? raw) {
  final code = raw?.toString().trim() ?? '';
  switch (code) {
    case 'phone_and_password_required':
      return 'Vui lòng nhập số điện thoại và mật khẩu';
    case 'phone_exists':
      return 'Số điện thoại đã được đăng ký';
    case 'user_not_found':
      return 'Không tìm thấy tài khoản';
    case 'invalid_credentials':
      return 'Sai số điện thoại hoặc mật khẩu';
    case 'user_blocked':
      return 'Tài khoản đã bị khóa. Vui lòng liên hệ quản trị viên. Zalo 0918998303';
    case 'subscription_expired':
      return 'Gói sử dụng đã hết hạn. Vui lòng quét mã QR gia hạn';
    case 'missing_fields':
      return 'Vui lòng điền đủ thông tin';
    case 'weak_password':
      return 'Mật khẩu mới quá yếu (tối thiểu 4 ký tự)';
    case 'missing_phone':
      return 'Tài khoản thiếu số điện thoại, không thể xử lý';
    default:
      if (code.isEmpty) {
        return 'Đăng nhập hoặc đăng ký không thành công';
      }
      if (!code.contains('_')) {
        return code;
      }
      return 'Đã có lỗi. Vui lòng thử lại sau';
  }
}

void main() {
  runApp(const ExpenseManagerApp());
}

class ExpenseManagerApp extends StatefulWidget {
  const ExpenseManagerApp({super.key});

  @override
  State<ExpenseManagerApp> createState() => _ExpenseManagerAppState();
}

class _ExpenseManagerAppState extends State<ExpenseManagerApp> {
  int _selectedIndex = 0;
  bool _loadingProjects = true;
  bool _loadingUsers = true;

  final List<Project> _projects = [];
  final List<AppUser> _users = [];
  AppUser? _currentUser;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    await Future.wait([_fetchProjects(), _fetchUsers()]);
  }

  Future<void> _fetchProjects() async {
    setState(() {
      _loadingProjects = true;
    });
    try {
      final res = await http.get(Uri.parse('$apiBaseUrl/api/projects'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List<dynamic>;
        final all = data.map((e) => Project.fromJson(e)).toList();
        final user = _currentUser;
        _projects
          ..clear()
          ..addAll(
            user == null || user.role == 'admin'
                ? all
                : all.where((p) => p.ownerPhone == user.phone),
          );
      }
    } catch (_) {
      // ignore, keep current list
    } finally {
      if (mounted) {
        setState(() {
          _loadingProjects = false;
        });
      }
    }
  }

  Future<void> _fetchUsers() async {
    setState(() {
      _loadingUsers = true;
    });
    try {
      final res = await http.get(Uri.parse('$apiBaseUrl/api/users'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List<dynamic>;
        _users
          ..clear()
          ..addAll(data.map((e) => AppUser.fromJson(e)));
      }
    } catch (_) {
      // ignore, keep current list
    } finally {
      if (mounted) {
        setState(() {
          _loadingUsers = false;
        });
      }
    }
  }

  Future<void> _refreshCurrentUser() async {
    if (_currentUser == null) return;
    await _fetchUsers();
    for (final u in _users) {
      if (u.id == _currentUser!.id) {
        setState(() {
          _currentUser = u;
        });
        return;
      }
    }
  }

  Future<void> _addProject(Project project) async {
    try {
      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/projects'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'name': project.name,
          'description': project.description,
          'ownerPhone': _currentUser?.phone,
        }),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _projects.add(Project.fromJson(data));
        });
      }
    } catch (_) {}
  }

  Future<void> _updateProject(Project updated) async {
    try {
      await http.put(
        Uri.parse('$apiBaseUrl/api/projects/${updated.id}'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'name': updated.name,
          'description': updated.description,
        }),
      );
      setState(() {
        final index = _projects.indexWhere((p) => p.id == updated.id);
        if (index != -1) {
          _projects[index] = updated;
        }
      });
    } catch (_) {}
  }

  Future<void> _deleteProject(String projectId) async {
    try {
      final res = await http.delete(
        Uri.parse('$apiBaseUrl/api/projects/$projectId'),
      );
      if (res.statusCode == 200) {
        await _fetchProjects();
      }
    } catch (_) {}
  }

  Future<void> _addTransaction(
    String projectId,
    ProjectTransaction tx,
  ) async {
    try {
      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/projects/$projectId/transactions'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'amount': tx.amount,
          'isIncome': tx.isIncome,
          'note': tx.note,
          'imageBase64': tx.imageBase64,
          'imageContentType': tx.imageContentType,
        }),
      );
      if (res.statusCode == 200) {
        // làm tươi lại danh sách dự án để cập nhật tổng thu/chi
        await _fetchProjects();
      }
    } catch (_) {}
  }

  Future<void> _updateTransaction(
    String projectId,
    ProjectTransaction tx,
  ) async {
    try {
      final res = await http.put(
        Uri.parse(
            '$apiBaseUrl/api/projects/$projectId/transactions/${tx.id}'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'amount': tx.amount,
          'isIncome': tx.isIncome,
          'note': tx.note,
          'imageBase64': tx.imageBase64,
          'imageContentType': tx.imageContentType,
        }),
      );
      if (res.statusCode == 200) {
        await _fetchProjects();
      }
    } catch (_) {}
  }

  Future<void> _addUser(AppUser user) async {
    try {
      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/users'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(user.toJson(forCreate: true)),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _users.add(AppUser.fromJson(data));
        });
      }
    } catch (_) {}
  }

  Future<void> _updateUser(AppUser user) async {
    try {
      await http.put(
        Uri.parse('$apiBaseUrl/api/users/${user.id}'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(user.toJson()),
      );
      setState(() {
        final index = _users.indexWhere((u) => u.id == user.id);
        if (index != -1) {
          _users[index] = user;
        }
      });
    } catch (_) {}
  }

  Future<void> _deleteUser(String userId) async {
    try {
      await http.delete(Uri.parse('$apiBaseUrl/api/users/$userId'));
      setState(() {
        _users.removeWhere((u) => u.id == userId);
      });
    } catch (_) {}
  }

  Future<void> _extendUser(String userId, int addDays) async {
    try {
      await http.put(
        Uri.parse('$apiBaseUrl/api/users/$userId'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'addDays': addDays}),
      );
      await _fetchUsers();
    } catch (_) {}
  }

  Future<void> _adminChangeUserPassword(
      String userId, String newPassword) async {
    try {
      await http.post(
        Uri.parse('$apiBaseUrl/api/users/$userId/change-password'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'newPassword': newPassword}),
      );
    } catch (_) {}
  }

  Future<void> _adminUpdateUserPaymentQr(
      String userId, String? paymentQrBase64) async {
    try {
      await http.put(
        Uri.parse('$apiBaseUrl/api/users/$userId'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'paymentQrBase64': paymentQrBase64}),
      );
      await _fetchUsers();
    } catch (_) {}
  }

  Future<void> _saveBackupJsonFile(
    BuildContext context,
    String filename,
    String jsonText,
  ) async {
    if (kIsWeb) {
      backup_dl.downloadJsonFileOnWeb(filename, jsonText);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Đã tải file sao lưu (JSON). Kiểm tra thư mục Tải xuống trên trình duyệt.',
            ),
          ),
        );
      }
      return;
    }
    try {
      final bytes = Uint8List.fromList(utf8.encode(jsonText));
      final xf = XFile.fromData(
        bytes,
        mimeType: 'application/json',
        name: filename,
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [xf],
          text: 'Sao lưu quản lý thu chi dự án',
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể chia sẻ file: $e')),
        );
      }
    }
  }

  Future<void> _showBackupDataDialog(BuildContext context) async {
    final user = _currentUser;
    if (user == null) return;

    final passwordController = TextEditingController();
    bool loading = false;
    String? dialogError;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Sao lưu dữ liệu'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.role == 'admin'
                          ? 'Xuất file JSON: toàn bộ dự án, giao dịch và nhật ký trên hệ thống.'
                          : 'Xuất file JSON: các dự án thuộc tài khoản của bạn, kèm giao dịch và nhật ký.',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Mật khẩu xác nhận',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        dialogError!,
                        style:
                            TextStyle(color: Colors.red[700], fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: loading ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Huỷ'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          final pw = passwordController.text;
                          if (pw.length < 4) {
                            setDialogState(() {
                              dialogError =
                                  'Vui lòng nhập đúng mật khẩu (tối thiểu 4 ký tự)';
                            });
                            return;
                          }
                          setDialogState(() {
                            loading = true;
                            dialogError = null;
                          });
                          try {
                            final res = await http.post(
                              Uri.parse('$apiBaseUrl/api/backup/export'),
                              headers: {'content-type': 'application/json'},
                              body: jsonEncode({
                                'phone': user.phone,
                                'password': pw,
                              }),
                            );
                            if (res.statusCode == 200) {
                              final pretty = const JsonEncoder.withIndent('  ')
                                  .convert(jsonDecode(res.body));
                              final safePhone = user.phone
                                  .replaceAll(RegExp(r'[^\w\-]+'), '_');
                              final fname =
                                  'backup_duan_${safePhone}_${DateTime.now().millisecondsSinceEpoch}.json';
                              if (ctx.mounted) {
                                Navigator.of(ctx).pop();
                              }
                              if (context.mounted) {
                                await _saveBackupJsonFile(
                                    context, fname, pretty);
                              }
                              return;
                            }
                            final data = jsonDecode(res.body)
                                as Map<String, dynamic>;
                            setDialogState(() {
                              loading = false;
                              dialogError =
                                  apiErrorToVietnamese(data['error']);
                            });
                          } catch (_) {
                            setDialogState(() {
                              loading = false;
                              dialogError = 'Không thể kết nối server';
                            });
                          }
                        },
                  child: loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Tạo file sao lưu'),
                ),
              ],
            );
          },
        );
      },
    );
    passwordController.dispose();
  }

  Future<void> _showChangePasswordDialog(BuildContext context) async {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool loading = false;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Đổi mật khẩu'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: oldController,
                      decoration: const InputDecoration(
                        labelText: 'Mật khẩu hiện tại',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      obscureText: true,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Vui lòng nhập mật khẩu hiện tại';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: newController,
                      decoration: const InputDecoration(
                        labelText: 'Mật khẩu mới',
                        prefixIcon: Icon(Icons.lock_reset_outlined),
                      ),
                      obscureText: true,
                      validator: (value) {
                        if (value == null || value.length < 4) {
                          return 'Mật khẩu mới tối thiểu 4 ký tự';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: confirmController,
                      decoration: const InputDecoration(
                        labelText: 'Nhập lại mật khẩu mới',
                        prefixIcon: Icon(Icons.check_circle_outline),
                      ),
                      obscureText: true,
                      validator: (value) {
                        if (value != newController.text) {
                          return 'Mật khẩu nhập lại không khớp';
                        }
                        return null;
                      },
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        error!,
                        style: TextStyle(color: Colors.red[700], fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: loading ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Hủy'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          final user = _currentUser;
                          if (user == null) return;

                          setState(() {
                            loading = true;
                            error = null;
                          });
                          try {
                            final res = await http.post(
                              Uri.parse(
                                  '$apiBaseUrl/api/auth/change_password'),
                              headers: {'content-type': 'application/json'},
                              body: jsonEncode({
                                'phone': user.phone,
                                'oldPassword': oldController.text,
                                'newPassword': newController.text,
                              }),
                            );
                            if (res.statusCode == 200) {
                              if (ctx.mounted) {
                                Navigator.of(ctx).pop();
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content:
                                        Text('Đổi mật khẩu thành công'),
                                  ),
                                );
                              }
                            } else {
                              final data = jsonDecode(res.body)
                                  as Map<String, dynamic>;
                              setState(() {
                                error = data['error'] != null
                                    ? apiErrorToVietnamese(data['error'])
                                    : 'Đổi mật khẩu thất bại';
                              });
                            }
                          } catch (_) {
                            setState(() {
                              error = 'Không thể kết nối server';
                            });
                          } finally {
                            setState(() {
                              loading = false;
                            });
                          }
                        },
                  child: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Lưu'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _logout() {
    setState(() {
      _currentUser = null;
      _selectedIndex = 0;
      _projects.clear();
      _users.clear();
    });
  }

  void _onTabChanged(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = const Color(0xFF0B1F3B); // navy chính
    final accentColor = const Color(0xFF1E88E5); // xanh dương điểm nhấn

    return MaterialApp(
      title: 'Quản lý thu chi dự án',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: baseColor,
          primary: baseColor,
          secondary: accentColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF3F5F9),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B1F3B),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: baseColor.withOpacity(0.1),
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? baseColor
                  : Colors.grey[600],
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontSize: 12,
              fontWeight:
                  states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
              color: states.contains(WidgetState.selected)
                  ? baseColor
                  : Colors.grey[700],
            ),
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: baseColor, width: 1.4),
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        textTheme: ThemeData.light().textTheme.apply(
              bodyColor: const Color(0xFF111827),
              displayColor: const Color(0xFF111827),
            ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: baseColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: baseColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: baseColor.withOpacity(0.06),
          selectedColor: baseColor,
          labelStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
      home: _currentUser == null
          ? LoginScreen(
              onAuthenticated: (user) {
                setState(() {
                  _currentUser = user;
                  _selectedIndex = 0;
                });
                _loadInitialData();
              },
            )
          : Builder(
              builder: (context) {
                final isAdmin = _currentUser?.role == 'admin';
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: isAdmin
                        ? Scaffold(
                            body: IndexedStack(
                              index: _selectedIndex,
                              children: [
                                ProjectListScreen(
                                  currentUser: _currentUser!,
                                  onChangePassword: _showChangePasswordDialog,
                                  onLogout: _logout,
                                  projects: _projects,
                                  loading: _loadingProjects,
                                  onRefresh: _fetchProjects,
                                  onAddProject: _addProject,
                                  onShowPaymentQr: (ctx) async {
                                    await _refreshCurrentUser();
                                    final user = _currentUser;
                                    if (user != null) {
                                      await _showUserPaymentQrDialog(ctx, user);
                                    }
                                  },
                                  onBackupData: _showBackupDataDialog,
                                  onOpenProject: (project) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (ctx) => Center(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxWidth: 480),
                                            child: ProjectDetailScreen(
                                              project: project,
                                              onUpdateProject: _updateProject,
                                              onAddTransaction:
                                                  _addTransaction,
                                              onUpdateTransaction:
                                                  _updateTransaction,
                                              onDeleteProject: _deleteProject,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                AdminUserScreen(
                                  users: _users,
                                  loading: _loadingUsers,
                                  onRefresh: _fetchUsers,
                                  onAddUser: _addUser,
                                  onUpdateUser: _updateUser,
                                  onDeleteUser: _deleteUser,
                                  onExtendUser: _extendUser,
                                  onChangeUserPassword:
                                      _adminChangeUserPassword,
                                  onUpdateGlobalPaymentQr: (String? qr) async {
                                    if (_users.isEmpty) return;
                                    // backend sẽ tự đồng bộ QR này cho tất cả users
                                    await _adminUpdateUserPaymentQr(
                                      _users.first.id,
                                      qr,
                                    );
                                  },
                                  onUpdateUserPaymentQr:
                                      _adminUpdateUserPaymentQr,
                                ),
                              ],
                            ),
                            bottomNavigationBar: NavigationBar(
                              selectedIndex: _selectedIndex,
                              onDestinationSelected: _onTabChanged,
                              destinations: const [
                                NavigationDestination(
                                  icon: Icon(Icons.work_outline),
                                  label: 'Dự án',
                                ),
                                NavigationDestination(
                                  icon: Icon(
                                      Icons.admin_panel_settings_outlined),
                                  label: 'Admin',
                                ),
                              ],
                            ),
                          )
                        : Scaffold(
                            body: ProjectListScreen(
                              currentUser: _currentUser!,
                              onChangePassword: _showChangePasswordDialog,
                              onLogout: _logout,
                              projects: _projects,
                              loading: _loadingProjects,
                              onRefresh: _fetchProjects,
                              onAddProject: _addProject,
                              onShowPaymentQr: (ctx) async {
                                await _refreshCurrentUser();
                                final user = _currentUser;
                                if (user != null) {
                                  await _showUserPaymentQrDialog(ctx, user);
                                }
                              },
                              onBackupData: _showBackupDataDialog,
                              onOpenProject: (project) {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (ctx) => Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                            maxWidth: 480),
                                        child: ProjectDetailScreen(
                                          project: project,
                                          onUpdateProject: _updateProject,
                                          onAddTransaction: _addTransaction,
                                          onUpdateTransaction:
                                              _updateTransaction,
                                          onDeleteProject: _deleteProject,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                );
              },
            ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onAuthenticated});

  final void Function(AppUser user) onAuthenticated;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoginMode = true;
  bool _loading = false;
  String? _error;
  /// true khi server trả lỗi `subscription_expired` (đăng nhập).
  bool _subscriptionExpired = false;
  bool _showRenewalQr = false;
  Uint8List? _renewalQrBytes;
  bool _renewalQrLoading = false;
  String? _renewalQrMessage;

  void _clearRenewalUi() {
    _subscriptionExpired = false;
    _showRenewalQr = false;
    _renewalQrBytes = null;
    _renewalQrLoading = false;
    _renewalQrMessage = null;
  }

  Future<void> _fetchPublicPaymentQr() async {
    setState(() {
      _renewalQrLoading = true;
      _renewalQrMessage = null;
    });
    try {
      final res = await http.get(Uri.parse('$apiBaseUrl/api/payment-qr'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final b64 = data['paymentQrBase64'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          if (mounted) {
            setState(() {
              _renewalQrBytes = base64Decode(b64);
              _renewalQrLoading = false;
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _renewalQrBytes = null;
              _renewalQrLoading = false;
              _renewalQrMessage =
                  'Chưa có mã QR thanh toán trên hệ thống. Vui lòng liên hệ quản trị viên.';
            });
          }
        }
      } else {
        if (mounted) {
          setState(() {
            _renewalQrLoading = false;
            _renewalQrMessage = 'Không tải được mã QR. Thử lại sau.';
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _renewalQrLoading = false;
          _renewalQrMessage = 'Không thể kết nối server để lấy mã QR.';
        });
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _clearRenewalUi();
    });
    try {
      final phone = _phoneController.text.trim();
      final password = _passwordController.text;
      final name = _nameController.text.trim();

      final uri = Uri.parse(
        _isLoginMode
            ? '$apiBaseUrl/api/auth/login'
            : '$apiBaseUrl/api/auth/register',
      );
      final res = await http.post(
        uri,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'phone': phone,
          'password': password,
          if (!_isLoginMode) 'name': name,
        }),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final user = AppUser.fromJson(data);
        widget.onAuthenticated(user);
      } else {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final code = (data['error'] ?? '').toString();
        setState(() {
          _error = apiErrorToVietnamese(data['error']);
          _subscriptionExpired =
              _isLoginMode && code == 'subscription_expired';
          if (!_subscriptionExpired) {
            _showRenewalQr = false;
            _renewalQrBytes = null;
            _renewalQrMessage = null;
          }
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Không thể kết nối server';
        _clearRenewalUi();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  // Logo: không dùng Container/BoxDecoration/màu nền — chỉ ảnh trên nền Scaffold.
                  Material(
                    type: MaterialType.transparency,
                    elevation: 0,
                    color: Colors.transparent,
                    shadowColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    child: Builder(
                      builder: (ctx) {
                        final dpr = MediaQuery.devicePixelRatioOf(ctx);
                        // Chiều cao logic lớn hơn + decode theo pixel thật → nét hơn trên màn HDPI.
                        const logicalLogoHeight = 168.0;
                        final cacheH =
                            (logicalLogoHeight * dpr).round().clamp(1, 8192);
                        return SizedBox(
                          width: double.infinity,
                          height: logicalLogoHeight,
                          child: Image.asset(
                            'assets/logo/logo.png',
                            fit: BoxFit.contain,
                            alignment: Alignment.center,
                            filterQuality: FilterQuality.high,
                            cacheHeight: cacheH,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Quản lý thu chi dự án',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isLoginMode
                        ? 'Đăng nhập bằng số điện thoại'
                        : 'Đăng ký tài khoản mới (dùng thử 30 ngày)',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey[700]),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _phoneController,
                    decoration: const InputDecoration(
                      labelText: 'Số điện thoại',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                    keyboardType: TextInputType.phone,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Vui lòng nhập số điện thoại';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Mật khẩu',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.length < 4) {
                        return 'Mật khẩu tối thiểu 4 ký tự';
                      }
                      return null;
                    },
                  ),
                  if (!_isLoginMode) ...[
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Tên hiển thị (tuỳ chọn)',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(color: Colors.red[700], fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    if (_subscriptionExpired) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _loading
                            ? null
                            : () async {
                                final show = !_showRenewalQr;
                                setState(() {
                                  _showRenewalQr = show;
                                  if (!show) {
                                    _renewalQrMessage = null;
                                  }
                                });
                                if (show &&
                                    _renewalQrBytes == null &&
                                    !_renewalQrLoading) {
                                  await _fetchPublicPaymentQr();
                                }
                              },
                        icon: const Icon(Icons.qr_code_2_outlined, size: 20),
                        label: Text(
                          _showRenewalQr
                              ? 'Ẩn mã QR thanh toán gia hạn'
                              : 'Thanh toán gia hạn — xem mã QR',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (_showRenewalQr) ...[
                        if (_renewalQrLoading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        if (_renewalQrMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              _renewalQrMessage!,
                              style: TextStyle(
                                color: Colors.orange[800],
                                fontSize: 12,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        if (_renewalQrBytes != null) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              _renewalQrBytes!,
                              width: 200,
                              height: 200,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Quét mã để thanh toán gia hạn. Vui lòng thanh toán 300.000đ cho 1 năm sử dụng. Nội dung chuyển khoản: số điện thoại đăng nhập',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.grey[700]),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ],
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isLoginMode ? 'Đăng nhập' : 'Đăng ký'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () {
                            setState(() {
                              _isLoginMode = !_isLoginMode;
                              _error = null;
                              _clearRenewalUi();
                            });
                          },
                    child: Text(_isLoginMode
                        ? 'Chưa có tài khoản? Đăng ký'
                        : 'Đã có tài khoản? Đăng nhập'),
                  ),
                ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class Project {
  Project({
    required this.id,
    required this.name,
    required this.description,
    this.ownerPhone = '',
    this.totalIncome = 0,
    this.totalExpense = 0,
    this.createdAt,
  });

  final String id;
  String name;
  String description;
  String ownerPhone;
  double totalIncome;
  double totalExpense;
  /// Ngày khởi tạo dự án (UTC từ server), có thể null với dữ liệu cũ.
  DateTime? createdAt;

  factory Project.fromJson(Map<String, dynamic> json) {
    DateTime? created;
    final rawCreated = json['createdAt'];
    if (rawCreated is String) {
      created = DateTime.tryParse(rawCreated);
    }
    return Project(
      id: json['id'] as String,
      name: json['name'] as String,
      description: (json['description'] ?? '') as String,
      ownerPhone: (json['ownerPhone'] ?? '') as String,
      totalIncome: (json['totalIncome'] as num?)?.toDouble() ?? 0,
      totalExpense: (json['totalExpense'] as num?)?.toDouble() ?? 0,
      createdAt: created,
    );
  }

  double get balance => totalIncome - totalExpense;
}

class ProjectTransaction {
  ProjectTransaction({
    required this.id,
    required this.amount,
    required this.isIncome,
    required this.note,
    required this.date,
    this.imageBase64,
    this.imageContentType,
  });

  final String id;
  final double amount;
  final bool isIncome;
  final String note;
  final DateTime date;
  final String? imageBase64;
  final String? imageContentType;

  factory ProjectTransaction.fromJson(Map<String, dynamic> json) {
    return ProjectTransaction(
      id: json['id'] as String,
      amount: (json['amount'] as num).toDouble(),
      isIncome: json['isIncome'] as bool,
      note: (json['note'] ?? '') as String,
      date: DateTime.parse(json['date'] as String),
      imageBase64: json['imageBase64'] as String?,
      imageContentType: json['imageContentType'] as String?,
    );
  }
}

class ProjectNote {
  ProjectNote({
    required this.id,
    required this.content,
    required this.date,
    this.imageBase64,
    this.imageContentType,
  });

  final String id;
  String content;
  final DateTime date;
  final String? imageBase64;
  final String? imageContentType;

  factory ProjectNote.fromJson(Map<String, dynamic> json) {
    return ProjectNote(
      id: json['id'] as String,
      content: (json['content'] ?? '') as String,
      date: DateTime.parse(json['date'] as String),
      imageBase64: json['imageBase64'] as String?,
      imageContentType: json['imageContentType'] as String?,
    );
  }
}

String formatCurrency(double value) {
  final n = value.round().abs();
  final str = n.toString();
  final sb = StringBuffer();
  for (var i = 0; i < str.length; i++) {
    if (i > 0 && (str.length - i) % 3 == 0) sb.write(',');
    sb.write(str[i]);
  }
  final sign = value < 0 ? '-' : '';
  return '$sign$sb đ';
}

/// Text số tiền tự co chữ để luôn hiển thị trên 1 dòng
class _AmountText extends StatelessWidget {
  const _AmountText(
    this.value, {
    super.key,
    this.style,
    this.prefixSign,
  });

  final double value;
  final TextStyle? style;
  final String? prefixSign;

  @override
  Widget build(BuildContext context) {
    final baseStyle =
        style ?? Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600);
    final sign = prefixSign ?? '';

    return FittedBox(
      alignment: Alignment.centerRight,
      fit: BoxFit.scaleDown,
      child: Text(
        '$sign${formatCurrency(value)}',
        style: baseStyle,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
      ),
    );
  }
}

String formatDate(DateTime date) {
  final d = date.day.toString().padLeft(2, '0');
  final m = date.month.toString().padLeft(2, '0');
  final y = date.year.toString();
  return '$d/$m/$y';
}

/// Chỉ giữ chữ số trong ô số tiền (bỏ dấu chấm phân tách).
String _amountFieldDigitsOnly(String input) =>
    input.replaceAll(RegExp(r'[^\d]'), '');

const int _maxUploadImageBytes = 10 * 1024 * 1024; // 10MB
const int _maxUploadImageDimension = 1920;

/// Giảm độ phân giải + nén ảnh trước khi upload.
/// Trả về null nếu sau tối ưu vẫn vượt quá 10MB.
Future<Uint8List?> _prepareImageForUpload(Uint8List originalBytes) async {
  if (originalBytes.isEmpty) return null;

  final decoded = img.decodeImage(originalBytes);
  if (decoded == null) {
    // Không decode được: chỉ chấp nhận nếu file gốc <= 10MB.
    return originalBytes.length <= _maxUploadImageBytes ? originalBytes : null;
  }

  img.Image processed = decoded;
  final longestSide = max(processed.width, processed.height);
  if (longestSide > _maxUploadImageDimension) {
    final scale = _maxUploadImageDimension / longestSide;
    processed = img.copyResize(
      processed,
      width: max(1, (processed.width * scale).round()),
      height: max(1, (processed.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }

  var jpeg = Uint8List.fromList(img.encodeJpg(processed, quality: 85));
  if (jpeg.length <= _maxUploadImageBytes) return jpeg;

  // Thử giảm quality trước.
  for (final q in const [75, 65, 55, 45, 35]) {
    jpeg = Uint8List.fromList(img.encodeJpg(processed, quality: q));
    if (jpeg.length <= _maxUploadImageBytes) return jpeg;
  }

  // Nếu vẫn lớn, giảm thêm kích thước ảnh rồi nén lại.
  for (var i = 0; i < 4; i++) {
    processed = img.copyResize(
      processed,
      width: max(1, (processed.width * 0.85).round()),
      height: max(1, (processed.height * 0.85).round()),
      interpolation: img.Interpolation.average,
    );
    jpeg = Uint8List.fromList(img.encodeJpg(processed, quality: 55));
    if (jpeg.length <= _maxUploadImageBytes) return jpeg;
  }

  return null;
}

/// Nhóm 3 chữ số bằng dấu chấm (vd: 300.000.000).
String formatAmountThousandsDots(String digitsOnly) {
  if (digitsOnly.isEmpty) return '';
  final sb = StringBuffer();
  for (var i = 0; i < digitsOnly.length; i++) {
    if (i > 0 && (digitsOnly.length - i) % 3 == 0) {
      sb.write('.');
    }
    sb.write(digitsOnly[i]);
  }
  return sb.toString();
}

/// Ô nhập số tiền nguyên — tự thêm dấu "." ngăn cách hàng nghìn.
class ThousandsDotAmountInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final digits = _amountFieldDigitsOnly(raw);
    if (digits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    final formatted = formatAmountThousandsDots(digits);

    final cursorPos = newValue.selection.baseOffset.clamp(0, raw.length);
    final beforeCursor = raw.substring(0, cursorPos);
    var digitsLeft = _amountFieldDigitsOnly(beforeCursor).length;
    if (digitsLeft > digits.length) {
      digitsLeft = digits.length;
    }

    if (digitsLeft == 0) {
      return TextEditingValue(
        text: formatted,
        selection: const TextSelection.collapsed(offset: 0),
      );
    }
    if (digitsLeft >= digits.length) {
      return TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    }

    var newOffset = 0;
    var counted = 0;
    for (var i = 0; i < formatted.length; i++) {
      if (formatted[i] != '.') {
        counted++;
      }
      newOffset = i + 1;
      if (counted >= digitsLeft) break;
    }
    newOffset = newOffset.clamp(0, formatted.length);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: newOffset),
    );
  }
}

Future<void> _showUserPaymentQrDialog(BuildContext context, AppUser user) async {
  var b64 = user.paymentQrBase64?.trim();
  if (b64 == null || b64.isEmpty) {
    try {
      final res = await http.get(Uri.parse('$apiBaseUrl/api/payment-qr'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final fetched = data['paymentQrBase64'] as String?;
        if (fetched != null && fetched.trim().isNotEmpty) {
          b64 = fetched.trim();
        }
      }
    } catch (_) {}
  }

  if (!context.mounted) return;

  if (b64 == null || b64.isEmpty) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Thanh toán'),
        content: const Text(
          'Hiện chưa có mã QR thanh toán. Vui lòng liên hệ admin để được cập nhật.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
    return;
  }

  final bytes = base64Decode(b64);

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Mã QR thanh toán'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.memory(
              bytes,
              height: 220,
              width: 220,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Số tiền: 300.000 đ cho 1 năm sử dụng',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
          Text(
            'Nội dung chuyển khoản: số điện thoại đăng nhập',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            '${user.name} (${user.phone.isNotEmpty ? user.phone : user.email})',
            style: Theme.of(ctx)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Đóng'),
        ),
      ],
    ),
  );
}

/// Header trong menu người dùng: avatar, tên, badge số ngày còn lại (không chọn được).
class _UserMenuHeaderEntry extends PopupMenuEntry<String> {
  const _UserMenuHeaderEntry({required this.user});

  final AppUser user;

  @override
  double get height => 124;

  @override
  bool represents(String? value) => false;

  @override
  State<_UserMenuHeaderEntry> createState() => _UserMenuHeaderEntryState();
}

class _UserMenuHeaderEntryState extends State<_UserMenuHeaderEntry> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final u = widget.user;
    final name = u.name.isNotEmpty ? u.name : u.phone;
    final sub = u.phone.isNotEmpty ? u.phone : u.email;
    final days = u.remainingDays;
    final expired = days <= 0;
    final low = !expired && days <= 7;
    final badgeColor = expired
        ? scheme.errorContainer
        : low
            ? const Color(0xFFFFF3E0)
            : scheme.primaryContainer;
    final badgeOn = expired
        ? scheme.onErrorContainer
        : low
            ? const Color(0xFFE65100)
            : scheme.onPrimaryContainer;
    final badgeText = expired
        ? 'Đã hết hạn — gia hạn để tiếp tục'
        : 'Còn $days ngày sử dụng';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: scheme.primary.withValues(alpha: 0.15),
                foregroundColor: scheme.primary,
                child: Text(
                  (name.isNotEmpty ? name[0] : '?').toUpperCase(),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (sub.isNotEmpty)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: expired
                    ? scheme.error.withValues(alpha: 0.35)
                    : scheme.outline.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  expired
                      ? Icons.event_busy_rounded
                      : Icons.event_available_rounded,
                  size: 18,
                  color: badgeOn,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    badgeText,
                    style: textTheme.labelLarge?.copyWith(
                      color: badgeOn,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileMenuRow extends StatelessWidget {
  const _ProfileMenuRow({
    required this.icon,
    required this.label,
    this.iconTint,
    this.textTint,
  });

  final IconData icon;
  final String label;
  final Color? iconTint;
  final Color? textTint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: (iconTint ?? scheme.primary).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            size: 20,
            color: iconTint ?? scheme.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: textTint ?? scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
      ],
    );
  }
}

/// Màn hình danh sách dự án
class ProjectListScreen extends StatelessWidget {
  const ProjectListScreen({
    super.key,
    required this.currentUser,
    required this.onChangePassword,
    required this.onLogout,
    required this.projects,
    required this.loading,
    required this.onRefresh,
    required this.onAddProject,
    required this.onOpenProject,
    required this.onShowPaymentQr,
    required this.onBackupData,
  });

  final AppUser currentUser;
  final Future<void> Function(BuildContext context) onChangePassword;
  final VoidCallback onLogout;
  final List<Project> projects;
  final bool loading;
  final Future<void> Function() onRefresh;
  final void Function(Project) onAddProject;
  final void Function(Project) onOpenProject;
  final Future<void> Function(BuildContext context) onShowPaymentQr;
  final Future<void> Function(BuildContext context) onBackupData;

  @override
  Widget build(BuildContext context) {
    final sortedProjects = List<Project>.from(projects)
      ..sort((a, b) {
        final aAt = a.createdAt;
        final bAt = b.createdAt;
        if (aAt == null && bAt == null) return 0;
        if (aAt == null) return 1;
        if (bAt == null) return -1;
        return bAt.compareTo(aAt);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quản lý dự án'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            tooltip: currentUser.name.isNotEmpty
                ? currentUser.name
                : currentUser.phone,
            position: PopupMenuPosition.under,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            color: Theme.of(context).colorScheme.surface,
            elevation: 10,
            shadowColor: Colors.black.withValues(alpha: 0.2),
            surfaceTintColor: Colors.transparent,
            menuPadding: const EdgeInsets.symmetric(vertical: 6),
            icon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    currentUser.name.isNotEmpty
                        ? currentUser.name
                        : currentUser.phone,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.white.withValues(alpha: 0.2),
                  foregroundColor: Colors.white,
                  child: Text(
                    (currentUser.name.isNotEmpty
                            ? currentUser.name[0]
                            : currentUser.phone.isNotEmpty
                                ? currentUser.phone[0]
                                : '?')
                        .toUpperCase(),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
            onSelected: (value) async {
              if (value == 'change_password') {
                await onChangePassword(context);
              } else if (value == 'payment_qr') {
                await onShowPaymentQr(context);
              } else if (value == 'backup') {
                await onBackupData(context);
              } else if (value == 'logout') {
                onLogout();
              }
            },
            itemBuilder: (ctx) => [
              _UserMenuHeaderEntry(user: currentUser),
              PopupMenuDivider(
                height: 1,
                thickness: 1,
                color: Theme.of(ctx).colorScheme.outlineVariant.withValues(
                      alpha: 0.5,
                    ),
              ),
              PopupMenuItem<String>(
                value: 'backup',
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: const _ProfileMenuRow(
                  icon: Icons.cloud_download_rounded,
                  label: 'Sao lưu dữ liệu',
                ),
              ),
              PopupMenuItem<String>(
                value: 'change_password',
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: const _ProfileMenuRow(
                  icon: Icons.lock_reset_rounded,
                  label: 'Đổi mật khẩu',
                ),
              ),
              PopupMenuItem<String>(
                value: 'payment_qr',
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: const _ProfileMenuRow(
                  icon: Icons.qr_code_2_rounded,
                  label: 'Thanh toán',
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<String>(
                value: 'logout',
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: _ProfileMenuRow(
                  icon: Icons.logout_rounded,
                  label: 'Đăng xuất',
                  iconTint: Theme.of(ctx).colorScheme.error,
                  textTint: Theme.of(ctx).colorScheme.error,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Container(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.2),
        child: RefreshIndicator(
          onRefresh: onRefresh,
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : sortedProjects.isEmpty
                  ? const _EmptyProjectsView()
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: sortedProjects.length,
                      itemBuilder: (ctx, index) {
                        final project = sortedProjects[index];
                        final income = project.totalIncome;
                        final expense = project.totalExpense;
                        final balance = project.balance;

                        return Card(
                          elevation: 1,
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => onOpenProject(project),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          project.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                  fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: balance >= 0
                                              ? Colors.teal.withOpacity(0.1)
                                              : Colors.red.withOpacity(0.08),
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            minWidth: 0,
                                            maxWidth: 140,
                                          ),
                                          child: _AmountText(
                                            balance,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: balance >= 0
                                                  ? Colors.teal
                                                  : Colors.red.shade700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    project.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: Colors.grey[700]),
                                  ),
                                  if (project.createdAt != null) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.calendar_today_outlined,
                                          size: 14,
                                          color: Colors.grey[600],
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'Khởi tạo: ${formatDate(project.createdAt!)}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Colors.grey[600],
                                                fontSize: 12,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: Row(
                                            children: [
                                              _AmountBadge(
                                                label: 'Chi',
                                                amount: expense,
                                                color: Colors.red,
                                              ),
                                              const SizedBox(width: 8),
                                              _AmountBadge(
                                                label: 'Thu',
                                                amount: income,
                                                color: Colors.green,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        color: Colors.grey[600],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'project_list_fab',
        onPressed: () => _showAddProjectDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Thêm dự án'),
      ),
    );
  }

  void _showAddProjectDialog(BuildContext context) {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Dự án mới'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Tên dự án',
                  prefixIcon: Icon(Icons.work_outline),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Vui lòng nhập tên dự án';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: descController,
                decoration: const InputDecoration(
                  labelText: 'Mô tả (tuỳ chọn)',
                  prefixIcon: Icon(Icons.notes_outlined),
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final id = 'p_${DateTime.now().microsecondsSinceEpoch}';
              final project = Project(
                id: id,
                name: nameController.text.trim(),
                description: descController.text.trim(),
              );
              onAddProject(project);
              Navigator.of(ctx).pop();
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }
}

class _AmountBadge extends StatelessWidget {
  const _AmountBadge({
    required this.label,
    required this.amount,
    required this.color,
  });

  final String label;
  final double amount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final bg = color.withOpacity(0.09);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: ShapeDecoration(
        color: bg,
        shape: StadiumBorder(
          side: BorderSide(color: color.withOpacity(0.25)),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            label == 'Thu' ? Icons.arrow_downward : Icons.arrow_upward,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              color: color.darken(0.2),
            ),
          ),
          const SizedBox(width: 4),
          _AmountText(
            amount,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 12,
              color: color.darken(0.2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Màn hình chi tiết 1 dự án + danh sách giao dịch
class ProjectDetailScreen extends StatefulWidget {
  const ProjectDetailScreen({
    super.key,
    required this.project,
    required this.onUpdateProject,
    required this.onAddTransaction,
    required this.onUpdateTransaction,
    required this.onDeleteProject,
  });

  final Project project;
  final void Function(Project) onUpdateProject;
  final Future<void> Function(String projectId, ProjectTransaction)
      onAddTransaction;
  final Future<void> Function(String projectId, ProjectTransaction)
      onUpdateTransaction;
  final Future<void> Function(String projectId) onDeleteProject;

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  bool _loading = true;
  List<ProjectTransaction> _transactions = [];
  int _txTabIndex = 0; // 0 = Chi, 1 = Thu, 2 = Tất cả

  double get _income => _transactions
      .where((t) => t.isIncome)
      .fold(0.0, (sum, t) => sum + t.amount);

  double get _expense => _transactions
      .where((t) => !t.isIncome)
      .fold(0.0, (sum, t) => sum + t.amount);

  double get _balance => _income - _expense;

  @override
  void initState() {
    super.initState();
    _loadTransactions();
  }

  Future<void> _loadTransactions() async {
    setState(() {
      _loading = true;
    });
    try {
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/projects/${widget.project.id}/transactions'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List<dynamic>;
        _transactions = data
            .map(
              (e) => ProjectTransaction.fromJson(
                e as Map<String, dynamic>,
              ),
            )
            .toList();
      }
    } catch (_) {
      // giữ nguyên state hiện tại nếu lỗi
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<pw.ThemeData?> _loadPdfTheme() async {
    try {
      final regular =
          await rootBundle.load('assets/fonts/Roboto/static/Roboto-Regular.ttf');
      final bold =
          await rootBundle.load('assets/fonts/Roboto/static/Roboto-Bold.ttf');
      final italic =
          await rootBundle.load('assets/fonts/Roboto/static/Roboto-Italic.ttf');
      final boldItalic = await rootBundle
          .load('assets/fonts/Roboto/static/Roboto-BoldItalic.ttf');

      return pw.ThemeData.withFont(
        base: pw.Font.ttf(regular),
        bold: pw.Font.ttf(bold),
        italic: pw.Font.ttf(italic),
        boldItalic: pw.Font.ttf(boldItalic),
      );
    } catch (_) {}

    // Fallback Unicode font (covers Vietnamese very well).
    try {
      final base = await PdfGoogleFonts.notoSansRegular();
      final bold = await PdfGoogleFonts.notoSansBold();
      final italic = await PdfGoogleFonts.notoSansItalic();
      final boldItalic = await PdfGoogleFonts.notoSansBoldItalic();
      return pw.ThemeData.withFont(
        base: base,
        bold: bold,
        italic: italic,
        boldItalic: boldItalic,
      );
    } catch (_) {}

    return null;
  }

  Future<Uint8List> _buildPdfBytes(
    pw.ThemeData? theme, {
    bool useVietnameseLabels = true,
  }) {
    final income = _income;
    final expense = _expense;
    final balance = _balance;

    final sTongQuan = useVietnameseLabels ? 'Tổng quan' : 'Tong quan';
    final sSoDu = useVietnameseLabels ? 'Số dư' : 'So du';
    final sGiaoDich = useVietnameseLabels ? 'Giao dịch' : 'Giao dich';
    final sNgay = useVietnameseLabels ? 'Ngày' : 'Ngay';
    final sNoiDung = useVietnameseLabels ? 'Nội dung' : 'Noi dung';
    final sSoTien = useVietnameseLabels ? 'Số tiền' : 'So tien';

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        theme: theme,
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Text(
                widget.project.name,
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(height: 4),
            if (widget.project.description.isNotEmpty)
              pw.Text(
                widget.project.description,
                style: const pw.TextStyle(fontSize: 10),
              ),
            pw.SizedBox(height: 12),
            pw.Text(
              sTongQuan,
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text('Thu: ${formatCurrency(income)}', style: const pw.TextStyle(fontSize: 10)),
                pw.Text('Chi: ${formatCurrency(expense)}', style: const pw.TextStyle(fontSize: 10)),
                pw.Text('$sSoDu: ${formatCurrency(balance)}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              ],
            ),
            pw.SizedBox(height: 16),
            pw.Text(
              sGiaoDich,
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Table(
              border: pw.TableBorder.all(width: 0.5),
              columnWidths: {
                0: const pw.FlexColumnWidth(2),
                1: const pw.FlexColumnWidth(3),
                2: const pw.FlexColumnWidth(1.5),
                3: const pw.FlexColumnWidth(2),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(sNgay, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(sNoiDung, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text('Loại', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(sSoTien, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
                    ),
                  ],
                ),
                ..._transactions.reversed.map((t) {
                  return pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text(formatDate(t.date), style: const pw.TextStyle(fontSize: 9)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text(t.note.isEmpty ? (t.isIncome ? 'Thu' : 'Chi') : t.note, style: const pw.TextStyle(fontSize: 9)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text(t.isIncome ? 'Thu' : 'Chi', style: const pw.TextStyle(fontSize: 9)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(4),
                        child: pw.Text('${t.isIncome ? "+" : "-"}${formatCurrency(t.amount)}', style: const pw.TextStyle(fontSize: 9)),
                      ),
                    ],
                  );
                }),
              ],
            ),
          ];
        },
      ),
    );
    return doc.save();
  }

  Future<void> _exportProjectToPdf() async {
    pw.ThemeData? theme;
    try {
      theme = await _loadPdfTheme();
    } catch (_) {}

    // Always keep Vietnamese labels. If font loading fails, the PDF still
    // exports, but labels remain in Vietnamese instead of degrading to ASCII.
    final bytes = await _buildPdfBytes(theme, useVietnameseLabels: true);

    final name = 'du-an-${widget.project.name.replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(' ', '_')}.pdf';
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Xuất dữ liệu dự án',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (kIsWeb) {
                    backup_dl.downloadBytesFileOnWeb(
                      name,
                      bytes,
                      mimeType: 'application/pdf',
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Đã tải file PDF. Mở file và dùng Ctrl+P (hoặc menu in) để in.',
                          ),
                        ),
                      );
                    }
                  } else {
                    await Printing.sharePdf(
                      bytes: bytes,
                      filename: name,
                    );
                  }
                },
                icon: const Icon(Icons.print_outlined),
                label: const Text('Tải / Lưu file PDF'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (kIsWeb) {
                    backup_dl.downloadBytesFileOnWeb(
                      name,
                      bytes,
                      mimeType: 'application/pdf',
                    );
                  } else {
                    await Printing.sharePdf(
                      bytes: bytes,
                      filename: name,
                    );
                  }
                },
                icon: const Icon(Icons.ios_share_outlined),
                label: Text(kIsWeb ? 'Tải file PDF' : 'Tải file PDF & chia sẻ'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final income = _income;
    final expense = _expense;
    final balance = _balance;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Xuất PDF / In',
            icon: const Icon(Icons.print_outlined),
            onPressed: () async {
              await _exportProjectToPdf();
            },
          ),
          IconButton(
            tooltip: 'Nhật ký',
            icon: const Icon(Icons.book_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) => Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: ProjectDiaryScreen(project: widget.project),
                    ),
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _showEditProjectDialog(context),
          ),
          IconButton(
            tooltip: 'Xóa dự án',
            icon: Icon(Icons.delete_outline, color: Colors.red[700]),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  title: const Text('Xóa dự án?'),
                  content: const Text(
                    'Hành động này sẽ xóa dự án và toàn bộ giao dịch/nhật ký liên quan. Bạn có chắc chắn muốn xóa?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Hủy'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Xóa'),
                    ),
                  ],
                ),
              );

              if (ok != true) return;
              await widget.onDeleteProject(widget.project.id);
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      body: Container(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.2),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                elevation: 1,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tổng quan',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _OverviewTile(
                              title: 'Chi',
                              amount: expense,
                              color: Colors.red,
                              icon: Icons.trending_up,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _OverviewTile(
                              title: 'Thu',
                              amount: income,
                              color: Colors.green,
                              icon: Icons.trending_down,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: balance >= 0
                              ? Colors.teal.withOpacity(0.08)
                              : Colors.red.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.account_balance_wallet_outlined,
                              color:
                                  balance >= 0 ? Colors.teal : Colors.red[700],
                            ),
                            const SizedBox(width: 8),
                            const Text('Số dư: '),
                            Flexible(
                              child: Text(
                                formatCurrency(balance),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: balance >= 0
                                      ? Colors.teal
                                      : Colors.red[700],
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Giao dịch',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${_filteredTransactions.length}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Row(
                      children: [
                        _TxTabChip(
                          label: 'Chi',
                          isSelected: _txTabIndex == 0,
                          color: Colors.red,
                          onTap: () {
                            setState(() {
                              _txTabIndex = 0;
                            });
                          },
                        ),
                        _TxTabChip(
                          label: 'Thu',
                          isSelected: _txTabIndex == 1,
                          color: Colors.green,
                          onTap: () {
                            setState(() {
                              _txTabIndex = 1;
                            });
                          },
                        ),
                        _TxTabChip(
                          label: 'Tất cả',
                          isSelected: _txTabIndex == 2,
                          color: Theme.of(context).colorScheme.primary,
                          onTap: () {
                            setState(() {
                              _txTabIndex = 2;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _transactions.isEmpty
                      ? const _EmptyTransactionsView()
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          itemCount: _filteredTransactions.length,
                          itemBuilder: (ctx, index) {
                            final tx = _filteredTransactions[index];
                            final color =
                                tx.isIncome ? Colors.green : Colors.red.shade700;
                            final sign = tx.isIncome ? '+' : '-';

                            Widget? trailing;
                            if (tx.imageBase64 != null) {
                              trailing = GestureDetector(
                                onTap: () {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => Dialog(
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(16),
                                        child: Image.memory(
                                          base64Decode(tx.imageBase64!),
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    base64Decode(tx.imageBase64!),
                                    height: 42,
                                    width: 42,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              );
                            }

                            return Card(
                              margin: const EdgeInsets.symmetric(
                                  vertical: 4, horizontal: 2),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: ListTile(
                                onTap: () => _showEditTransactionSheet(tx),
                                leading: CircleAvatar(
                                  backgroundColor: color.withOpacity(0.14),
                                  foregroundColor: color,
                                  child: Icon(
                                    tx.isIncome
                                        ? Icons.arrow_downward
                                        : Icons.arrow_upward,
                                  ),
                                ),
                                title: Text(
                                  tx.note.isEmpty
                                      ? (tx.isIncome ? 'Thu' : 'Chi')
                                      : tx.note,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(formatDate(tx.date)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                      Flexible(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          _AmountText(
                                            tx.amount,
                                            prefixSign: sign,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: color,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (trailing != null) ...[
                                      const SizedBox(width: 8),
                                      trailing,
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'detail_fab',
        onPressed: () => _showAddTransactionSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('Thêm giao dịch'),
      ),
    );
  }

  List<ProjectTransaction> get _filteredTransactions {
    List<ProjectTransaction> list;
    if (_txTabIndex == 0) {
      list = _transactions.where((t) => !t.isIncome).toList();
    } else if (_txTabIndex == 1) {
      list = _transactions.where((t) => t.isIncome).toList();
    } else {
      list = List<ProjectTransaction>.from(_transactions);
    }
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  void _showEditTransactionSheet(ProjectTransaction tx) {
    final amountController = TextEditingController(
        text: formatAmountThousandsDots(
            _amountFieldDigitsOnly(tx.amount.toStringAsFixed(0))));
    final noteController = TextEditingController(text: tx.note);
    bool isIncome = tx.isIncome;
    final formKey = GlobalKey<FormState>();
    Uint8List? imageBytes =
        tx.imageBase64 != null ? base64Decode(tx.imageBase64!) : null;
    String? imageMime = tx.imageContentType;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setState) {
              return Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[400],
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Text(
                      'Sửa giao dịch',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    ToggleButtons(
                      isSelected: [!isIncome, isIncome],
                      onPressed: (index) {
                        setState(() {
                          // index 0 = Chi, index 1 = Thu
                          isIncome = index == 1;
                        });
                      },
                      borderRadius: BorderRadius.circular(20),
                      children: const [
                        Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          child: Text('Chi'),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          child: Text('Thu'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: amountController,
                      decoration: const InputDecoration(
                        labelText: 'Số tiền',
                        prefixIcon: Icon(Icons.attach_money),
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: false),
                      inputFormatters: [ThousandsDotAmountInputFormatter()],
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Vui lòng nhập số tiền';
                        }
                        final digits = _amountFieldDigitsOnly(value);
                        final parsed = double.tryParse(digits);
                        if (parsed == null || parsed <= 0) {
                          return 'Số tiền không hợp lệ';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: noteController,
                      decoration: const InputDecoration(
                        labelText: 'Ghi chú',
                        prefixIcon: Icon(Icons.notes_outlined),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              withData: true,
                            );
                            if (result != null &&
                                result.files.isNotEmpty &&
                                result.files.first.bytes != null) {
                              final processed = await _prepareImageForUpload(
                                result.files.first.bytes!,
                              );
                              if (!ctx.mounted) return;
                              if (processed == null) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Ảnh vượt quá 10MB sau khi tối ưu. Vui lòng chọn ảnh khác.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              setState(() {
                                imageBytes = processed;
                                imageMime = 'image/jpeg';
                              });
                            }
                          },
                          icon: const Icon(Icons.image_outlined),
                          label: Text(
                            imageBytes == null
                                ? 'Thay hình hóa đơn'
                                : 'Đổi hình hóa đơn',
                          ),
                        ),
                        const Spacer(),
                        if (imageBytes != null)
                          TextButton(
                            onPressed: () {
                              setState(() {
                                imageBytes = null;
                                imageMime = null;
                              });
                            },
                            child: const Text(
                              'Xóa hình',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                      ],
                    ),
                    if (imageBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          imageBytes!,
                          height: 120,
                          fit: BoxFit.cover,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Hủy'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () async {
                            if (!formKey.currentState!.validate()) return;
                            final raw =
                                _amountFieldDigitsOnly(amountController.text);
                            final amount = double.parse(raw);
                            final updated = ProjectTransaction(
                              id: tx.id,
                              amount: amount,
                              isIncome: isIncome,
                              note: noteController.text.trim(),
                              date: tx.date,
                              imageBase64: imageBytes != null
                                  ? base64Encode(imageBytes!)
                                  : null,
                              imageContentType: imageMime,
                            );
                            await widget.onUpdateTransaction(
                              widget.project.id,
                              updated,
                            );
                            await _loadTransactions();
                            Navigator.of(ctx).pop();
                          },
                          child: const Text('Lưu'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _showEditProjectDialog(BuildContext context) {
    final nameController = TextEditingController(text: widget.project.name);
    final descController =
        TextEditingController(text: widget.project.description);
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Chỉnh sửa dự án'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Tên dự án',
                  prefixIcon: Icon(Icons.work_outline),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Vui lòng nhập tên dự án';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: descController,
                decoration: const InputDecoration(
                  labelText: 'Mô tả',
                  prefixIcon: Icon(Icons.notes_outlined),
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final updated = Project(
                id: widget.project.id,
                name: nameController.text.trim(),
                description: descController.text.trim(),
                totalIncome: widget.project.totalIncome,
                totalExpense: widget.project.totalExpense,
                createdAt: widget.project.createdAt,
              );
              widget.onUpdateProject(updated);
              Navigator.of(ctx).pop();
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }

  void _showAddTransactionSheet(BuildContext context) {
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    // Mặc định chọn Chi
    bool isIncome = false;
    final formKey = GlobalKey<FormState>();
    Uint8List? imageBytes;
    String? imageMime;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setState) {
              return Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[400],
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Text(
                      'Giao dịch mới',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    ToggleButtons(
                      isSelected: [!isIncome, isIncome],
                      onPressed: (index) {
                        setState(() {
                          // index 0 = Chi, index 1 = Thu
                          isIncome = index == 1;
                        });
                      },
                      borderRadius: BorderRadius.circular(20),
                      children: const [
                        Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          child: Text('Chi'),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          child: Text('Thu'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: amountController,
                      decoration: const InputDecoration(
                        labelText: 'Số tiền',
                        prefixIcon: Icon(Icons.attach_money),
                      ),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: false),
                      inputFormatters: [ThousandsDotAmountInputFormatter()],
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Vui lòng nhập số tiền';
                        }
                        final digits = _amountFieldDigitsOnly(value);
                        final parsed = double.tryParse(digits);
                        if (parsed == null || parsed <= 0) {
                          return 'Số tiền không hợp lệ';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: noteController,
                      decoration: const InputDecoration(
                        labelText: 'Ghi chú (tuỳ chọn)',
                        prefixIcon: Icon(Icons.notes_outlined),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final result = await FilePicker.platform.pickFiles(
                            type: FileType.image,
                            withData: true,
                          );
                          if (result != null &&
                              result.files.isNotEmpty &&
                              result.files.first.bytes != null) {
                            final processed = await _prepareImageForUpload(
                              result.files.first.bytes!,
                            );
                            if (!ctx.mounted) return;
                            if (processed == null) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Ảnh vượt quá 10MB sau khi tối ưu. Vui lòng chọn ảnh khác.',
                                  ),
                                ),
                              );
                              return;
                            }
                            setState(() {
                              imageBytes = processed;
                              imageMime = 'image/jpeg';
                            });
                          }
                        },
                        icon: const Icon(Icons.image_outlined),
                        label: Text(
                          imageBytes == null
                              ? 'Đính kèm hình hóa đơn (tuỳ chọn)'
                              : 'Đã chọn hình hóa đơn',
                        ),
                      ),
                    ),
                    if (imageBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          imageBytes!,
                          height: 120,
                          fit: BoxFit.cover,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Hủy'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () async {
                            if (!formKey.currentState!.validate()) return;
                            final raw =
                                _amountFieldDigitsOnly(amountController.text);
                            final amount = double.parse(raw);
                            final tx = ProjectTransaction(
                              id:
                                  't_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}',
                              amount: amount,
                              isIncome: isIncome,
                              note: noteController.text.trim(),
                              date: DateTime.now(),
                              imageBase64: imageBytes != null
                                  ? base64Encode(imageBytes!)
                                  : null,
                              imageContentType: imageMime,
                            );
                            await widget.onAddTransaction(widget.project.id, tx);
                            await _loadTransactions();
                            Navigator.of(ctx).pop();
                          },
                          child: const Text('Lưu'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _OverviewTile extends StatelessWidget {
  const _OverviewTile({
    required this.title,
    required this.amount,
    required this.color,
    required this.icon,
  });

  final String title;
  final double amount;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: color.withOpacity(0.14),
            foregroundColor: color,
            child: Icon(icon, size: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey[700],
                      ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                _AmountText(
                  amount,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: color.darken(0.2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTransactionsView extends StatelessWidget {
  const _EmptyTransactionsView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 48,
              color: Colors.grey[500],
            ),
            const SizedBox(height: 12),
            Text(
              'Chưa có giao dịch nào',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Nhấn nút "Thêm giao dịch" để bắt đầu ghi nhận thu chi cho dự án này.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

class _TxTabChip extends StatelessWidget {
  const _TxTabChip({
    required this.label,
    required this.isSelected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selectedColor = color;
    final unselectedColor = Colors.grey[400]!;

    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? selectedColor.withOpacity(0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isSelected ? selectedColor : unselectedColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProjectDiaryScreen extends StatefulWidget {
  const ProjectDiaryScreen({super.key, required this.project});

  final Project project;

  @override
  State<ProjectDiaryScreen> createState() => _ProjectDiaryScreenState();
}

class _ProjectDiaryScreenState extends State<ProjectDiaryScreen> {
  bool _loading = true;
  List<ProjectNote> _notes = [];

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    setState(() {
      _loading = true;
    });
    try {
      final res = await http.get(
        Uri.parse('$apiBaseUrl/api/projects/${widget.project.id}/notes'),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List<dynamic>;
        _notes = data
            .map((e) => ProjectNote.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      // giữ nguyên nếu lỗi
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _addNote(ProjectNote note) async {
    try {
      final res = await http.post(
        Uri.parse('$apiBaseUrl/api/projects/${widget.project.id}/notes'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'content': note.content,
          'imageBase64': note.imageBase64,
          'imageContentType': note.imageContentType,
        }),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _notes.insert(0, ProjectNote.fromJson(data));
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Nhật ký dự án'),
            Text(
              widget.project.name,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ],
        ),
        centerTitle: true,
      ),
      body: Container(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.2),
        child: RefreshIndicator(
          onRefresh: _loadNotes,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _notes.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 160),
                        _EmptyNotesView(),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _notes.length,
                      itemBuilder: (ctx, index) {
                        final note = _notes[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.event_note_outlined,
                                            size: 16,
                                            color: Colors.grey[600],
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            formatDate(note.date),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                    color: Colors.grey[700]),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        note.content.isEmpty
                                            ? '(Không có nội dung)'
                                            : note.content,
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(height: 1.25),
                                      ),
                                    ],
                                  ),
                                ),
                                if (note.imageBase64 != null) ...[
                                  const SizedBox(width: 10),
                                  GestureDetector(
                                    onTap: () {
                                      showDialog(
                                        context: context,
                                        builder: (ctx) => Dialog(
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            child: Image.memory(
                                              base64Decode(
                                                  note.imageBase64!),
                                              fit: BoxFit.contain,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.memory(
                                        base64Decode(note.imageBase64!),
                                        height: 56,
                                        width: 56,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'diary_fab',
        onPressed: _showAddNoteSheet,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('Thêm nhật ký'),
      ),
    );
  }

  void _showAddNoteSheet() {
    final contentController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    Uint8List? imageBytes;
    String? imageMime;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setState) {
              return Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey[400],
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Text(
                      'Nhật ký mới',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: contentController,
                      decoration: const InputDecoration(
                        labelText: 'Nội dung',
                        alignLabelWithHint: true,
                        prefixIcon: Icon(Icons.short_text),
                      ),
                      maxLines: 4,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Vui lòng nhập nội dung';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              withData: true,
                            );
                            if (result != null &&
                                result.files.isNotEmpty &&
                                result.files.first.bytes != null) {
                              final processed = await _prepareImageForUpload(
                                result.files.first.bytes!,
                              );
                              if (!ctx.mounted) return;
                              if (processed == null) {
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Ảnh vượt quá 10MB sau khi tối ưu. Vui lòng chọn ảnh khác.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              setState(() {
                                imageBytes = processed;
                                imageMime = 'image/jpeg';
                              });
                            }
                          },
                          icon: const Icon(Icons.image_outlined),
                          label: Text(
                            imageBytes == null
                                ? 'Thêm hình (tuỳ chọn)'
                                : 'Đã chọn hình',
                          ),
                        ),
                        const Spacer(),
                        if (imageBytes != null)
                          TextButton(
                            onPressed: () {
                              setState(() {
                                imageBytes = null;
                                imageMime = null;
                              });
                            },
                            child: const Text(
                              'Xóa hình',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                      ],
                    ),
                    if (imageBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          imageBytes!,
                          height: 140,
                          fit: BoxFit.cover,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Hủy'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () async {
                            if (!formKey.currentState!.validate()) return;
                            final note = ProjectNote(
                              id: '',
                              content: contentController.text.trim(),
                              date: DateTime.now(),
                              imageBase64: imageBytes != null
                                  ? base64Encode(imageBytes!)
                                  : null,
                              imageContentType: imageMime,
                            );
                            await _addNote(note);
                            if (mounted) {
                              Navigator.of(ctx).pop();
                            }
                          },
                          child: const Text('Lưu'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _EmptyNotesView extends StatelessWidget {
  const _EmptyNotesView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_note_outlined,
              size: 48,
              color: Colors.grey[500],
            ),
            const SizedBox(height: 12),
            Text(
              'Chưa có nhật ký nào',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Nhấn nút "Thêm nhật ký" để ghi lại diễn biến, lưu ý hoặc lịch sử làm việc của dự án.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyProjectsView extends StatelessWidget {
  const _EmptyProjectsView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.work_outline,
              size: 48,
              color: Colors.grey[500],
            ),
            const SizedBox(height: 12),
            Text(
              'Chưa có dự án nào',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Nhấn nút "Thêm dự án" để tạo dự án đầu tiên.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

class AppUser {
  AppUser({
    required this.id,
    required this.phone,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
    required this.remainingDays,
    this.paymentQrBase64,
  });

  final String id;
  String phone;
  String name;
  String email;
  String role;
  bool isActive;
  int remainingDays;
  String? paymentQrBase64;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      phone: (json['phone'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      email: (json['email'] ?? '') as String,
      role: (json['role'] ?? 'user') as String,
      isActive: json['isActive'] as bool? ?? true,
      remainingDays: (json['remainingDays'] as num?)?.toInt() ?? 0,
      paymentQrBase64: json['paymentQrBase64'] as String?,
    );
  }

  Map<String, dynamic> toJson({bool forCreate = false}) {
    return {
      if (!forCreate) 'id': id,
      'phone': phone,
      'name': name,
      'email': email,
      'role': role,
      'isActive': isActive,
      'expiresInDays': remainingDays,
      'paymentQrBase64': paymentQrBase64,
    };
  }
}

class AdminUserScreen extends StatefulWidget {
  const AdminUserScreen({
    super.key,
    required this.users,
    required this.loading,
    required this.onRefresh,
    required this.onAddUser,
    required this.onUpdateUser,
    required this.onDeleteUser,
    required this.onExtendUser,
    required this.onChangeUserPassword,
    required this.onUpdateGlobalPaymentQr,
    required this.onUpdateUserPaymentQr,
  });

  final List<AppUser> users;
  final bool loading;
  final Future<void> Function() onRefresh;
  final Future<void> Function(AppUser user) onAddUser;
  final Future<void> Function(AppUser user) onUpdateUser;
  final Future<void> Function(String id) onDeleteUser;
  final Future<void> Function(String userId, int addDays) onExtendUser;
  final Future<void> Function(String userId, String newPassword)
      onChangeUserPassword;
  final Future<void> Function(String? paymentQrBase64)
      onUpdateGlobalPaymentQr;
  final Future<void> Function(String userId, String? paymentQrBase64)
      onUpdateUserPaymentQr;

  @override
  State<AdminUserScreen> createState() => _AdminUserScreenState();
}

class _AdminUserScreenState extends State<AdminUserScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _query = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final users = widget.users;
    final loading = widget.loading;
    final filteredUsers = _query.isEmpty
        ? users
        : users
            .where((u) =>
                u.name.toLowerCase().contains(_query) ||
                u.phone.contains(_query))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin - Quản lý user'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Tải mã QR thanh toán cho tất cả',
            onPressed: (loading || widget.users.isEmpty)
                ? null
                : () => _showAdminGlobalPaymentQrDialog(
                      context,
                      widget.onUpdateGlobalPaymentQr,
                    ),
            icon: const Icon(Icons.qr_code_2_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Tìm theo tên hoặc số điện thoại',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ),
        ),
      ),
      body: Container(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.2),
        child: RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : filteredUsers.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        _EmptyUsersView(),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: filteredUsers.length,
                      itemBuilder: (ctx, index) {
                        final user = filteredUsers[index];
                        final isAdmin = user.role == 'admin';
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(user.name.isNotEmpty
                                  ? user.name[0].toUpperCase()
                                  : '?'),
                            ),
                            title: Text(user.name),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user.phone.isEmpty
                                      ? user.email
                                      : user.phone,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isAdmin
                                            ? Colors.orange.withOpacity(0.15)
                                            : Colors.blue.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        isAdmin ? 'Admin' : 'User',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isAdmin
                                              ? Colors.orange[800]
                                              : Colors.blue[800],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.purple.withOpacity(0.06),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        user.remainingDays > 0
                                            ? '${user.remainingDays} ngày còn lại'
                                            : 'Hết hạn',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.purple[800],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: user.isActive
                                            ? Colors.green.withOpacity(0.1)
                                            : Colors.red.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        user.isActive
                                            ? 'Active'
                                            : 'Khoá',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: user.isActive
                                              ? Colors.green[800]
                                              : Colors.red[800],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) async {
                                if (value == 'toggle_active') {
                                  final updated = AppUser(
                                    id: user.id,
                                    phone: user.phone,
                                    name: user.name,
                                    email: user.email,
                                    role: user.role,
                                    isActive: !user.isActive,
                                    remainingDays: user.remainingDays,
                                    // Keep current payment QR so it isn't cleared
                                    // when admin updates other user fields.
                                    paymentQrBase64: user.paymentQrBase64,
                                  );
                                  await widget.onUpdateUser(updated);
                                } else if (value == 'toggle_role') {
                                  final updated = AppUser(
                                    id: user.id,
                                    phone: user.phone,
                                    name: user.name,
                                    email: user.email,
                                    role: isAdmin ? 'user' : 'admin',
                                    isActive: user.isActive,
                                    remainingDays: user.remainingDays,
                                    // Keep current payment QR so it isn't cleared
                                    // when admin updates other user fields.
                                    paymentQrBase64: user.paymentQrBase64,
                                  );
                                  await widget.onUpdateUser(updated);
                                } else if (value == 'extend') {
                                  _showExtendDialog(
                                      ctx, user, widget.onExtendUser);
                                } else if (value == 'change_password') {
                                  _showAdminChangePasswordDialog(ctx, user,
                                      widget.onChangeUserPassword);
                                } else if (value == 'delete') {
                                  await widget.onDeleteUser(user.id);
                                }
                              },
                              itemBuilder: (ctx) => [
                                PopupMenuItem(
                                  value: 'toggle_active',
                                  child: Text(user.isActive
                                      ? 'Khoá tài khoản'
                                      : 'Mở khoá tài khoản'),
                                ),
                                PopupMenuItem(
                                  value: 'toggle_role',
                                  child: Text(isAdmin
                                      ? 'Chuyển thành User'
                                      : 'Chuyển thành Admin'),
                                ),
                                const PopupMenuItem(
                                  value: 'extend',
                                  child: Row(
                                    children: [
                                      Icon(Icons.date_range, size: 20),
                                      SizedBox(width: 8),
                                      Text('Gia hạn sử dụng'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'change_password',
                                  child: Row(
                                    children: [
                                      Icon(Icons.lock_reset, size: 20),
                                      SizedBox(width: 8),
                                      Text('Đổi mật khẩu'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    'Xoá user',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'admin_fab',
        onPressed: () => _showAddUserDialog(context),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Thêm user'),
      ),
    );
  }

  static void _showExtendDialog(
    BuildContext context,
    AppUser user,
    Future<void> Function(String userId, int addDays) onExtendUser,
  ) {
    final daysController = TextEditingController(text: '30');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Gia hạn sử dụng'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'User: ${user.name} (${user.phone.isNotEmpty ? user.phone : user.email})',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: daysController,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: false,
              ),
              decoration: const InputDecoration(
                labelText: 'Thêm / trừ số ngày',
                hintText: '30 hoặc -7',
                helperText: 'Số dương: gia hạn. Số âm: giảm ngày còn lại.',
                prefixIcon: Icon(Icons.calendar_today_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () async {
              final days = int.tryParse(daysController.text.trim());
              if (days == null || days == 0) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Vui lòng nhập số ngày khác 0 (dương để cộng, âm để trừ)',
                    ),
                  ),
                );
                return;
              }
              Navigator.pop(ctx);
              await onExtendUser(user.id, days);
              if (ctx.mounted) {
                final msg = days > 0
                    ? 'Đã cộng thêm $days ngày cho user'
                    : 'Đã trừ ${-days} ngày cho user';
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(msg)),
                );
              }
            },
            child: const Text('Áp dụng'),
          ),
        ],
      ),
    );
  }

  static void _showAdminChangePasswordDialog(
    BuildContext context,
    AppUser user,
    Future<void> Function(String userId, String newPassword)
        onChangeUserPassword,
  ) {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool loading = false;
    String? error;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Text('Đổi mật khẩu user'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'User: ${user.name} (${user.phone.isNotEmpty ? user.phone : user.email})',
                      style: Theme.of(ctx).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: passwordController,
                      decoration: const InputDecoration(
                        labelText: 'Mật khẩu mới',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      obscureText: true,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Vui lòng nhập mật khẩu mới';
                        }
                        if (value.trim().length < 6) {
                          return 'Mật khẩu tối thiểu 6 ký tự';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: confirmController,
                      decoration: const InputDecoration(
                        labelText: 'Nhập lại mật khẩu',
                        prefixIcon: Icon(Icons.lock_reset),
                      ),
                      obscureText: true,
                      validator: (value) {
                        if (value != passwordController.text) {
                          return 'Mật khẩu nhập lại không khớp';
                        }
                        return null;
                      },
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: loading ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Hủy'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setState(() {
                            loading = true;
                            error = null;
                          });
                          try {
                            await onChangeUserPassword(
                              user.id,
                              passwordController.text.trim(),
                            );
                            Navigator.of(ctx).pop();
                          } catch (_) {
                            setState(() {
                              error = 'Không thể đổi mật khẩu. Thử lại sau.';
                              loading = false;
                            });
                          }
                        },
                  child: loading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Lưu'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddUserDialog(BuildContext context) {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final emailController = TextEditingController();
    String role = 'user';
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('User mới'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Tên',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Vui lòng nhập tên';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: phoneController,
                decoration: const InputDecoration(
                  labelText: 'Số điện thoại',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Vui lòng nhập số điện thoại';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Vui lòng nhập email';
                  }
                  if (!value.contains('@')) {
                    return 'Email không hợp lệ';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              StatefulBuilder(
                builder: (ctx, setState) {
                  return DropdownButtonFormField<String>(
                    value: role,
                    decoration: const InputDecoration(
                      labelText: 'Vai trò',
                      prefixIcon: Icon(Icons.security_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'user',
                        child: Text('User'),
                      ),
                      DropdownMenuItem(
                        value: 'admin',
                        child: Text('Admin'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        role = value;
                      });
                    },
                  );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final user = AppUser(
                id: '',
                phone: phoneController.text.trim(),
                name: nameController.text.trim(),
                email: emailController.text.trim(),
                role: role,
                isActive: true,
                remainingDays: 30,
              );
              await widget.onAddUser(user);
              if (context.mounted) {
                Navigator.of(ctx).pop();
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }

  static void _showAdminPaymentQrDialog(
    BuildContext context,
    AppUser user,
    Future<void> Function(String userId, String? paymentQrBase64)
        onUpdateUserPaymentQr,
  ) {
    Uint8List? imageBytes =
        user.paymentQrBase64 != null ? base64Decode(user.paymentQrBase64!) : null;
    String? imageMime;
    bool loading = false;
    String? error;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Text('Mã QR thanh toán'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'User: ${user.name} (${user.phone.isNotEmpty ? user.phone : user.email})',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  if (imageBytes != null) ...[
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          imageBytes!,
                          height: 180,
                          width: 180,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextButton.icon(
                    onPressed: loading
                        ? null
                        : () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              withData: true,
                            );
                            if (result != null &&
                                result.files.isNotEmpty &&
                                result.files.first.bytes != null) {
                              final processed = await _prepareImageForUpload(
                                result.files.first.bytes!,
                              );
                              if (!ctx.mounted) return;
                              if (processed == null) {
                                setState(() {
                                  error =
                                      'Ảnh vượt quá 10MB sau khi tối ưu. Vui lòng chọn ảnh nhỏ hơn.';
                                });
                                return;
                              }
                              setState(() {
                                imageBytes = processed;
                                imageMime = 'jpeg';
                                error = null;
                              });
                            }
                          },
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Chọn ảnh QR từ máy'),
                  ),
                  if (imageBytes != null)
                    TextButton.icon(
                      onPressed: loading
                          ? null
                          : () {
                              setState(() {
                                imageBytes = null;
                                imageMime = null;
                              });
                            },
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      label: const Text(
                        'Xoá mã QR hiện tại',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style:
                          const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: loading ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Hủy'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          setState(() {
                            loading = true;
                            error = null;
                          });
                          try {
                            final base64 = imageBytes != null
                                ? base64Encode(imageBytes!)
                                : null;
                            await onUpdateUserPaymentQr(user.id, base64);
                            if (context.mounted) {
                              Navigator.of(ctx).pop();
                            }
                          } catch (_) {
                            setState(() {
                              error =
                                  'Không thể lưu mã QR. Vui lòng thử lại sau.';
                              loading = false;
                            });
                          }
                        },
                  child: loading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Lưu'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static void _showAdminGlobalPaymentQrDialog(
    BuildContext context,
    Future<void> Function(String? paymentQrBase64)
        onUpdateGlobalPaymentQr,
  ) {
    Uint8List? imageBytes = null;
    String? imageMime;
    bool loading = false;
    String? error;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Mã QR thanh toán (dùng cho tất cả)'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (imageBytes != null) ...[
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          imageBytes!,
                          height: 180,
                          width: 180,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  TextButton.icon(
                    onPressed: loading
                        ? null
                        : () async {
                            final result =
                                await FilePicker.platform.pickFiles(
                              type: FileType.image,
                              withData: true,
                            );
                            if (result != null &&
                                result.files.isNotEmpty &&
                                result.files.first.bytes != null) {
                              final processed = await _prepareImageForUpload(
                                result.files.first.bytes!,
                              );
                              if (!ctx.mounted) return;
                              if (processed == null) {
                                setState(() {
                                  error =
                                      'Ảnh vượt quá 10MB sau khi tối ưu. Vui lòng chọn ảnh nhỏ hơn.';
                                });
                                return;
                              }
                              setState(() {
                                imageBytes = processed;
                                imageMime = 'jpeg';
                                error = null;
                              });
                            }
                          },
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Chọn ảnh QR từ máy'),
                  ),
                  if (imageBytes != null)
                    TextButton.icon(
                      onPressed: loading
                          ? null
                          : () {
                              setState(() {
                                imageBytes = null;
                                imageMime = null;
                              });
                            },
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      label: const Text(
                        'Xoá mã QR hiện tại',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: loading ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('Huỷ'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          setState(() {
                            loading = true;
                            error = null;
                          });
                          try {
                            final base64 =
                                imageBytes != null ? base64Encode(imageBytes!) : null;
                            await onUpdateGlobalPaymentQr(base64);
                            if (context.mounted) {
                              Navigator.of(ctx).pop();
                            }
                          } catch (_) {
                            setState(() {
                              error =
                                  'Không thể lưu mã QR. Vui lòng thử lại sau.';
                              loading = false;
                            });
                          }
                        },
                  child: const Text('Lưu'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _EmptyUsersView extends StatelessWidget {
  const _EmptyUsersView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline,
              size: 48,
              color: Colors.grey[500],
            ),
            const SizedBox(height: 12),
            Text(
              'Chưa có user nào',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Nhấn nút "Thêm user" để tạo tài khoản mới.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tiện ích nhỏ để làm tối màu
extension _ColorUtils on Color {
  Color darken(double amount) {
    assert(amount >= 0 && amount <= 1);
    final f = 1 - amount;
    return Color.fromARGB(
      alpha,
      (red * f).round(),
      (green * f).round(),
      (blue * f).round(),
    );
  }
}