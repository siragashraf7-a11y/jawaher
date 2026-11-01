import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? err;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    err = '$e';
  }
  runApp(AdminApp(error: err));
}

class AdminApp extends StatelessWidget {
  final String? error;
  const AdminApp({super.key, this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Jawaher Admin',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFD4AF37), brightness: Brightness.dark),
      ),
      builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: error != null ? Scaffold(body: Center(child: Text(error!))) : const PinScreen(),
    );
  }
}

class PinScreen extends StatefulWidget {
  const PinScreen({super.key});
  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final pin = TextEditingController();
  final pin2 = TextEditingController();
  bool loading = true;
  bool firstRun = false;
  String? hash;
  String msg = '';

  String _h(String p) => sha256.convert(utf8.encode('jawaher-admin:$p')).toString();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await FirebaseFirestore.instance.collection('admin').doc('config').get();
      hash = d.data()?['pinHash'] as String?;
      firstRun = hash == null;
      msg = '';
    } catch (e) {
      msg = 'تعذر الاتصال: $e';
    }
    if (mounted) setState(() => loading = false);
  }

  void _enter() => Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const DevicesScreen()),
      );

  Future<void> _submit() async {
    final p = pin.text.trim();
    if (p.length < 4) {
      setState(() => msg = 'الرقم السري 4 أرقام على الأقل');
      return;
    }
    if (firstRun) {
      if (p != pin2.text.trim()) {
        setState(() => msg = 'الرقمين مش متطابقين');
        return;
      }
      await FirebaseFirestore.instance.collection('admin').doc('config').set({'pinHash': _h(p)});
      _enter();
    } else if (_h(p) == hash) {
      _enter();
    } else {
      setState(() => msg = 'الرقم السري غلط');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: loading
            ? const CircularProgressIndicator()
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.admin_panel_settings, size: 72, color: Color(0xFFD4AF37)),
                      const SizedBox(height: 12),
                      Text(firstRun ? 'أول مرة: اختار رقم سري للمسؤول' : 'ادخل الرقم السري',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      TextField(
                        controller: pin,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'الرقم السري', border: OutlineInputBorder()),
                        onSubmitted: (_) => _submit(),
                      ),
                      if (firstRun) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: pin2,
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'أعد كتابته', border: OutlineInputBorder()),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (msg.isNotEmpty) Text(msg, style: const TextStyle(color: Colors.redAccent)),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _submit,
                        child: const Padding(padding: EdgeInsets.all(12), child: Text('دخول')),
                      ),
                      if (msg.startsWith('تعذر'))
                        TextButton(onPressed: _load, child: const Text('إعادة المحاولة')),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

String _t2(int n) => n.toString().padLeft(2, '0');

String _fmt(dynamic t) {
  if (t is! Timestamp) return '-';
  final d = t.toDate();
  return '${d.year}-${_t2(d.month)}-${_t2(d.day)} ${_t2(d.hour)}:${_t2(d.minute)}';
}

Future<int?> _latestBuild() async {
  try {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final req = await c.getUrl(Uri.parse('https://api.github.com/repos/siragashraf7-a11y/jawaher/releases/tags/latest'));
    req.headers.set('User-Agent', 'jawaher-admin');
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    return int.tryParse(RegExp(r'\d+').firstMatch('${j['name']}')?.group(0) ?? '');
  } catch (_) {
    return null;
  }
}

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late final Future<int?> latest = _latestBuild();

  Widget _card(BuildContext context, QueryDocumentSnapshot<Map<String, dynamic>> doc, int? last) {
    final d = doc.data();
    final st = '${d['status'] ?? 'pending'}';
    final id = doc.id.length >= 8 ? doc.id.substring(0, 8).toUpperCase() : doc.id;
    final branch = '${d['branch'] ?? ''}';
    final build = (d['build'] as num?)?.toInt();
    final old = last != null && build != null && build < last;
    final waiting = d['forceUpdate'] == true;
    Future<void> setSt(String v) => doc.reference.update({'status': v, 'decidedAt': Timestamp.now()});
    return Card(
      child: Column(
        children: [
          ListTile(
            isThreeLine: true,
            leading: Icon(d['kind'] == 'pc' ? Icons.computer : Icons.phone_android, size: 32),
            title: Text('${d['username'] ?? ''}', textDirection: TextDirection.ltr),
            subtitle: Text(
              'الفرع: ${branch.isEmpty ? '-' : branch}\n'
              'كود الجهاز: $id  |  نسخة ${build ?? '-'}${old ? '  ⚠ قديمة' : ''}\n'
              'طلب: ${_fmt(d['requestedAt'])}\n'
              'آخر ظهور: ${_fmt(d['lastSeen'])}'
              '${waiting ? '\nطلب التحديث اتبعت ⏳' : (d['updateAckAt'] is Timestamp ? '\nآخر تحديث مطلوب اتنفذ: ${_fmt(d['updateAckAt'])}' : '')}',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Wrap(
              spacing: 6,
              children: [
                if (st != 'approved')
                  TextButton.icon(
                    onPressed: () => setSt('approved'),
                    icon: const Icon(Icons.check_circle, color: Colors.green),
                    label: const Text('قبول'),
                  ),
                if (st != 'rejected')
                  TextButton.icon(
                    onPressed: () => setSt('rejected'),
                    icon: const Icon(Icons.cancel, color: Colors.redAccent),
                    label: Text(st == 'approved' ? 'إيقاف' : 'رفض'),
                  ),
                TextButton.icon(
                  onPressed: waiting
                      ? null
                      : () async {
                          await doc.reference.update({'forceUpdate': true, 'updateRequestedAt': Timestamp.now()});
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('تم إرسال طلب التحديث. بيتنفذ خلال دقيقة لو البرنامج مفتوح، أو أول ما يتفتح')));
                          }
                        },
                  icon: Icon(Icons.system_update, color: old ? Colors.orange : null),
                  label: const Text('تحديث'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        content: const Text('مسح الجهاز ده من القايمة؟ (هيطلب موافقة من جديد لو فتح البرنامج)'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('مسح')),
                        ],
                      ),
                    );
                    if (ok == true) doc.reference.delete();
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('مسح'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int?>(
      future: latest,
      builder: (context, lf) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('devices').snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return Scaffold(
              appBar: AppBar(title: const Text('الأجهزة')),
              body: Center(child: snap.hasError ? Text('${snap.error}') : const CircularProgressIndicator()),
            );
          }
          final docs = snap.data!.docs.toList()
            ..sort((a, b) {
              final x = a.data()['requestedAt'];
              final y = b.data()['requestedAt'];
              if (x is Timestamp && y is Timestamp) return y.compareTo(x);
              return 0;
            });
          List<QueryDocumentSnapshot<Map<String, dynamic>>> by(String st) =>
              docs.where((d) => '${d.data()['status'] ?? 'pending'}' == st).toList();
          final pending = by('pending'), approved = by('approved'), rejected = by('rejected');
          Widget list(List<QueryDocumentSnapshot<Map<String, dynamic>>> l) => l.isEmpty
              ? const Center(child: Text('لا يوجد'))
              : ListView(padding: const EdgeInsets.all(10), children: [for (final d in l) _card(context, d, lf.data)]);
          return DefaultTabController(
            length: 3,
            child: Scaffold(
              appBar: AppBar(
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('أجهزة المستخدمين'),
                    if (lf.data != null) Text('أحدث نسخة: ${lf.data}', style: const TextStyle(fontSize: 12)),
                  ],
                ),
                bottom: TabBar(tabs: [
                  Tab(text: 'بانتظار (${pending.length})'),
                  Tab(text: 'مقبول (${approved.length})'),
                  Tab(text: 'مرفوض (${rejected.length})'),
                ]),
              ),
              body: TabBarView(children: [list(pending), list(approved), list(rejected)]),
            ),
          );
        },
      ),
    );
  }
}
