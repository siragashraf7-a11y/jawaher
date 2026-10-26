import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:barcode_widget/barcode_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/material.dart' as m show Text;
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart' show MobileScanner;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'firebase_options.dart';


const goldKarats = [14, 18, 21, 24];
const silverKarats = [800, 900, 925];

const metalNames = {'gold': 'الذهب', 'silver': 'الفضة'};
const metalColors = {'gold': Color(0xFFB8860B), 'silver': Color(0xFF607D8B)};

List<int> karatsOf(String metal) => metal == 'gold' ? goldKarats : silverKarats;


class Item {
  final String id, metal, name, barcode, photo;
  final int karat;
  final List<double> weights; // وزن كل قطعة وقت الإدخال
  final double remaining; // المتبقي بالجرام
  final List<int> soldIdx; // أرقام القطع اللي اتباعت كاملة
  final int count; // عدد القطع المتبقي
  final bool hasCount;
  final String supplier;
  final String kind;
  Item({
    required this.id,
    required this.metal,
    required this.karat,
    required this.name,
    required this.barcode,
    required this.photo,
    required this.weights,
    required this.remaining,
    this.soldIdx = const <int>[],
    this.count = 0,
    this.hasCount = true,
    this.supplier = '',
    this.kind = 'normal',
  });

  factory Item.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data()!;
    return Item(
      id: d.id,
      metal: m['metal'],
      karat: m['karat'],
      name: m['name'] ?? '',
      barcode: m['barcode'],
      photo: m['photo'] ?? '',
      weights: List<double>.from((m['weights'] as List).map((e) => (e as num).toDouble())),
      remaining: (m['remaining'] as num).toDouble(),
      soldIdx: List<int>.from(((m['soldIdx'] ?? []) as List).map((e) => (e as num).toInt())),
      hasCount: m['count'] != null,
      supplier: '${m['supplier'] ?? ''}',
      kind: '${m['kind'] ?? 'normal'}',
      count: m['count'] != null
          ? (m['count'] as num).toInt()
          : ((m['weights'] as List).length - ((m['soldIdx'] ?? []) as List).length).clamp(0, 100000),
    );
  }

  bool get isScrap => kind == 'scrap';

  List<int> get available => [for (var n = 0; n < weights.length; n++) if (!soldIdx.contains(n)) n];

  Uint8List? get photoBytes => photo.isEmpty ? null : base64Decode(photo);
}

class Store {
  static String user = '';

  static final _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get items =>
      _db.collection('users').doc(user).collection('items');

  /// الذهب والفضة منفصلين بالـ metal
  static Stream<List<Item>> watchItems(String metal) =>
      liveQuery('items:$user:$metal', items.where('metal', isEqualTo: metal), serverSeconds: 60)
          .map((s) => s.docs.map(Item.fromDoc).toList()
            ..sort((a, b) => a.karat.compareTo(b.karat)));

  /// باركود فريد من غير نت: حرف المعدن + العيار + الوقت
  static String newBarcode(String metal, int karat) {
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase();
    return '${metal == 'gold' ? 'G' : 'S'}$karat-$t';
  }

  /// مهم: من غير await عشان الحفظ ميتعطلش لما مفيش نت.
  /// Firestore بيحفظ محلياً فوراً ويرفع لوحده لما النت يرجع.
  static void addItem({
    required String metal,
    required int karat,
    required String name,
    required String barcode,
    required String photo,
    required List<double> weights,
  }) {
    liveRefreshSoon();
    items.doc().set({
      'metal': metal,
      'karat': karat,
      'name': name,
      'barcode': barcode,
      'photo': photo,
      'weights': weights,
      'remaining': weights.fold<double>(0, (a, b) => a + b),
      'count': weights.length,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}


class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _c = TextEditingController();

  Future<void> _save() async {
    final name = _c.text.trim().toLowerCase();
    if (name.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اليوزر لازم يكون ٦ حروف على الأقل (يفضل طويل ومميز)')));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', name);
    Store.user = name;
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.diamond, size: 72, color: Color(0xFFB8860B)),
              const SizedBox(height: 16),
              const Text('اسم المستخدم', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('اكتب نفس اليوزر على الكمبيوتر والتليفون\nعشان الداتا تتشارك. مش هيتطلب تاني.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextField(
                controller: _c,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), hintText: 'مثال: elnour-gold-7391'),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: _save, child: const Text('دخول'))),
            ]),
          ),
        ),
        ),
      ),
    );
  }
}


class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Updater.check();
    });
  }

  Widget _metalCard(BuildContext context, String m) {
    final c = metalColors[m]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MetalMenuScreen(metal: m))),
        child: Container(
          height: 170,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              colors: [c, c.withAlpha(170)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [BoxShadow(color: c.withAlpha(90), blurRadius: 16, offset: const Offset(0, 8))],
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(m == 'gold' ? Icons.workspace_premium : Icons.diamond_outlined, size: 56, color: Colors.white),
                const SizedBox(height: 8),
                Text(metalNames[m]!,
                    style: const TextStyle(fontSize: 34, color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('المحل: ${Store.user}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: PageList(
            padding: const EdgeInsets.all(20),
            children: [
              _metalCard(context, 'gold'),
              _metalCard(context, 'silver'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.settings),
                  title: const Text('الإعدادات'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class InventoryScreen extends StatelessWidget {
  final String metal;
  const InventoryScreen({super.key, required this.metal});

  Widget _tile(BuildContext context, Item i) {
    return ListTile(
      leading: i.photoBytes == null
          ? const Icon(Icons.image_not_supported, size: 40)
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(i.photoBytes!, width: 50, height: 50, fit: BoxFit.cover)),
      title: Text('عيار ${i.karat}${i.name.isEmpty ? '' : ' - ${i.name}'}'),
      subtitle: Text('${i.count} قطعة | المتبقي ${money(i.remaining)} جم'),
      trailing: Text(i.barcode, textDirection: TextDirection.ltr),
      onTap: () =>
          Navigator.push(context, MaterialPageRoute(builder: (_) => ItemDetailScreen(item: i))),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  @override
  Widget build(BuildContext context) {
    final color = metalColors[metal]!;
    return Scaffold(
      appBar: AppBar(
        title: Text('مخزون ${metalNames[metal]}'),
        backgroundColor: color,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: color,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('إضافة منتج'),
        onPressed: () =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => AddItemScreen(metal: metal))),
      ),
      body: StreamBuilder<List<Item>>(
        stream: Store.watchItems(metal),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final all = snap.data!;
          if (all.isEmpty) return const Center(child: Text('مفيش منتجات لسه'));
          final scrap = all.where((i) => i.isScrap).toList();
          final normal = all.where((i) => !i.isScrap).toList();

          final cnt = <int, int>{};
          final wt = <int, double>{};
          for (final i in normal) {
            cnt[i.karat] = (cnt[i.karat] ?? 0) + i.count;
            wt[i.karat] = (wt[i.karat] ?? 0.0) + i.remaining;
          }
          final totalCount = normal.fold<int>(0, (a, i) => a + i.count);
          final totalW = normal.fold<double>(0.0, (a, i) => a + i.remaining);

          final groups = <String, List<Item>>{};
          for (final i in normal) {
            groups.putIfAbsent(i.supplier, () => <Item>[]).add(i);
          }
          final names = groups.keys.toList()..sort();

          return PageList(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('إجمالي المخزون', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text('عدد القطع: $totalCount   |   الوزن: ${money(totalW)} جم',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      const Divider(),
                      for (final k in karatsOf(metal))
                        Text('عيار $k:  ${cnt[k] ?? 0} قطعة  -  ${money(wt[k] ?? 0.0)} جم'),
                    ],
                  ),
                ),
              ),
              if (scrap.isNotEmpty)
                Card(
                  color: Colors.amber.shade50,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(14, 12, 14, 0),
                        child: Text('الكسر (بالوزن فقط)',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
                      ),
                      for (final i in scrap)
                        ListTile(
                          dense: true,
                          title: Text('عيار ${i.karat}', style: const TextStyle(color: Colors.black87)),
                          trailing: Text('${money(i.remaining)} جم',
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87)),
                          onTap: () => Navigator.push(
                              context, MaterialPageRoute(builder: (_) => ItemDetailScreen(item: i))),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                        child: Text(
                          'إجمالي الكسر: ${money(scrap.fold<double>(0.0, (a, i) => a + i.remaining))} جم',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                ),
              for (final n in names) ...[
                _header(n.isEmpty
                    ? 'مخزون عام'
                    : 'التاجر / المورد: $n  (${groups[n]!.fold<int>(0, (a, i) => a + i.count)} قطعة - ${money(groups[n]!.fold<double>(0.0, (a, i) => a + i.remaining))} جم)'),
                for (final i in groups[n]!) Card(child: _tile(context, i)),
              ],
              const SizedBox(height: 70),
            ],
          );
        },
      ),
    );
  }
}

class ItemDetailScreen extends StatefulWidget {
  final Item item;
  const ItemDetailScreen({super.key, required this.item});
  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  late String photo = widget.item.photo;
  late String name = widget.item.name;

  Item get item => widget.item;

  Future<void> _changePhoto() async {
    final p = await pickPhotoB64();
    if (p == null) return;
    Store.items.doc(item.id).update({'photo': p});
    liveRefreshSoon();
    setState(() => photo = p);
  }

  Future<void> _removePhoto() async {
    if (!await confirmDialog(context, 'حذف صورة المنتج؟')) return;
    Store.items.doc(item.id).update({'photo': ''});
    liveRefreshSoon();
    setState(() => photo = '');
  }

  Future<void> _editName() async {
    final r = await editDialog(context, 'تعديل الوصف', {'اسم / وصف المنتج': name});
    if (r == null) return;
    final v = r['اسم / وصف المنتج'] ?? '';
    Store.items.doc(item.id).update({'name': v});
    liveRefreshSoon();
    setState(() => name = v);
  }

  Future<void> _delete() async {
    if (!await confirmDialog(context,
        'مسح المنتج من المخزون؟ هيتخصم وزنه وعدده من إجمالي المخزون. (العمليات القديمة هتفضل في السجل)')) {
      return;
    }
    Store.items.doc(item.id).delete();
    liveRefreshSoon();
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final pic = photo.isEmpty ? null : base64Decode(photo);
    return Scaffold(
      appBar: AppBar(title: Text(item.isScrap ? 'كسر عيار ${item.karat}' : 'عيار ${item.karat} $name')),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          if (!item.isScrap) ...[
            Center(
              child: pic == null
                  ? const Icon(Icons.image_not_supported, size: 90)
                  : Image.memory(pic, height: 220),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _changePhoto,
                  icon: const Icon(Icons.photo_camera),
                  label: Text(pic == null ? 'إضافة صورة' : 'تغيير الصورة'),
                ),
                if (pic != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _removePhoto,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('حذف الصورة'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: BarcodeWidget(barcode: Barcode.code128(), data: item.barcode, height: 90, drawText: true),
            ),
            const SizedBox(height: 16),
          ],
          Text('المتبقي: ${money(item.remaining)} جم',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          if (!item.isScrap) Text('العدد: ${item.count} قطعة'),
          if (item.supplier.isNotEmpty) Text('التاجر / المورد: ${item.supplier}'),
          const SizedBox(height: 8),
          if (!item.isScrap)
            OutlinedButton.icon(
              onPressed: _editName,
              icon: const Icon(Icons.edit),
              label: const Text('تعديل الاسم / الوصف'),
            ),
          if (!item.isScrap) ...[
            const SizedBox(height: 12),
            const Text('أوزان القطع وقت الإدخال:'),
            for (var n = 0; n < item.weights.length; n++)
              ListTile(dense: true, title: Text('قطعة ${n + 1}'), trailing: Text('${item.weights[n]} جم')),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: _delete,
            icon: const Icon(Icons.delete),
            label: const Padding(padding: EdgeInsets.all(12), child: Text('مسح المنتج من المخزون')),
          ),
        ],
      ),
    );
  }
}

class AddItemScreen extends StatefulWidget {
  final String metal;
  const AddItemScreen({super.key, required this.metal});
  @override
  State<AddItemScreen> createState() => _AddItemScreenState();
}

class _AddItemScreenState extends State<AddItemScreen> {
  late int karat = karatsOf(widget.metal).first;
  final _name = TextEditingController();
  final _count = TextEditingController(text: '1');
  List<TextEditingController> _weights = [TextEditingController()];
  String _photo = '';
  bool _saved = false;
  late String _barcode = Store.newBarcode(widget.metal, karat);

  Future<void> _pickPhoto() async {
    final src = Platform.isAndroid || Platform.isIOS ? ImageSource.camera : ImageSource.gallery;
    final f = await ImagePicker().pickImage(source: src);
    if (f == null) return;
    final decoded = img.decodeImage(await f.readAsBytes());
    if (decoded == null) return;
    // نصغّر الصورة عشان تتزامن بين الأجهزة
    final small = img.copyResize(decoded, width: 400);
    setState(() => _photo = base64Encode(img.encodeJpg(small, quality: 70)));
  }

  void _onCount(String v) {
    final n = (int.tryParse(v) ?? 1).clamp(1, 200);
    setState(() {
      while (_weights.length < n) {
        _weights.add(TextEditingController());
      }
      _weights = _weights.sublist(0, n);
    });
  }

  void _save() {
    if (_saved) return;
    final ws = <double>[];
    for (final c in _weights) {
      final w = double.tryParse(c.text.trim().replaceAll(',', '.'));
      if (w == null || w <= 0) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('اكتب وزن كل القطع (أرقام أكبر من صفر)')));
        return;
      }
      ws.add(w);
    }
    Store.addItem(
      metal: widget.metal,
      karat: karat,
      name: _name.text.trim(),
      barcode: _barcode,
      photo: _photo,
      weights: ws,
    );
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ المنتج')));
  }

  void _newOp() => setState(() {
        _name.clear();
        _count.text = '1';
        _weights = [TextEditingController()];
        _photo = '';
        _barcode = Store.newBarcode(widget.metal, karat);
        _saved = false;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('إضافة منتج ${metalNames[widget.metal]}')),
      body: PageList(padding: const EdgeInsets.all(16), children: [
        Center(
          child: InkWell(
            onTap: _pickPhoto,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(border: Border.all(), borderRadius: BorderRadius.circular(8)),
              child: _photo.isEmpty
                  ? const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.camera_alt, size: 40),
                      Text('تصوير المنتج'),
                    ])
                  : Image.memory(base64Decode(_photo), fit: BoxFit.cover),
            ),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          value: karat,
          decoration: const InputDecoration(label: Text('العيار'), border: OutlineInputBorder()),
          items: [for (final k in karatsOf(widget.metal)) DropdownMenuItem(value: k, child: Text('عيار $k'))],
          onChanged: (v) => setState(() {
            karat = v!;
            _barcode = Store.newBarcode(widget.metal, karat);
          }),
        ),
        const SizedBox(height: 12),
        TextField(
            controller: _name,
            decoration: const InputDecoration(label: Text('وصف (اختياري) مثال: خاتم'), border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(
          controller: _count,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(label: Text('العدد'), border: OutlineInputBorder()),
          onChanged: _onCount,
        ),
        const SizedBox(height: 12),
        for (var n = 0; n < _weights.length; n++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: _weights[n],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(label: Text('وزن القطعة ${n + 1} (جرام)'), border: const OutlineInputBorder()),
            ),
          ),
        const SizedBox(height: 8),
        const Text('الباركود الخاص بالمنتج:'),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(8),
          child: BarcodeWidget(barcode: Barcode.code128(), data: _barcode, height: 70),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saved ? null : _save,
          child: Padding(padding: const EdgeInsets.all(12), child: Text(_saved ? 'تم الحفظ ✓' : 'حفظ')),
        ),
        if (_saved)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              onPressed: _newOp,
              icon: const Icon(Icons.refresh),
              label: const Text('منتج جديد'),
            ),
          ),
      ]),
    );
  }
}



Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? startupError;
  bool loggedIn = false;
  try {
    await Prefs.load();
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
        .timeout(const Duration(seconds: 25));
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
    final prefs = await SharedPreferences.getInstance();
    final user = prefs.getString('username');
    if (user != null) Store.user = user;
    loggedIn = user != null;
  } catch (e) {
    startupError = '$e';
  }
  runApp(startupError != null ? ErrorApp(message: startupError) : App(loggedIn: loggedIn));
}

/// بتظهر لو حصل خطأ وقت تشغيل البرنامج، بدل ما يقفل من غير ما نعرف السبب
class ErrorApp extends StatelessWidget {
  final String message;
  const ErrorApp({super.key, required this.message});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const m.Text('Startup error')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Directionality(textDirection: TextDirection.ltr, child: SelectableText(message)),
        ),
      ),
    );
  }
}

class App extends StatelessWidget {
  final bool loggedIn;
  const App({super.key, required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appLang,
      builder: (context, lang, _) => ValueListenableBuilder<bool>(
        valueListenable: appDark,
        builder: (context, dark, _) => MaterialApp(
          navigatorKey: navKey,
          scrollBehavior: const AppScrollBehavior(),
          title: 'Jawaher',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(false),
          darkTheme: buildTheme(true),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          builder: (c, child) {
            return Directionality(
              textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (ctx, cons) => cons.maxWidth > 900
                        ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: child!))
                        : child!,
                  ),
                  PositionedDirectional(
                    top: MediaQuery.of(c).padding.top + 4,
                    end: 6,
                    child: const Material(type: MaterialType.transparency, child: TopTools()),
                  ),
                ],
              ),
            );
          },
          home: loggedIn ? const HomeScreen() : const LoginScreen(),
        ),
      ),
    );
  }
}

// ======================= المرحلة 2: بيع / شراء / سجل =======================

String _two(int n) => n.toString().padLeft(2, '0');
String fmtDate(Timestamp t) {
  final d = t.toDate();
  return '${d.year}-${_two(d.month)}-${_two(d.day)}  ${_two(d.hour)}:${_two(d.minute)}';
}

double? parseNum(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));
String money(double v) => v.toStringAsFixed(2);
double nd(dynamic v) => (v as num).toDouble();

Future<String?> pickPhotoB64() async {
  final src = Platform.isAndroid || Platform.isIOS ? ImageSource.camera : ImageSource.gallery;
  final f = await ImagePicker().pickImage(source: src);
  if (f == null) return null;
  final decoded = img.decodeImage(await f.readAsBytes());
  if (decoded == null) return null;
  return base64Encode(img.encodeJpg(img.copyResize(decoded, width: 400), quality: 70));
}

Widget tf(String label, TextEditingController c,
    {TextInputType type = const TextInputType.numberWithOptions(decimal: true), VoidCallback? onChanged}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      keyboardType: type,
      decoration: InputDecoration(label: Text(label), border: const OutlineInputBorder()),
      onChanged: (_) => onChanged?.call(),
    ),
  );
}

/// عمليات البيع والشراء. بنستخدم batch من غير await عشان تشتغل من غير نت.
/// 'pc' للكمبيوتر و 'phone' للتليفون. عمليات التليفون مبتظهرش على الكمبيوتر.
final String deviceKind =
    (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ? 'pc' : 'phone';

Object _cnt(Item it, int delta) => it.hasCount ? FieldValue.increment(delta) : it.count + delta;

class SaleLine {
  final Item item;
  final double weight;
  final int count;
  final List<int> pieces;
  final double pricePerGram;
  final double fee;
  const SaleLine({
    required this.item,
    required this.weight,
    required this.count,
    required this.pieces,
    required this.pricePerGram,
    required this.fee,
  });
  double get total => weight * pricePerGram + fee;
}

class BuyLine {
  final Item? existing;
  final int karat;
  final String barcode, photo, desc;
  final double weight;
  final int count;
  final double price;
  final bool scrap;
  const BuyLine({
    required this.existing,
    required this.karat,
    required this.barcode,
    required this.photo,
    required this.desc,
    required this.weight,
    required this.count,
    required this.price,
    this.scrap = false,
  });
}

Item? _find(List<Item> items, String id) {
  for (final i in items) {
    if (i.id == id) return i;
  }
  return null;
}

class Ops {
  static CollectionReference<Map<String, dynamic>> col(String name) =>
      FirebaseFirestore.instance.collection('users').doc(Store.user).collection(name);

  static Query<Map<String, dynamic>> _ops(String name, String metal) {
    final q = col(name).where('metal', isEqualTo: metal);
    // الكمبيوتر بيشوف عملياته هو بس. التليفون بيشوف كل العمليات.
    return deviceKind == 'pc' ? q.where('device', isEqualTo: 'pc') : q;
  }

  static Stream<List<Map<String, dynamic>>> watch(String name, String metal) =>
      liveQuery('$name:${Store.user}:$metal:$deviceKind', _ops(name, metal), serverSeconds: 180)
          .map((s) {
        final l = s.docs.map((d) => <String, dynamic>{...d.data(), 'id': d.id}).toList();
        l.sort((a, b) => (b['ts'] as Timestamp).compareTo(a['ts'] as Timestamp));
        return l;
      });

  static DocumentReference<Map<String, dynamic>> _serialRef(String metal, String kind) =>
      col('meta').doc('serial-$kind-$metal-$deviceKind');

  /// رقم تسلسلي لكل فاتورة: حرف المعدن + حرف الجهاز (P كمبيوتر / M تليفون) + رقم
  static Future<(String, int)> _nextSerial(String metal, String kind) async {
    var n = 0;
    try {
      final s = await _serialRef(metal, kind).get().timeout(const Duration(seconds: 4));
      n = (s.data()?['n'] as num?)?.toInt() ?? 0;
    } catch (_) {
      n = (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 100000;
    }
    final serial =
        '${metal == 'gold' ? 'G' : 'S'}${deviceKind == 'pc' ? 'P' : 'M'}${kind == 'buy' ? 'R' : ''}-${(n + 1).toString().padLeft(6, '0')}';
    return (serial, n + 1);
  }

  /// عملية بيع واحدة فيها أكتر من منتج
  static Future<Map<String, dynamic>> sellMulti({
    required String metal,
    required List<SaleLine> lines,
    required double paid,
    required String customerName,
    required String customerPhone,
    String payMethod = 'cash',
  }) async {
    final serial = await _nextSerial(metal, 'sale');
    final batch = FirebaseFirestore.instance.batch();
    var total = 0.0, fee = 0.0, weight = 0.0;
    var count = 0;
    final maps = <Map<String, dynamic>>[];
    for (final l in lines) {
      batch.update(Store.items.doc(l.item.id), {
        'remaining': FieldValue.increment(-l.weight),
        'count': _cnt(l.item, -l.count),
        if (l.pieces.isNotEmpty) 'soldIdx': FieldValue.arrayUnion(l.pieces),
      });
      total += l.total;
      fee += l.fee;
      weight += l.weight;
      count += l.count;
      maps.add({
        'itemId': l.item.id,
        'barcode': l.item.barcode,
        'karat': l.item.karat,
        'weight': l.weight,
        'count': l.count,
        'pieces': l.pieces,
        'pricePerGram': l.pricePerGram,
        'fee': l.fee,
        'total': l.total,
      });
    }
    final doc = <String, dynamic>{
      'serial': serial.$1,
      'payMethod': payMethod,
      'metal': metal,
      'lines': maps,
      'weight': weight,
      'count': count,
      'fee': fee,
      'total': total,
      'paid': paid,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'ts': Timestamp.now(),
      'device': deviceKind,
    };
    batch.set(col('sales').doc(), doc);
    batch.set(_serialRef(metal, 'sale'), {'n': serial.$2});
    batch.commit();
    liveRefreshSoon();
    return doc;
  }

  /// عملية شراء واحدة فيها أكتر من منتج (قديم أو جديد أو كسر)، ممكن تكون من تاجر/مورد
  static Future<Map<String, dynamic>> buyMulti({
    required String metal,
    required List<BuyLine> lines,
    required double paid,
    required String customerName,
    required String customerPhone,
    String supplier = '',
    String payMethod = 'cash',
  }) async {
    final serial = await _nextSerial(metal, 'buy');
    final batch = FirebaseFirestore.instance.batch();
    var price = 0.0, weight = 0.0;
    var count = 0;
    final maps = <Map<String, dynamic>>[];
    for (final l in lines) {
      if (l.scrap) {
        // الكسر: خانة واحدة لكل عيار، بالوزن بس
        final ref = Store.items.doc('scrap-$metal-${l.karat}');
        batch.set(
          ref,
          {
            'metal': metal,
            'karat': l.karat,
            'kind': 'scrap',
            'name': 'كسر',
            'barcode': 'SCRAP-$metal-${l.karat}',
            'photo': '',
            'weights': <double>[],
            'count': 0,
            'remaining': FieldValue.increment(l.weight),
          },
          SetOptions(merge: true),
        );
        price += l.price;
        weight += l.weight;
        maps.add({
          'itemId': ref.id,
          'barcode': 'SCRAP-$metal-${l.karat}',
          'karat': l.karat,
          'weight': l.weight,
          'count': 0,
          'price': l.price,
          'newItem': false,
          'scrap': true,
          'pieceIdx': <int>[],
        });
        continue;
      }
      final ex = l.existing;
      final ref = ex != null ? Store.items.doc(ex.id) : Store.items.doc();
      final newWeights = List<double>.filled(l.count, l.weight / l.count);
      final start = ex != null ? ex.weights.length : 0;
      if (ex != null) {
        batch.update(ref, {
          'remaining': FieldValue.increment(l.weight),
          'count': _cnt(ex, l.count),
          'weights': [...ex.weights, ...newWeights],
        });
      } else {
        batch.set(ref, {
          'metal': metal,
          'karat': l.karat,
          'name': l.desc,
          'barcode': l.barcode,
          'photo': l.photo,
          'weights': newWeights,
          'remaining': l.weight,
          'count': l.count,
          'supplier': supplier,
          'kind': 'normal',
          'createdAt': Timestamp.now(),
        });
      }
      price += l.price;
      weight += l.weight;
      count += l.count;
      maps.add({
        'itemId': ref.id,
        'barcode': l.barcode,
        'karat': l.karat,
        'weight': l.weight,
        'count': l.count,
        'price': l.price,
        'newItem': ex == null,
        'pieceIdx': [for (var i = 0; i < l.count; i++) start + i],
      });
    }
    final doc = <String, dynamic>{
      'serial': serial.$1,
      'payMethod': payMethod,
      'metal': metal,
      'lines': maps,
      'weight': weight,
      'count': count,
      'price': price,
      'paid': paid,
      'supplier': supplier,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'ts': Timestamp.now(),
      'device': deviceKind,
    };
    batch.set(col('purchases').doc(), doc);
    batch.set(_serialRef(metal, 'buy'), {'n': serial.$2});
    batch.commit();
    liveRefreshSoon();
    return doc;
  }

  static void addPayment({
    required String metal,
    required String kind, // sale | purchase
    required String refId,
    required double amount,
    required String customerName,
    required String customerPhone,
  }) {
    liveRefreshSoon();
    col('payments').doc().set({
      'metal': metal,
      'kind': kind,
      'refId': refId,
      'amount': amount,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'ts': Timestamp.now(),
      'device': deviceKind,
    });
  }

  static void addExpense({
    required String metal,
    required String type, // expense | salary
    required String title,
    required double amount,
  }) {
    liveRefreshSoon();
    col('expenses').doc().set({
      'metal': metal,
      'type': type,
      'title': title,
      'amount': amount,
      'ts': Timestamp.now(),
      'device': deviceKind,
    });
  }

  static void deleteSale(Map<String, dynamic> m, List<String> paymentIds, List<Item> items) {
    final b = FirebaseFirestore.instance.batch();
    for (final l in linesOf(m, true)) {
      final pieces = ((l['pieces'] ?? []) as List).map((e) => (e as num).toInt()).toList();
      final n = (l['count'] as num?)?.toInt() ?? pieces.length;
      final id = l['itemId'] as String;
      final it = _find(items, id);
      if (it != null) b.update(Store.items.doc(id), {
        'remaining': FieldValue.increment(nd(l['weight'])),
        'count': it != null ? _cnt(it, n) : FieldValue.increment(n),
        if (pieces.isNotEmpty) 'soldIdx': FieldValue.arrayRemove(pieces),
      });
    }
    b.delete(col('sales').doc(m['id'] as String));
    for (final id in paymentIds) {
      b.delete(col('payments').doc(id));
    }
    b.commit();
    liveRefreshSoon();
  }

  static void deletePurchase(Map<String, dynamic> m, List<String> paymentIds, List<Item> items) {
    final b = FirebaseFirestore.instance.batch();
    for (final l in linesOf(m, false)) {
      final raw = l['pieceIdx'];
      final List<int> idxs = raw is List
          ? raw.map((e) => (e as num).toInt()).toList()
          : (raw is num ? <int>[raw.toInt()] : <int>[]);
      final n = (l['count'] as num?)?.toInt() ?? 1;
      final id = l['itemId'] as String;
      final it = _find(items, id);
      if (it != null) b.update(Store.items.doc(id), {
        'remaining': FieldValue.increment(-nd(l['weight'])),
        'count': it != null ? _cnt(it, -n) : FieldValue.increment(-n),
        if (idxs.isNotEmpty) 'soldIdx': FieldValue.arrayUnion(idxs),
      });
    }
    b.delete(col('purchases').doc(m['id'] as String));
    for (final id in paymentIds) {
      b.delete(col('payments').doc(id));
    }
    b.commit();
    liveRefreshSoon();
  }

  static void convert({
    required String metal,
    required Item from,
    required double weight,
    required int count,
    required int toKarat,
    Item? to,
    required double toWeight,
  }) {
    final b = FirebaseFirestore.instance.batch();
    b.update(Store.items.doc(from.id), {
      'remaining': FieldValue.increment(-weight),
      'count': _cnt(from, -count),
    });
    final newWeights = List<double>.filled(count, toWeight / count);
    final String toBarcode;
    if (to != null) {
      toBarcode = to.barcode;
      b.update(Store.items.doc(to.id), {
        'remaining': FieldValue.increment(toWeight),
        'count': _cnt(to, count),
        'weights': [...to.weights, ...newWeights],
      });
    } else {
      toBarcode = Store.newBarcode(metal, toKarat);
      b.set(Store.items.doc(), {
        'metal': metal,
        'karat': toKarat,
        'name': 'محوّل من عيار ${from.karat}',
        'barcode': toBarcode,
        'photo': '',
        'weights': newWeights,
        'remaining': toWeight,
        'count': count,
        'createdAt': Timestamp.now(),
      });
    }
    b.set(col('conversions').doc(), {
      'metal': metal,
      'fromKarat': from.karat,
      'toKarat': toKarat,
      'fromWeight': weight,
      'toWeight': toWeight,
      'count': count,
      'fromBarcode': from.barcode,
      'toBarcode': toBarcode,
      'ts': Timestamp.now(),
      'device': deviceKind,
    });
    b.commit();
    liveRefreshSoon();
  }
}

class MetalMenuScreen extends StatelessWidget {
  final String metal;
  const MetalMenuScreen({super.key, required this.metal});

  @override
  Widget build(BuildContext context) {
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    final tiles = <(IconData, String, Widget)>[
      (Icons.inventory_2, 'المخزون', InventoryScreen(metal: metal)),
      (Icons.sell, 'بيع', SellScreen(metal: metal)),
      (Icons.shopping_cart_checkout, 'شراء', BuyScreen(metal: metal)),
      (Icons.receipt_long, 'سجل العمليات', HistoryScreen(metal: metal)),
      (Icons.bar_chart, 'التقارير', ReportsScreen(metal: metal)),
      (Icons.people, 'العملاء والمديونيات', CustomersScreen(metal: metal)),
      (Icons.store, 'التجار والموردين', SuppliersScreen(metal: metal)),
      (Icons.insights, 'الإحصائيات', StatsScreen(metal: metal)),
      (Icons.payments, 'مصاريف وقبض العاملين', ExpensesScreen(metal: metal)),
      (Icons.swap_horiz, 'تحويل بين العيارات', ConvertScreen(metal: metal)),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(metalNames[metal]!),
        backgroundColor: metalColors[metal],
        foregroundColor: Colors.white,
      ),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          for (final t in tiles)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                leading: Icon(t.$1, size: 34, color: metalColors[metal]),
                title: Text(t.$2, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => go(t.$3),
              ),
            ),
        ],
      ),
    );
  }
}

class ItemPicker extends StatelessWidget {
  final String metal;
  final ValueChanged<Item> onSelected;
  final bool autofocus;
  const ItemPicker({super.key, required this.metal, required this.onSelected, this.autofocus = false});

  Widget _thumb(Item i) => i.photoBytes == null
      ? const Icon(Icons.diamond, size: 40)
      : ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(i.photoBytes!, width: 48, height: 48, fit: BoxFit.cover),
        );

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Item>>(
      stream: Store.watchItems(metal),
      builder: (context, snap) {
        final items = (snap.data ?? <Item>[]).where((i) => !i.isScrap).toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Autocomplete<Item>(
            displayStringForOption: (i) => i.barcode,
            optionsBuilder: (v) {
              final tokens = v.text
                  .trim()
                  .toUpperCase()
                  .split(RegExp(r'\s+'))
                  .where((t) => t.isNotEmpty)
                  .toList();
              return items.where((i) {
                final hay = '${i.barcode} ${i.name} ${i.karat}'.toUpperCase();
                return tokens.every((t) => hay.contains(t));
              });
            },
            onSelected: onSelected,
            fieldViewBuilder: (ctx, ctrl, focus, submit) => TextField(
              controller: ctrl,
              focusNode: focus,
              autofocus: autofocus,
              textDirection: TextDirection.ltr,
              onChanged: (v) {
                final t = v.trim().toUpperCase();
                for (final i in items) {
                  if (i.barcode.toUpperCase() == t) {
                    onSelected(i);
                    break;
                  }
                }
              },
              decoration: InputDecoration(
                label: Text('الباركود أو الاسم (اكتب أو امسح أو اختار)'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.qr_code),
                suffixIcon: (Platform.isAndroid || Platform.isIOS)
                    ? IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        onPressed: () async {
                          final code = await Navigator.push<String>(
                              context, MaterialPageRoute(builder: (_) => const ScanScreen()));
                          if (code == null || !context.mounted) return;
                          final t = code.trim().toUpperCase();
                          final found = items.where((i) => i.barcode.toUpperCase() == t).toList();
                          if (found.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('مفيش منتج بالباركود ده')));
                          } else {
                            ctrl.text = found.first.barcode;
                            onSelected(found.first);
                          }
                        },
                      )
                    : null,
              ),
            ),
            optionsViewBuilder: (ctx, onSel, opts) => Align(
              alignment: Alignment.topRight,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300, maxWidth: 360),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final i in opts)
                        ListTile(
                          leading: _thumb(i),
                          title: Text(i.barcode, textDirection: TextDirection.ltr),
                          subtitle: Text(
                              'عيار ${i.karat}${i.name.isEmpty ? '' : ' - ${i.name}'} | المتبقي ${money(i.remaining)} جم | العدد ${i.count}'),
                          onTap: () => onSel(i),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool done = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('امسح الباركود')),
      body: MobileScanner(
        onDetect: (capture) {
          if (done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && v.isNotEmpty) {
              done = true;
              Navigator.pop(context, v);
              return;
            }
          }
        },
      ),
    );
  }
}

class ItemInfo extends StatelessWidget {
  final Item item;
  const ItemInfo(this.item, {super.key});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: item.photoBytes == null
            ? const Icon(Icons.diamond)
            : Image.memory(item.photoBytes!, width: 50, height: 50, fit: BoxFit.cover),
        title: Text('عيار ${item.karat}${item.name.isEmpty ? '' : ' - ${item.name}'}'),
        subtitle: Text('المتبقي: ${money(item.remaining)} جم | العدد: ${item.count}'),
      ),
    );
  }
}

Widget payMethodField(String value, ValueChanged<String> onChanged) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String>(
      value: value,
      decoration: const InputDecoration(label: Text('طريقة الدفع'), border: OutlineInputBorder()),
      items: const [
        DropdownMenuItem(value: 'cash', child: Text('كاش')),
        DropdownMenuItem(value: 'instapay', child: Text('انستا باي')),
        DropdownMenuItem(value: 'visa', child: Text('فيزا')),
      ],
      onChanged: (v) => onChanged(v ?? 'cash'),
    ),
  );
}

String payLabel(dynamic v) => v == 'instapay' ? 'انستا باي' : (v == 'visa' ? 'فيزا' : 'كاش');

class SellScreen extends StatefulWidget {
  final String metal;
  const SellScreen({super.key, required this.metal});
  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  final cart = <SaleLine>[];
  Item? item;
  final w = TextEditingController();
  final cnt = TextEditingController(text: '1');
  final price = TextEditingController();
  final fee = TextEditingController();
  final paid = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  bool feePerGram = true;
  bool byPiece = false;
  final Set<int> picked = {};
  int gen = 0;
  bool saved = false;
  String payMethod = 'cash';
  Map<String, dynamic>? lastOp;

  double get weight => byPiece
      ? picked.fold<double>(0.0, (a, n) => a + (item?.weights[n] ?? 0.0))
      : (parseNum(w) ?? 0.0);
  int get count => byPiece ? picked.length : (int.tryParse(cnt.text.trim()) ?? 0);
  double get feeTotal => (parseNum(fee) ?? 0.0) * (feePerGram ? weight : 1.0);
  double get lineTotal => weight * (parseNum(price) ?? 0.0) + feeTotal;
  double get cartTotal => cart.fold<double>(0.0, (a, l) => a + l.total);
  double get cartFee => cart.fold<double>(0.0, (a, l) => a + l.fee);

  void _msg(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void addLine() {
    if (saved) return _msg('العملية اتحفظت، اضغط "عملية جديدة" لو عايز تسجل واحدة تانية');
    final it = item;
    if (it == null) return _msg('اختار المنتج بالباركود');
    if (cart.any((l) => l.item.id == it.id)) return _msg('المنتج ده مضاف بالفعل في العملية');
    if (byPiece && picked.isEmpty) return _msg('اختار القطع اللي اتباعت');
    final wt = weight;
    final cn = count;
    if (wt <= 0 || cn <= 0) return _msg('اكتب الوزن والعدد');
    if (wt > it.remaining + 0.0001 || cn > it.count) {
      return _msg('لا يوجد رصيد كافي (المتاح: ${money(it.remaining)} جم و ${it.count} قطعة)');
    }
    final p = parseNum(price);
    if (p == null || p <= 0) return _msg('اكتب سعر الجرام');
    cart.add(SaleLine(
      item: it,
      weight: wt,
      count: cn,
      pieces: byPiece ? (picked.toList()..sort()) : <int>[],
      pricePerGram: p,
      fee: feeTotal,
    ));
    setState(() {
      item = null;
      picked.clear();
      w.clear();
      cnt.text = '1';
      gen++;
    });
  }

  Future<void> confirm() async {
    if (saved) return _msg('العملية اتحفظت، اضغط "عملية جديدة" لو عايز تسجل واحدة تانية');
    if (item != null) return _msg('اضغط "إضافة للعملية" الأول عشان المنتج المختار يتحسب');
    if (cart.isEmpty) return _msg('ضيف منتج واحد على الأقل');
    final t = cartTotal;
    final pd = paid.text.trim().isEmpty ? t : (parseNum(paid) ?? -1.0);
    if (pd < 0 || pd > t + 0.005) return _msg('المبلغ المدفوع غير صحيح');
    if (pd < t - 0.005 && name.text.trim().isEmpty && phone.text.trim().isEmpty) {
      return _msg('في حالة الدفع الجزئي لازم اسم أو رقم العميل');
    }
    final n = cart.length;
    final op = await Ops.sellMulti(
      metal: widget.metal,
      lines: List<SaleLine>.of(cart),
      paid: pd,
      customerName: name.text.trim(),
      customerPhone: phone.text.trim(),
      payMethod: payMethod,
    );
    setState(() {
      saved = true;
      lastOp = op;
    });
    _msg('تم البيع ($n منتج). الإجمالي ${money(t)}');
  }

  void newOp() => setState(() {
        cart.clear();
        item = null;
        picked.clear();
        w.clear();
        cnt.text = '1';
        paid.clear();
        name.clear();
        phone.clear();
        gen++;
        saved = false;
        lastOp = null;
      });

  @override
  Widget build(BuildContext context) {
    final it = item;
    return Scaffold(
      appBar: AppBar(title: Text('بيع ${metalNames[widget.metal]}')),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('إضافة منتج للعملية', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ItemPicker(
            key: ValueKey(gen),
            metal: widget.metal,
            autofocus: true,
            onSelected: (i) => setState(() {
              item = i;
              picked.clear();
            }),
          ),
          if (it != null) ItemInfo(it),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('بيع بالجرام')),
              ButtonSegment(value: true, label: Text('بيع بالقطعة')),
            ],
            selected: {byPiece},
            onSelectionChanged: (s) => setState(() => byPiece = s.first),
          ),
          const SizedBox(height: 12),
          if (!byPiece) ...[
            tf('الوزن المباع (جرام)', w, onChanged: () => setState(() {})),
            tf('العدد المباع (قطعة)', cnt, type: TextInputType.number, onChanged: () => setState(() {})),
          ] else if (it == null)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('اختار المنتج الأول عشان تظهر قطعه'),
            )
          else if (it.available.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('مفيش قطع متاحة، استخدم البيع بالجرام'),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final n in it.available)
                    CheckboxListTile(
                      dense: true,
                      value: picked.contains(n),
                      title: Text('قطعة ${n + 1} - ${money(it.weights[n])} جم'),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          picked.add(n);
                        } else {
                          picked.remove(n);
                        }
                      }),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text('المحدد: ${picked.length} قطعة = ${money(weight)} جم'),
                  ),
                ],
              ),
            ),
          tf('سعر الجرام', price, onChanged: () => setState(() {})),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('مصنعية للجرام')),
              ButtonSegment(value: false, label: Text('مصنعية إجمالية')),
            ],
            selected: {feePerGram},
            onSelectionChanged: (s) => setState(() => feePerGram = s.first),
          ),
          const SizedBox(height: 12),
          tf(feePerGram ? 'المصنعية لكل جرام' : 'المصنعية الإجمالية', fee, onChanged: () => setState(() {})),
          Text('سعر المنتج ده: ${money(lineTotal)} (مصنعية ${money(feeTotal)})'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: addLine,
            icon: const Icon(Icons.add),
            label: const Text('إضافة للعملية'),
          ),
          const Divider(height: 32),
          Text('المنتجات في العملية (${cart.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (cart.isEmpty) const Text('لسه مفيش منتجات'),
          for (final l in cart)
            Card(
              child: ListTile(
                title: Text('عيار ${l.item.karat} - ${l.item.barcode}', textDirection: TextDirection.ltr),
                subtitle: Text(
                    '${money(l.weight)} جم | ${l.count} قطعة | سعر الجرام ${money(l.pricePerGram)} | مصنعية ${money(l.fee)}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(money(l.total), style: const TextStyle(fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: saved ? null : () => setState(() => cart.remove(l)),
                    ),
                  ],
                ),
              ),
            ),
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('مجمل المصنعية: ${money(cartFee)}'),
                  const SizedBox(height: 4),
                  Text('مجمل السعر: ${money(cartTotal)}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          payMethodField(payMethod, (v) => setState(() => payMethod = v)),
          tf('المبلغ المدفوع (سيبه فاضي لو دفع كامل)', paid),
          tf('اسم العميل (اختياري)', name, type: TextInputType.text),
          tf('رقم العميل (اختياري)', phone, type: TextInputType.phone),
          FilledButton(
            onPressed: saved ? null : confirm,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(saved ? 'تم الحفظ ✓' : 'تأكيد البيع'),
            ),
          ),
          if (saved && lastOp != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => InvoiceScreen(op: lastOp!, isSale: true)),
                ),
                icon: const Icon(Icons.print),
                label: const Text('طباعة الفاتورة'),
              ),
            ),
          if (saved)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: newOp,
                icon: const Icon(Icons.refresh),
                label: const Text('عملية جديدة'),
              ),
            ),
        ],
      ),
    );
  }
}

class BuyScreen extends StatefulWidget {
  final String metal;
  const BuyScreen({super.key, required this.metal});
  @override
  State<BuyScreen> createState() => _BuyScreenState();
}

class _BuyScreenState extends State<BuyScreen> {
  final cart = <BuyLine>[];
  int mode = 0; // 0 منتج قديم، 1 منتج جديد، 2 كسر
  Item? old;
  late int karat = karatsOf(widget.metal).first;
  late String barcode = Store.newBarcode(widget.metal, karat);
  String photo = '';
  int gen = 0;
  bool saved = false;
  String payMethod = 'cash';
  Map<String, dynamic>? lastOp;
  final desc = TextEditingController();
  final w = TextEditingController();
  final cnt = TextEditingController(text: '1');
  final price = TextEditingController();
  final paid = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  final supplier = TextEditingController();

  void _msg(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  double get cartTotal => cart.fold<double>(0.0, (a, l) => a + l.price);

  double get debt {
    final pr = cartTotal;
    final pd = paid.text.trim().isEmpty ? pr : (parseNum(paid) ?? 0.0);
    return pr - pd;
  }

  void addLine() {
    if (saved) return _msg('العملية اتحفظت، اضغط "عملية جديدة" لو عايز تسجل واحدة تانية');
    final o = old;
    if (mode == 0 && o == null) return _msg('اختار المنتج القديم بالباركود أو الاسم');
    if (mode == 0 && o != null && cart.any((l) => l.existing?.id == o.id)) {
      return _msg('المنتج ده مضاف بالفعل في العملية');
    }
    if (mode == 2 && cart.any((l) => l.scrap && l.karat == karat)) {
      return _msg('الكسر لنفس العيار مضاف بالفعل، عدّل وزنه أو امسحه');
    }
    final wt = parseNum(w);
    if (wt == null || wt <= 0) return _msg('اكتب الوزن');
    final cn = mode == 2 ? 0 : (int.tryParse(cnt.text.trim()) ?? 0);
    if (mode != 2 && cn <= 0) return _msg('اكتب العدد');
    final pr = parseNum(price);
    if (pr == null || pr <= 0) return _msg('اكتب سعر الشراء للمنتج ده');
    cart.add(BuyLine(
      existing: mode == 0 ? o : null,
      karat: mode == 0 ? o!.karat : karat,
      barcode: mode == 0 ? o!.barcode : (mode == 2 ? 'SCRAP-${widget.metal}-$karat' : barcode),
      photo: mode == 1 ? photo : '',
      desc: desc.text.trim(),
      weight: wt,
      count: cn,
      price: pr,
      scrap: mode == 2,
    ));
    setState(() {
      old = null;
      photo = '';
      desc.clear();
      w.clear();
      cnt.text = '1';
      price.clear();
      barcode = Store.newBarcode(widget.metal, karat);
      gen++;
    });
  }

  Future<void> confirm() async {
    if (saved) return _msg('العملية اتحفظت، اضغط "عملية جديدة" لو عايز تسجل واحدة تانية');
    if (old != null || w.text.trim().isNotEmpty) {
      return _msg('اضغط "إضافة للعملية" الأول عشان المنتج المكتوب يتحسب');
    }
    if (cart.isEmpty) return _msg('ضيف منتج واحد على الأقل');
    final sup = supplier.text.trim();
    final pr = cartTotal;
    final pd = paid.text.trim().isEmpty ? pr : (parseNum(paid) ?? -1.0);
    if (pd < 0 || pd > pr + 0.005) return _msg('المبلغ المدفوع غير صحيح');
    if (pd < pr - 0.005 && sup.isEmpty && name.text.trim().isEmpty && phone.text.trim().isEmpty) {
      return _msg('في حالة الدفع الجزئي لازم اسم التاجر أو اسم أو رقم العميل');
    }
    final n = cart.length;
    final op = await Ops.buyMulti(
      metal: widget.metal,
      lines: List<BuyLine>.of(cart),
      paid: pd,
      customerName: sup.isNotEmpty ? sup : name.text.trim(),
      customerPhone: sup.isNotEmpty ? '' : phone.text.trim(),
      supplier: sup,
      payMethod: payMethod,
    );
    final owe = pr - pd;
    setState(() {
      saved = true;
      lastOp = op;
    });
    _msg(owe > 0.005 ? 'تم التسجيل ($n منتج). عليا مديونية ${money(owe)}' : 'تم التسجيل ($n منتج)');
  }

  void newOp() => setState(() {
        cart.clear();
        old = null;
        photo = '';
        desc.clear();
        w.clear();
        cnt.text = '1';
        price.clear();
        paid.clear();
        name.clear();
        phone.clear();
        supplier.clear();
        barcode = Store.newBarcode(widget.metal, karat);
        gen++;
        saved = false;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('شراء ${metalNames[widget.metal]}')),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('إضافة منتج للعملية', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('منتج قديم')),
              ButtonSegment(value: 1, label: Text('منتج جديد')),
              ButtonSegment(value: 2, label: Text('كسر')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setState(() => mode = s.first),
          ),
          const SizedBox(height: 16),
          if (mode == 0) ...[
            ItemPicker(
              key: ValueKey(gen),
              metal: widget.metal,
              autofocus: true,
              onSelected: (i) => setState(() => old = i),
            ),
            if (old != null) ItemInfo(old!),
          ] else if (mode == 1) ...[
            Center(
              child: InkWell(
                onTap: () async {
                  final p = await pickPhotoB64();
                  if (p != null) setState(() => photo = p);
                },
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(border: Border.all(), borderRadius: BorderRadius.circular(8)),
                  child: photo.isEmpty
                      ? const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [Icon(Icons.camera_alt, size: 36), Text('تصوير المنتج')],
                        )
                      : Image.memory(base64Decode(photo), fit: BoxFit.cover),
                ),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: karat,
              decoration: const InputDecoration(label: Text('العيار'), border: OutlineInputBorder()),
              items: [
                for (final k in karatsOf(widget.metal))
                  DropdownMenuItem(value: k, child: Text('عيار $k')),
              ],
              onChanged: (v) => setState(() {
                karat = v!;
                barcode = Store.newBarcode(widget.metal, karat);
              }),
            ),
            const SizedBox(height: 12),
            tf('وصف / اسم المنتج (اختياري)', desc, type: TextInputType.text),
          ] else ...[
            DropdownButtonFormField<int>(
              value: karat,
              decoration: const InputDecoration(label: Text('عيار الكسر'), border: OutlineInputBorder()),
              items: [
                for (final k in karatsOf(widget.metal))
                  DropdownMenuItem(value: k, child: Text('عيار $k')),
              ],
              onChanged: (v) => setState(() => karat = v!),
            ),
            const SizedBox(height: 12),
          ],
          tf('الوزن (جرام)', w),
          if (mode != 2) tf('العدد (قطعة)', cnt, type: TextInputType.number),
          tf('سعر شراء المنتج ده', price),
          OutlinedButton.icon(
            onPressed: addLine,
            icon: const Icon(Icons.add),
            label: const Text('إضافة للعملية'),
          ),
          const Divider(height: 32),
          Text('المنتجات في العملية (${cart.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          if (cart.isEmpty) const Text('لسه مفيش منتجات'),
          for (final l in cart)
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text(l.scrap
                        ? 'عيار ${l.karat} - كسر'
                        : 'عيار ${l.karat} - ${l.existing == null ? 'منتج جديد' : 'منتج قديم'}'),
                    subtitle: Text(l.scrap
                        ? '${money(l.weight)} جم'
                        : '${money(l.weight)} جم | ${l.count} قطعة | ${l.barcode}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!l.scrap && l.existing == null)
                          IconButton(
                            tooltip: 'طباعة ملصق الباركود',
                            icon: const Icon(Icons.print),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => LabelScreen(barcode: l.barcode, karat: l.karat, copies: l.count)),
                            ),
                          ),
                        Text(money(l.price), style: const TextStyle(fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: saved ? null : () => setState(() => cart.remove(l)),
                        ),
                      ],
                    ),
                  ),
                  if (!l.scrap && l.existing == null)
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: BarcodeWidget(barcode: Barcode.code128(), data: l.barcode, height: 50),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          tf('اسم التاجر / المورد / الشركة (اختياري)', supplier, type: TextInputType.text, onChanged: () => setState(() {})),
          StreamBuilder<List<Item>>(
            stream: Store.watchItems(widget.metal),
            builder: (context, snap) {
              final names = <String>{
                for (final i in snap.data ?? <Item>[])
                  if (i.supplier.isNotEmpty) i.supplier,
              }.toList()
                ..sort();
              if (names.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final n in names)
                      ActionChip(label: Text(n), onPressed: () => setState(() => supplier.text = n)),
                  ],
                ),
              );
            },
          ),
          Text('إجمالي سعر الشراء: ${money(cartTotal)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          payMethodField(payMethod, (v) => setState(() => payMethod = v)),
          tf('المبلغ المدفوع (سيبه فاضي لو دفعت كامل)', paid, onChanged: () => setState(() {})),
          Card(
            color: debt > 0.005 ? Colors.red.shade100 : Colors.green.shade100,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                debt > 0.005
                    ? (supplier.text.trim().isEmpty
                        ? 'عليا مديونية: ${money(debt)}'
                        : 'واقف على التاجر ${supplier.text.trim()}: ${money(debt)}')
                    : 'لا توجد مديونية',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (supplier.text.trim().isEmpty) ...[
            tf('اسم العميل (اختياري)', name, type: TextInputType.text),
            tf('رقم العميل (اختياري)', phone, type: TextInputType.phone),
          ],
          FilledButton(
            onPressed: saved ? null : confirm,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(saved ? 'تم الحفظ ✓' : 'تأكيد الشراء'),
            ),
          ),
          if (saved && lastOp != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => InvoiceScreen(op: lastOp!, isSale: false)),
                ),
                icon: const Icon(Icons.print),
                label: const Text('طباعة الفاتورة'),
              ),
            ),
          if (saved)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: newOp,
                icon: const Icon(Icons.refresh),
                label: const Text('عملية جديدة'),
              ),
            ),
        ],
      ),
    );
  }
}

// ======================= المرحلة 3: تقارير / عملاء / مصاريف / تحويل / تعديل ومسح =======================

double? pn(String? s) => double.tryParse((s ?? '').trim().replaceAll(',', '.'));

String custKey(Map<String, dynamic> m) {
  final ph = '${m['customerPhone'] ?? ''}'.trim();
  if (ph.isNotEmpty) return ph;
  return '${m['customerName'] ?? ''}'.trim();
}

class MultiData {
  List<Map<String, dynamic>> sales = [], purchases = [], payments = [], expenses = [], conversions = [];
  List<Item> items = [];
  Map<String, double> paySum = {};

  void refresh() {
    final m = <String, double>{};
    for (final p in payments) {
      final k = p['refId'] as String;
      m[k] = (m[k] ?? 0.0) + nd(p['amount']);
    }
    paySum = m;
  }

  double restOf(Map<String, dynamic> m, bool isSale) =>
      nd(isSale ? m['total'] : m['price']) - nd(m['paid']) - (paySum[m['id'] as String] ?? 0.0);

  Item? itemById(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }
}

/// بيجمّع كل البيانات (مبيعات، مشتريات، دفعات، مصاريف، تحويلات، مخزون) لنوع المعدن
class Multi extends StatefulWidget {
  final String metal;
  final Widget Function(BuildContext, MultiData) builder;
  const Multi({super.key, required this.metal, required this.builder});
  @override
  State<Multi> createState() => _MultiState();
}

class _MultiState extends State<Multi> {
  final d = MultiData();
  final subs = <StreamSubscription<dynamic>>[];
  final ready = <String>{};

  void _listen<T>(String key, Stream<T> st, void Function(T) assign) {
    subs.add(st.listen((v) {
      assign(v);
      d.refresh();
      ready.add(key);
      if (mounted) setState(() {});
    }));
  }

  @override
  void initState() {
    super.initState();
    final mt = widget.metal;
    _listen('sales', Ops.watch('sales', mt), (v) => d.sales = v);
    _listen('purchases', Ops.watch('purchases', mt), (v) => d.purchases = v);
    _listen('payments', Ops.watch('payments', mt), (v) => d.payments = v);
    _listen('expenses', Ops.watch('expenses', mt), (v) => d.expenses = v);
    _listen('conversions', Ops.watch('conversions', mt), (v) => d.conversions = v);
    _listen('items', Store.watchItems(mt), (v) => d.items = v);
  }

  @override
  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ready.length < 6 ? const Center(child: CircularProgressIndicator()) : widget.builder(context, d);
}

Future<bool> confirmDialog(BuildContext context, String msg) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(msg),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
      ],
    ),
  );
  return r ?? false;
}

Future<double?> askAmount(BuildContext context, String title, double max) {
  final c = TextEditingController();
  return showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
            label: Text('المبلغ (المتبقي ${money(max)})'), border: const OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () {
            final v = parseNum(c);
            if (v == null || v <= 0 || v > max + 0.005) return;
            Navigator.pop(ctx, v);
          },
          child: const Text('تسجيل'),
        ),
      ],
    ),
  );
}

Future<Map<String, String>?> editDialog(BuildContext context, String title, Map<String, String> initial) {
  final ctrls = {for (final e in initial.entries) e.key: TextEditingController(text: e.value)};
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in ctrls.entries)
              tf(
                e.key,
                e.value,
                type: e.key.contains('اسم')
                    ? TextInputType.text
                    : e.key.contains('رقم')
                        ? TextInputType.phone
                        : const TextInputType.numberWithOptions(decimal: true),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, {for (final e in ctrls.entries) e.key: e.value.text.trim()}),
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
}

List<Map<String, dynamic>> linesOf(Map<String, dynamic> m, bool isSale) {
  final raw = m['lines'];
  if (raw is List) {
    return [for (final e in raw) Map<String, dynamic>.from(e as Map)];
  }
  return [
    <String, dynamic>{
      'itemId': m['itemId'],
      'barcode': m['barcode'],
      'karat': m['karat'],
      'weight': m['weight'],
      'count': m['count'],
      'pieces': m['pieces'] ?? [],
      'pieceIdx': m['pieceIdx'],
      'pricePerGram': m['pricePerGram'],
      'fee': m['fee'],
      'total': isSale ? m['total'] : m['price'],
    }
  ];
}

Future<void> editOp(BuildContext context, Map<String, dynamic> m, bool isSale, MultiData d) async {
  final msg = ScaffoldMessenger.of(context);
  void err(String s) => msg.showSnackBar(SnackBar(content: Text(s)));
  final id = m['id'] as String;
  final totalKey = isSale ? 'total' : 'price';
  final totalLabel = isSale ? 'الإجمالي النهائي' : 'سعر الشراء الإجمالي';
  final r = await editDialog(context, isSale ? 'تعديل عملية البيع' : 'تعديل عملية الشراء', {
    totalLabel: money(nd(m[totalKey])),
    'المبلغ المدفوع': money(nd(m['paid'])),
    'اسم العميل': '${m['customerName'] ?? ''}',
    'رقم العميل': '${m['customerPhone'] ?? ''}',
  });
  if (r == null) return;
  final total = pn(r[totalLabel]);
  final paid = pn(r['المبلغ المدفوع']);
  if (total == null || total <= 0 || paid == null || paid < 0) return err('قيم غير صحيحة');
  if (paid + (d.paySum[id] ?? 0.0) > total + 0.005) return err('المدفوع أكبر من الإجمالي');
  liveRefreshSoon();
  Ops.col(isSale ? 'sales' : 'purchases').doc(id).update({
    totalKey: total,
    'paid': paid,
    'customerName': r['اسم العميل'],
    'customerPhone': r['رقم العميل'],
  });
}

Future<void> deleteOp(BuildContext context, Map<String, dynamic> m, bool isSale, MultiData d) async {
  final msg = ScaffoldMessenger.of(context);
  final ids = d.payments
      .where((p) => p['refId'] == m['id'])
      .map((p) => p['id'] as String)
      .toList();
  if (!isSale) {
    for (final l in linesOf(m, false)) {
      final it = d.itemById(l['itemId'] as String);
      final n = (l['count'] as num?)?.toInt() ?? 1;
      if (it != null && (it.remaining < nd(l['weight']) - 0.0001 || it.count < n)) {
        msg.showSnackBar(const SnackBar(
            content: Text('لا يوجد رصيد كافي: اتباع من المنتج ده بعد الشراء، امسح عملية البيع الأول')));
        return;
      }
    }
  }
  if (!await confirmDialog(context, 'مسح العملية دي؟ المخزون هيتعدّل تلقائيًا.')) return;
  if (isSale) {
    Ops.deleteSale(m, ids, d.items);
  } else {
    Ops.deletePurchase(m, ids, d.items);
  }
  msg.showSnackBar(const SnackBar(content: Text('تم المسح')));
}

void opActions(BuildContext context, Map<String, dynamic> m, bool isSale, MultiData d) {
  final rest = d.restOf(m, isSale);
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rest > 0.005)
            ListTile(
              leading: const Icon(Icons.payments),
              title: Text(isSale ? 'تسجيل دفعة من العميل' : 'تسجيل دفعة للعميل'),
              onTap: () async {
                Navigator.pop(ctx);
                final v = await askAmount(context, 'تسجيل دفعة', rest);
                if (v != null) {
                  Ops.addPayment(
                    metal: m['metal'] as String,
                    kind: isSale ? 'sale' : 'purchase',
                    refId: m['id'] as String,
                    amount: v,
                    customerName: '${m['customerName'] ?? ''}',
                    customerPhone: '${m['customerPhone'] ?? ''}',
                  );
                }
              },
            ),
          ListTile(
            leading: const Icon(Icons.print),
            title: const Text('طباعة الفاتورة'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => InvoiceScreen(op: m, isSale: isSale)));
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('تعديل'),
            onTap: () {
              Navigator.pop(ctx);
              editOp(context, m, isSale, d);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('مسح'),
            onTap: () {
              Navigator.pop(ctx);
              deleteOp(context, m, isSale, d);
            },
          ),
        ],
      ),
    ),
  );
}

Widget opTile(BuildContext context, Map<String, dynamic> m, bool isSale, MultiData d) {
  final amount = nd(isSale ? m['total'] : m['price']);
  final extra = d.paySum[m['id'] as String] ?? 0.0;
  final paid = nd(m['paid']) + extra;
  final rest = amount - paid;
  final who = [m['customerName'], m['customerPhone']]
      .where((e) => e != null && '$e'.isNotEmpty)
      .join(' - ');
  final ls = linesOf(m, isSale);
  final title = ls.length == 1
      ? 'عيار ${ls.first['karat']} - ${money(nd(m['weight']))} جم'
      : '${ls.length} منتجات - ${money(nd(m['weight']))} جم';
  final lines = <String>[
    fmtDate(m['ts'] as Timestamp),
    for (final l in ls)
      '• عيار ${l['karat']} | ${money(nd(l['weight']))} جم | ${l['count'] ?? '-'} قطعة | ${l['barcode']}',
    if (who.isNotEmpty) 'العميل: $who',
    if (isSale) 'مصنعية ${money(nd(m['fee']))}',
    'مدفوع ${money(paid)}'
        '${rest > 0.005 ? (isSale ? ' | متبقي عليه ${money(rest)}' : ' | متبقي علينا ${money(rest)}') : ''}',
  ];
  return Card(
    child: ListTile(
      title: Text('$title${m['cut'] == true ? ' (قطع)' : ''}'),
      subtitle: Text(lines.join('\n')),
      trailing: Text(money(amount), style: const TextStyle(fontWeight: FontWeight.bold)),
      onTap: () => opActions(context, m, isSale, d),
    ),
  );
}

Widget emptyNote([String t = 'لا يوجد عمليات']) => Center(child: Text(t));

class HistoryScreen extends StatelessWidget {
  final String metal;
  const HistoryScreen({super.key, required this.metal});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text('عمليات ${metalNames[metal]}'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [Tab(child: Text('مبيعات')), Tab(child: Text('مشتريات')), Tab(child: Text('مصاريف')), Tab(child: Text('تحويلات'))],
          ),
        ),
        body: Multi(
          metal: metal,
          builder: (context, d) => TabBarView(children: [
            d.sales.isEmpty
                ? emptyNote()
                : PageList(children: [for (final m in d.sales) opTile(context, m, true, d)]),
            d.purchases.isEmpty
                ? emptyNote()
                : PageList(children: [for (final m in d.purchases) opTile(context, m, false, d)]),
            d.expenses.isEmpty
                ? emptyNote('لا يوجد مصاريف')
                : PageList(children: [
                    for (final m in d.expenses)
                      Card(
                        child: ListTile(
                          title: Text('${m['title']}${m['type'] == 'salary' ? ' (قبض عامل)' : ''}'),
                          subtitle: Text(fmtDate(m['ts'] as Timestamp)),
                          trailing: Text(money(nd(m['amount'])),
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          onTap: () async {
                            if (await confirmDialog(context, 'مسح المصروف ده؟')) {
                              Ops.col('expenses').doc(m['id'] as String).delete();
                              liveRefreshSoon();
                            }
                          },
                        ),
                      ),
                  ]),
            d.conversions.isEmpty
                ? emptyNote('لا يوجد تحويلات')
                : PageList(children: [
                    for (final m in d.conversions)
                      Card(
                        child: ListTile(
                          isThreeLine: true,
                          title: Text('من عيار ${m['fromKarat']} إلى عيار ${m['toKarat']}'),
                          subtitle: Text('${fmtDate(m['ts'] as Timestamp)}\n'
                              '${money(nd(m['fromWeight']))} جم  ←  ${money(nd(m['toWeight']))} جم'),
                        ),
                      ),
                  ]),
          ]),
        ),
      ),
    );
  }
}

class ReportsScreen extends StatefulWidget {
  final String metal;
  const ReportsScreen({super.key, required this.metal});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int mode = 0; // 0 يومي، 1 أسبوعي، 2 شهري، 3 سنوي
  DateTime anchor = DateTime.now();

  (DateTime, DateTime) get range {
    final a = anchor;
    switch (mode) {
      case 0:
        return (DateTime(a.year, a.month, a.day), DateTime(a.year, a.month, a.day + 1));
      case 1:
        final s = DateTime(a.year, a.month, a.day - ((a.weekday - 6) % 7)); // الأسبوع يبدأ السبت
        return (s, DateTime(s.year, s.month, s.day + 7));
      case 2:
        return (DateTime(a.year, a.month, 1), DateTime(a.year, a.month + 1, 1));
      default:
        return (DateTime(a.year, 1, 1), DateTime(a.year + 1, 1, 1));
    }
  }

  void shift(int dir) => setState(() {
        final a = anchor;
        anchor = switch (mode) {
          0 => DateTime(a.year, a.month, a.day + dir),
          1 => DateTime(a.year, a.month, a.day + 7 * dir),
          2 => DateTime(a.year, a.month + dir, 1),
          _ => DateTime(a.year + dir, 1, 1),
        };
      });

  String get label {
    final r = range;
    String f(DateTime x) => '${x.year}-${_two(x.month)}-${_two(x.day)}';
    switch (mode) {
      case 0:
        return f(r.$1);
      case 1:
        return '${f(r.$1)}  →  ${f(DateTime(r.$2.year, r.$2.month, r.$2.day - 1))}';
      case 2:
        return '${r.$1.year}-${_two(r.$1.month)}';
      default:
        return '${r.$1.year}';
    }
  }

  Widget body(MultiData d) {
    final r = range;
    bool inR(Map<String, dynamic> m) {
      final t = (m['ts'] as Timestamp).toDate();
      return !t.isBefore(r.$1) && t.isBefore(r.$2);
    }

    double sum(Iterable<Map<String, dynamic>> l, String k) => l.fold<double>(0, (a, m) => a + nd(m[k]));

    final sales = d.sales.where(inR).toList();
    final purchases = d.purchases.where(inR).toList();
    final payIn = d.payments.where((p) => p['kind'] == 'sale' && inR(p)).toList();
    final payOut = d.payments.where((p) => p['kind'] == 'purchase' && inR(p)).toList();
    final exps = d.expenses.where(inR).toList();

    final totalSales = sum(sales, 'total');
    final totalPurch = sum(purchases, 'price');
    final collected = sum(sales, 'paid') + sum(payIn, 'amount');
    final paidOut = sum(purchases, 'paid') + sum(payOut, 'amount');
    final salesRest = sales.fold<double>(0, (a, m) => a + d.restOf(m, true));
    final purchRest = purchases.fold<double>(0, (a, m) => a + d.restOf(m, false));
    final fees = sum(sales, 'fee');
    final spent = sum(exps.where((e) => e['type'] != 'salary'), 'amount');
    final salaries = sum(exps.where((e) => e['type'] == 'salary'), 'amount');

    final rows = <(String, String)>[
      ('إجمالي المبيعات', money(totalSales)),
      ('إجمالي المشتريات', money(totalPurch)),
      ('تم تحصيله', money(collected)),
      ('تم دفعه', money(paidOut)),
      ('مبيعات متبقية (عليهم)', money(salesRest)),
      ('مشتريات متبقية (علينا)', money(purchRest)),
      ('إجمالي المصنعية في المبيعات', money(fees)),
      ('مصاريف المحل', money(spent)),
      ('قبض العاملين', money(salaries)),
      ('صافي المصنعية بعد المصاريف', money(fees - spent - salaries)),
      ('وزن المبيعات (جم)', money(sum(sales, 'weight'))),
      ('وزن المشتريات (جم)', money(sum(purchases, 'weight'))),
      ('عدد عمليات البيع', '${sales.length}'),
      ('عدد عمليات الشراء', '${purchases.length}'),
    ];

    return PageList(
      padding: const EdgeInsets.all(12),
      children: [
        for (final row in rows)
          Card(
            child: ListTile(
              dense: true,
              title: Text(row.$1),
              trailing: Text(row.$2, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'تم تحصيله/دفعه = فلوس دخلت أو خرجت خلال الفترة (تشمل الدفعات اللاحقة). '
            'المتبقي = الرصيد الحالي على عمليات الفترة.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('تقارير ${metalNames[widget.metal]}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('يومي')),
                ButtonSegment(value: 1, label: Text('أسبوعي')),
                ButtonSegment(value: 2, label: Text('شهري')),
                ButtonSegment(value: 3, label: Text('سنوي')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => setState(() {
                mode = s.first;
                anchor = DateTime.now();
              }),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => shift(-1)),
              Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => shift(1)),
            ],
          ),
          Expanded(child: Multi(metal: widget.metal, builder: (c, d) => body(d))),
        ],
      ),
    );
  }
}

class _Cust {
  final String key;
  String name = '';
  String phone = '';
  double owesUs = 0;
  double weOwe = 0;
  _Cust(this.key);
  String get title => name.isNotEmpty ? name : (phone.isNotEmpty ? phone : key);
}

class CustomersScreen extends StatefulWidget {
  final String metal;
  const CustomersScreen({super.key, required this.metal});
  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('عملاء ${metalNames[widget.metal]}')),
      body: Multi(
        metal: widget.metal,
        builder: (context, d) {
          final map = <String, _Cust>{};
          void add(Map<String, dynamic> m, bool isSale) {
            final k = custKey(m);
            if (k.isEmpty) return;
            final c = map.putIfAbsent(k, () => _Cust(k));
            final nm = '${m['customerName'] ?? ''}';
            final ph = '${m['customerPhone'] ?? ''}';
            if (nm.isNotEmpty) c.name = nm;
            if (ph.isNotEmpty) c.phone = ph;
            final rest = d.restOf(m, isSale);
            if (isSale) {
              c.owesUs += rest;
            } else {
              c.weOwe += rest;
            }
          }

          for (final m in d.sales) {
            add(m, true);
          }
          for (final m in d.purchases) {
            add(m, false);
          }
          final list = map.values
              .where((c) => q.isEmpty || c.name.contains(q) || c.phone.contains(q))
              .toList()
            ..sort((a, b) => (b.owesUs + b.weOwe).compareTo(a.owesUs + a.weOwe));
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  decoration: const InputDecoration(
                      label: Text('بحث بالاسم أو الرقم'),
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search)),
                  onChanged: (v) => setState(() => q = v.trim()),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? emptyNote('لا يوجد عملاء مسجلين')
                    : PageList(
                        children: [
                          for (final c in list)
                            Card(
                              child: ListTile(
                                title: Text(c.title),
                                subtitle: Text(c.phone),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (c.owesUs > 0.005)
                                      Text('عليه ${money(c.owesUs)}',
                                          style: const TextStyle(color: Colors.red)),
                                    if (c.weOwe > 0.005)
                                      Text('له ${money(c.weOwe)}',
                                          style: const TextStyle(color: Colors.green)),
                                    if (c.owesUs <= 0.005 && c.weOwe <= 0.005) const Text('خالص'),
                                  ],
                                ),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => CustomerDetailScreen(
                                        metal: widget.metal, keyValue: c.key, title: c.title),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class CustomerDetailScreen extends StatelessWidget {
  final String metal, keyValue, title;
  const CustomerDetailScreen({super.key, required this.metal, required this.keyValue, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Multi(
        metal: metal,
        builder: (context, d) {
          final s = d.sales.where((m) => custKey(m) == keyValue).toList();
          final p = d.purchases.where((m) => custKey(m) == keyValue).toList();
          return PageList(
            children: [
              if (s.isNotEmpty)
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('مبيعات له', style: TextStyle(fontWeight: FontWeight.bold))),
              for (final m in s) opTile(context, m, true, d),
              if (p.isNotEmpty)
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('مشتريات منه', style: TextStyle(fontWeight: FontWeight.bold))),
              for (final m in p) opTile(context, m, false, d),
            ],
          );
        },
      ),
    );
  }
}

class ExpensesScreen extends StatefulWidget {
  final String metal;
  const ExpensesScreen({super.key, required this.metal});
  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  bool salary = false;
  bool saved = false;
  final title = TextEditingController();
  final amount = TextEditingController();

  void save() {
    if (saved) return;
    final a = parseNum(amount);
    if (title.text.trim().isEmpty || a == null || a <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(salary ? 'اكتب اسم العامل والمبلغ' : 'اكتب وصف المصروف والمبلغ')));
      return;
    }
    Ops.addExpense(
      metal: widget.metal,
      type: salary ? 'salary' : 'expense',
      title: title.text.trim(),
      amount: a,
    );
    setState(() => saved = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الحفظ')));
  }

  void newOp() => setState(() {
        title.clear();
        amount.clear();
        saved = false;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مصاريف وقبض العاملين')),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('مصروف')),
              ButtonSegment(value: true, label: Text('قبض عامل')),
            ],
            selected: {salary},
            onSelectionChanged: (s) => setState(() => salary = s.first),
          ),
          const SizedBox(height: 16),
          tf(salary ? 'اسم العامل' : 'وصف المصروف (مثال: صيانة المحل)', title, type: TextInputType.text),
          tf(salary ? 'مبلغ القبض' : 'المبلغ', amount),
          FilledButton(
            onPressed: saved ? null : save,
            child: Padding(padding: const EdgeInsets.all(12), child: Text(saved ? 'تم الحفظ ✓' : 'حفظ')),
          ),
          if (saved)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: newOp,
                icon: const Icon(Icons.refresh),
                label: const Text('عملية جديدة'),
              ),
            ),
        ],
      ),
    );
  }
}

class ConvertScreen extends StatefulWidget {
  final String metal;
  const ConvertScreen({super.key, required this.metal});
  @override
  State<ConvertScreen> createState() => _ConvertScreenState();
}

class _ConvertScreenState extends State<ConvertScreen> {
  Item? from;
  Item? to;
  bool toExisting = false;
  bool saved = false;
  int gen = 0;
  late int toKarat = karatsOf(widget.metal).first;
  final w = TextEditingController();
  final cnt = TextEditingController(text: '1');
  final toW = TextEditingController();

  void _recalc() {
    final f = from;
    final wt = parseNum(w);
    if (f != null && wt != null) toW.text = money(wt * f.karat / toKarat);
    setState(() {});
  }

  void _msg(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void save() {
    if (saved) return;
    final f = from;
    if (f == null) return _msg('اختار المنتج اللي هيتحول منه');
    final wt = parseNum(w);
    final cn = int.tryParse(cnt.text.trim()) ?? 0;
    if (wt == null || wt <= 0 || cn <= 0) return _msg('اكتب الوزن والعدد');
    if (wt > f.remaining + 0.0001 || cn > f.count) {
      return _msg('لا يوجد رصيد كافي (المتاح: ${money(f.remaining)} جم و ${f.count} قطعة)');
    }
    if (toKarat == f.karat) return _msg('اختار عيار مختلف');
    final tw = parseNum(toW);
    if (tw == null || tw <= 0) return _msg('اكتب الوزن الناتج');
    Item? dest;
    if (toExisting) {
      dest = to;
      if (dest == null) return _msg('اختار المنتج اللي هيتحول إليه');
      if (dest.karat != toKarat) return _msg('المنتج المختار مش من عيار $toKarat');
    }
    Ops.convert(
        metal: widget.metal, from: f, weight: wt, count: cn, toKarat: toKarat, to: dest, toWeight: tw);
    setState(() => saved = true);
    _msg('تم التحويل: ${money(wt)} جم ← ${money(tw)} جم');
  }

  void newOp() => setState(() {
        from = null;
        to = null;
        w.clear();
        toW.clear();
        cnt.text = '1';
        gen++;
        saved = false;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تحويل بين العيارات')),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('التحويل من:'),
          const SizedBox(height: 8),
          ItemPicker(
            key: ValueKey('from$gen'),
            metal: widget.metal,
            onSelected: (i) {
              from = i;
              _recalc();
            },
          ),
          if (from != null) ItemInfo(from!),
          tf('الوزن المحوّل (جرام)', w, onChanged: _recalc),
          tf('العدد المحوّل (قطعة)', cnt, type: TextInputType.number),
          DropdownButtonFormField<int>(
            value: toKarat,
            decoration: const InputDecoration(label: Text('التحويل إلى عيار'), border: OutlineInputBorder()),
            items: [
              for (final k in karatsOf(widget.metal)) DropdownMenuItem(value: k, child: Text('عيار $k')),
            ],
            onChanged: (v) {
              toKarat = v!;
              to = null;
              _recalc();
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('منتج جديد')),
              ButtonSegment(value: true, label: Text('على منتج موجود')),
            ],
            selected: {toExisting},
            onSelectionChanged: (s) => setState(() => toExisting = s.first),
          ),
          const SizedBox(height: 12),
          if (toExisting) ...[
            ItemPicker(
              key: ValueKey('to$gen'),
              metal: widget.metal,
              onSelected: (i) => setState(() => to = i),
            ),
            if (to != null) ItemInfo(to!),
          ],
          tf('الوزن الناتج (جرام) - بيتحسب تلقائي وتقدر تعدله', toW),
          const Text(
            'الحساب: الوزن × عيار المصدر ÷ عيار الهدف (بنفس كمية الذهب الصافي).',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: saved ? null : save,
            child: Padding(padding: const EdgeInsets.all(12), child: Text(saved ? 'تم الحفظ ✓' : 'تأكيد التحويل')),
          ),
          if (saved)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: newOp,
                icon: const Icon(Icons.refresh),
                label: const Text('عملية جديدة'),
              ),
            ),
        ],
      ),
    );
  }
}


// ======================= قراءة البيانات (الكمبيوتر) =======================
// على ويندوز مكتبة Firebase بتقفل البرنامج لما نستخدم الاستماع اللحظي (snapshots)،
// فبنستبدله بقراءة دورية: من الجهاز كل ثانيتين (مجاناً) ومن السيرفر كل فترة.
// على الأندرويد بيفضل الاستماع اللحظي زي ما هو.

class _Live {
  final Query<Map<String, dynamic>> q;
  final int serverSeconds;
  _Live(this.q, this.serverSeconds);

  late final StreamController<QuerySnapshot<Map<String, dynamic>>> c =
      StreamController.broadcast(onListen: _start, onCancel: _stop);
  QuerySnapshot<Map<String, dynamic>>? last;
  int lastSig = 0;
  DateTime? serverAt;
  Timer? timer;
  bool busy = false;

  Stream<QuerySnapshot<Map<String, dynamic>>> get stream => c.stream;

  void _start() {
    final l = last;
    if (l != null) {
      Future.microtask(() {
        if (c.hasListener) c.add(l);
      });
    }
    tick(force: true);
    timer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
  }

  void _stop() {
    timer?.cancel();
    timer = null;
  }

  void _emit(QuerySnapshot<Map<String, dynamic>> snap) {
    final sig = snap.docs.map((d) => '${d.id}:${d.data()}').join('|').hashCode;
    if (last == null || sig != lastSig) {
      last = snap;
      lastSig = sig;
      if (c.hasListener) c.add(snap);
    }
  }

  Future<void> tick({bool force = false}) async {
    if (busy) return;
    final now = DateTime.now();
    if (!force && serverAt != null && now.difference(serverAt!).inSeconds < serverSeconds) return;
    busy = true;
    serverAt = now;
    try {
      _emit(await q.get());
    } catch (_) {
      if (last == null) {
        try {
          _emit(await q.get(const GetOptions(source: Source.cache)));
        } catch (_) {}
      }
    } finally {
      busy = false;
    }
  }
}

final Map<String, _Live> _liveMap = {};

Stream<QuerySnapshot<Map<String, dynamic>>> liveQuery(
  String key,
  Query<Map<String, dynamic>> q, {
  int serverSeconds = 60,
}) {
  if (!Platform.isWindows) return q.snapshots();
  return _liveMap.putIfAbsent(key, () => _Live(q, serverSeconds)).stream;
}

/// بعد أي كتابة بنحدّث القراءة من السيرفر بعد ثانيتين وبعد 8 ثواني (الكمبيوتر بس)
void liveRefresh() {
  for (final l in _liveMap.values) {
    if (l.timer != null) l.tick(force: true);
  }
}

void liveRefreshSoon() {
  Future.delayed(const Duration(seconds: 2), liveRefresh);
  Future.delayed(const Duration(seconds: 8), liveRefresh);
}

/// تمكين السحب بالماوس واللمس لتحريك الصفحات فوق وتحت
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();
  @override
  Set<ui.PointerDeviceKind> get dragDevices => {
        ui.PointerDeviceKind.touch,
        ui.PointerDeviceKind.mouse,
        ui.PointerDeviceKind.stylus,
        ui.PointerDeviceKind.trackpad,
      };
}

// ======================= المرحلة 4: لغات / ثيم / تحديث تلقائي / طباعة / إحصائيات =======================

const int kBuild = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
const String kRepo = 'siragashraf7-a11y/jawaher';

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
final ValueNotifier<String> appLang = ValueNotifier<String>('ar');
final ValueNotifier<bool> appDark = ValueNotifier<bool>(true);

const List<List<String>> _dict = [
  ['المخزون', 'Inventory', 'Lagerbestand', 'Stock', 'Magazzino', 'Inventario'],
  ['إجمالي المخزون', 'Total inventory', 'Gesamtbestand', 'Stock total', 'Inventario totale', 'Inventario total'],
  ['مخزون عام', 'General stock', 'Allgemeiner Bestand', 'Stock général', 'Magazzino generale', 'Inventario general'],
  ['سجل العمليات', 'Transactions', 'Vorgänge', 'Opérations', 'Operazioni', 'Operaciones'],
  ['عمليات', 'Transactions', 'Vorgänge', 'Opérations', 'Operazioni', 'Operaciones'],
  ['العملاء والمديونيات', 'Customers & Debts', 'Kunden & Schulden', 'Clients & Dettes', 'Clienti e Debiti', 'Clientes y Deudas'],
  ['عملاء', 'Customers', 'Kunden', 'Clients', 'Clienti', 'Clientes'],
  ['مصاريف وقبض العاملين', 'Expenses & Wages', 'Ausgaben & Löhne', 'Dépenses & Salaires', 'Spese e Stipendi', 'Gastos y Salarios'],
  ['مصاريف', 'Expenses', 'Ausgaben', 'Dépenses', 'Spese', 'Gastos'],
  ['تحويل بين العيارات', 'Karat conversion', 'Karat-Umrechnung', 'Conversion de carats', 'Conversione carati', 'Conversión de quilates'],
  ['التجار والموردين', 'Dealers & Suppliers', 'Händler & Lieferanten', 'Marchands & Fournisseurs', 'Commercianti e Fornitori', 'Comerciantes y Proveedores'],
  ['الإحصائيات', 'Statistics', 'Statistik', 'Statistiques', 'Statistiche', 'Estadísticas'],
  ['إحصائيات', 'Statistics', 'Statistik', 'Statistiques', 'Statistiche', 'Estadísticas'],
  ['الإعدادات', 'Settings', 'Einstellungen', 'Paramètres', 'Impostazioni', 'Ajustes'],
  ['التقارير', 'Reports', 'Berichte', 'Rapports', 'Rapporti', 'Informes'],
  ['تقارير', 'Reports', 'Berichte', 'Rapports', 'Rapporti', 'Informes'],
  ['الذهب', 'Gold', 'Gold', 'Or', 'Oro', 'Oro'],
  ['الفضة', 'Silver', 'Silber', 'Argent', 'Argento', 'Plata'],
  ['المحل', 'Shop', 'Geschäft', 'Boutique', 'Negozio', 'Tienda'],
  ['بيع بالجرام', 'Sell by gram', 'Nach Gramm verkaufen', 'Vente au gramme', 'Vendita al grammo', 'Venta por gramo'],
  ['بيع بالقطعة', 'Sell by piece', 'Stückverkauf', 'Vente à la pièce', 'Vendita a pezzo', 'Venta por pieza'],
  ['بيع', 'Sell', 'Verkauf', 'Vente', 'Vendita', 'Venta'],
  ['شراء', 'Buy', 'Einkauf', 'Achat', 'Acquisto', 'Compra'],
  ['إضافة منتج للعملية', 'Add product to transaction', 'Produkt zum Vorgang', 'Ajouter un produit', 'Aggiungi prodotto', 'Añadir producto'],
  ['إضافة للعملية', 'Add to transaction', 'Zum Vorgang hinzufügen', "Ajouter à l'opération", "Aggiungi all'operazione", 'Añadir a la operación'],
  ['إضافة منتج', 'Add product', 'Produkt hinzufügen', 'Ajouter un produit', 'Aggiungi prodotto', 'Añadir producto'],
  ['المنتجات في العملية', 'Items in transaction', 'Artikel im Vorgang', "Articles de l'opération", "Articoli nell'operazione", 'Artículos en la operación'],
  ['تأكيد البيع', 'Confirm sale', 'Verkauf bestätigen', 'Confirmer la vente', 'Conferma vendita', 'Confirmar venta'],
  ['تأكيد الشراء', 'Confirm purchase', 'Einkauf bestätigen', "Confirmer l'achat", 'Conferma acquisto', 'Confirmar compra'],
  ['تأكيد التحويل', 'Confirm conversion', 'Umrechnung bestätigen', 'Confirmer la conversion', 'Conferma conversione', 'Confirmar conversión'],
  ['تم الحفظ ✓', 'Saved ✓', 'Gespeichert ✓', 'Enregistré ✓', 'Salvato ✓', 'Guardado ✓'],
  ['تم الحفظ', 'Saved', 'Gespeichert', 'Enregistré', 'Salvato', 'Guardado'],
  ['عملية جديدة', 'New transaction', 'Neuer Vorgang', 'Nouvelle opération', 'Nuova operazione', 'Nueva operación'],
  ['منتج جديد', 'New product', 'Neues Produkt', 'Nouveau produit', 'Nuovo prodotto', 'Nuevo producto'],
  ['منتج قديم', 'Existing product', 'Vorhandenes Produkt', 'Produit existant', 'Prodotto esistente', 'Producto existente'],
  ['حفظ', 'Save', 'Speichern', 'Enregistrer', 'Salva', 'Guardar'],
  ['إلغاء', 'Cancel', 'Abbrechen', 'Annuler', 'Annulla', 'Cancelar'],
  ['تأكيد', 'Confirm', 'Bestätigen', 'Confirmer', 'Conferma', 'Confirmar'],
  ['لاحقاً', 'Later', 'Später', 'Plus tard', 'Più tardi', 'Más tarde'],
  ['مسح', 'Delete', 'Löschen', 'Supprimer', 'Elimina', 'Eliminar'],
  ['تعديل', 'Edit', 'Bearbeiten', 'Modifier', 'Modifica', 'Editar'],
  ['تسجيل دفعة', 'Record payment', 'Zahlung erfassen', 'Enregistrer un paiement', 'Registra pagamento', 'Registrar pago'],
  ['طباعة الفاتورة', 'Print invoice', 'Rechnung drucken', 'Imprimer la facture', 'Stampa fattura', 'Imprimir factura'],
  ['طباعة ملصق الباركود', 'Print barcode label', 'Barcode-Etikett drucken', "Imprimer l'étiquette", 'Stampa etichetta', 'Imprimir etiqueta'],
  ['طباعة', 'Print', 'Drucken', 'Imprimer', 'Stampa', 'Imprimir'],
  ['فاتورة بيع', 'Sales invoice', 'Verkaufsrechnung', 'Facture de vente', 'Fattura di vendita', 'Factura de venta'],
  ['إيصال شراء', 'Purchase receipt', 'Einkaufsbeleg', "Reçu d'achat", 'Ricevuta di acquisto', 'Recibo de compra'],
  ['الفاتورة', 'Invoice', 'Rechnung', 'Facture', 'Fattura', 'Factura'],
  ['الصنف', 'Item', 'Artikel', 'Article', 'Articolo', 'Artículo'],
  ['شكراً لتعاملكم معنا', 'Thank you for your business', 'Vielen Dank für Ihren Einkauf', 'Merci de votre confiance', 'Grazie per averci scelto', 'Gracias por su compra'],
  ['عيار', 'Karat', 'Karat', 'Carat', 'Carati', 'Quilates'],
  ['جم', 'g', 'g', 'g', 'g', 'g'],
  ['قطعة', 'pcs', 'Stk.', 'pcs', 'pz', 'uds'],
  ['العدد', 'Count', 'Anzahl', 'Quantité', 'Quantità', 'Cantidad'],
  ['الوزن', 'Weight', 'Gewicht', 'Poids', 'Peso', 'Peso'],
  ['المتبقي', 'Remaining', 'Verbleibend', 'Restant', 'Rimanente', 'Restante'],
  ['متبقي', 'Remaining', 'Verbleibend', 'Restant', 'Rimanente', 'Restante'],
  ['باقي', 'Remaining', 'Rest', 'Reste', 'Resto', 'Resto'],
  ['سعر الجرام', 'Price per gram', 'Preis pro Gramm', 'Prix par gramme', 'Prezzo al grammo', 'Precio por gramo'],
  ['مصنعية للجرام', 'Making per gram', 'Arbeitslohn pro Gramm', 'Façon par gramme', 'Lavorazione al grammo', 'Hechura por gramo'],
  ['مصنعية إجمالية', 'Total making', 'Arbeitslohn gesamt', 'Façon totale', 'Lavorazione totale', 'Hechura total'],
  ['المصنعية الإجمالية', 'Total making charge', 'Gesamter Arbeitslohn', 'Façon totale', 'Lavorazione totale', 'Hechura total'],
  ['المصنعية لكل جرام', 'Making per gram', 'Arbeitslohn pro Gramm', 'Façon par gramme', 'Lavorazione al grammo', 'Hechura por gramo'],
  ['مجمل المصنعية', 'Total making', 'Arbeitslohn gesamt', 'Total façon', 'Totale lavorazione', 'Total hechura'],
  ['مجمل السعر', 'Total price', 'Gesamtpreis', 'Prix total', 'Prezzo totale', 'Precio total'],
  ['المصنعية', 'Making charge', 'Arbeitslohn', 'Façon', 'Lavorazione', 'Hechura'],
  ['مصنعية', 'Making', 'Arbeitslohn', 'Façon', 'Lavorazione', 'Hechura'],
  ['سعر المنتج ده', 'Price of this item', 'Preis dieses Artikels', 'Prix de cet article', 'Prezzo di questo articolo', 'Precio de este artículo'],
  ['الإجمالي النهائي', 'Final total', 'Endsumme', 'Total final', 'Totale finale', 'Total final'],
  ['الإجمالي', 'Total', 'Gesamt', 'Total', 'Totale', 'Total'],
  ['إجمالي', 'Total', 'Gesamt', 'Total', 'Totale', 'Total'],
  ['المبلغ المدفوع', 'Amount paid', 'Gezahlter Betrag', 'Montant payé', 'Importo pagato', 'Importe pagado'],
  ['المدفوع', 'Paid', 'Bezahlt', 'Payé', 'Pagato', 'Pagado'],
  ['مدفوع', 'Paid', 'Bezahlt', 'Payé', 'Pagato', 'Pagado'],
  ['اسم العميل', 'Customer name', 'Kundenname', 'Nom du client', 'Nome cliente', 'Nombre del cliente'],
  ['رقم العميل', 'Customer phone', 'Kundentelefon', 'Téléphone du client', 'Telefono cliente', 'Teléfono del cliente'],
  ['العميل', 'Customer', 'Kunde', 'Client', 'Cliente', 'Cliente'],
  ['اختياري', 'optional', 'optional', 'facultatif', 'facoltativo', 'opcional'],
  ['اسم التاجر / المورد / الشركة', 'Dealer / supplier / company name', 'Händler / Lieferant / Firma', 'Marchand / fournisseur / société', 'Commerciante / fornitore / società', 'Comerciante / proveedor / empresa'],
  ['التاجر / المورد', 'Dealer / supplier', 'Händler / Lieferant', 'Marchand / fournisseur', 'Commerciante / fornitore', 'Comerciante / proveedor'],
  ['التاجر', 'Dealer', 'Händler', 'Marchand', 'Commerciante', 'Comerciante'],
  ['الواقف على التاجر', 'Owed to dealer', 'Beim Händler offen', 'Dû au marchand', 'Dovuto al commerciante', 'Pendiente con el comerciante'],
  ['علينا', 'We owe', 'Wir schulden', 'Nous devons', 'Dobbiamo', 'Debemos'],
  ['عليه', 'He owes', 'Schuldet', 'Doit', 'Deve', 'Debe'],
  ['خالص', 'Settled', 'Beglichen', 'Réglé', 'Saldato', 'Saldado'],
  ['طريقة الدفع', 'Payment method', 'Zahlungsart', 'Mode de paiement', 'Metodo di pagamento', 'Método de pago'],
  ['كاش', 'Cash', 'Bar', 'Espèces', 'Contanti', 'Efectivo'],
  ['انستا باي', 'InstaPay', 'InstaPay', 'InstaPay', 'InstaPay', 'InstaPay'],
  ['فيزا', 'Visa', 'Visa', 'Visa', 'Visa', 'Visa'],
  ['كسر', 'Scrap', 'Altgold', 'Casse', 'Rottame', 'Chatarra'],
  ['الكسر', 'Scrap', 'Altgold', 'Casse', 'Rottame', 'Chatarra'],
  ['بالوزن فقط', 'by weight only', 'nur nach Gewicht', 'au poids seulement', 'solo a peso', 'solo por peso'],
  ['الباركود أو الاسم', 'Barcode or name', 'Barcode oder Name', 'Code-barres ou nom', 'Codice o nome', 'Código o nombre'],
  ['الباركود', 'Barcode', 'Barcode', 'Code-barres', 'Codice a barre', 'Código de barras'],
  ['وصف', 'Description', 'Beschreibung', 'Description', 'Descrizione', 'Descripción'],
  ['العيار', 'Karat', 'Karat', 'Carat', 'Carati', 'Quilates'],
  ['مبيعات', 'Sales', 'Verkäufe', 'Ventes', 'Vendite', 'Ventas'],
  ['مشتريات', 'Purchases', 'Einkäufe', 'Achats', 'Acquisti', 'Compras'],
  ['تحويلات', 'Conversions', 'Umrechnungen', 'Conversions', 'Conversioni', 'Conversiones'],
  ['يومي', 'Daily', 'Täglich', 'Quotidien', 'Giornaliero', 'Diario'],
  ['أسبوعي', 'Weekly', 'Wöchentlich', 'Hebdomadaire', 'Settimanale', 'Semanal'],
  ['شهري', 'Monthly', 'Monatlich', 'Mensuel', 'Mensile', 'Mensual'],
  ['سنوي', 'Yearly', 'Jährlich', 'Annuel', 'Annuale', 'Anual'],
  ['إجمالي المبيعات', 'Total sales', 'Gesamtumsatz', 'Total des ventes', 'Vendite totali', 'Ventas totales'],
  ['إجمالي المشتريات', 'Total purchases', 'Gesamteinkäufe', 'Total des achats', 'Acquisti totali', 'Compras totales'],
  ['عدد الفواتير', 'Invoices', 'Rechnungen', 'Factures', 'Fatture', 'Facturas'],
  ['عدد العملاء', 'Customers', 'Kunden', 'Clients', 'Clienti', 'Clientes'],
  ['متوسط الفاتورة', 'Average invoice', 'Durchschnittsrechnung', 'Facture moyenne', 'Fattura media', 'Factura media'],
  ['نمو المبيعات', 'Sales growth', 'Umsatzwachstum', 'Croissance des ventes', 'Crescita vendite', 'Crecimiento de ventas'],
  ['نسبة تحقيق الهدف', 'Target achievement', 'Zielerreichung', "Atteinte de l'objectif", 'Raggiungimento obiettivo', 'Cumplimiento del objetivo'],
  ['توزيع المبيعات حسب العيار', 'Sales by karat', 'Umsatz nach Karat', 'Ventes par carat', 'Vendite per carato', 'Ventas por quilate'],
  ['المبيعات اليومية', 'Daily sales', 'Tagesumsatz', 'Ventes quotidiennes', 'Vendite giornaliere', 'Ventas diarias'],
  ['المبيعات الشهرية', 'Monthly sales', 'Monatsumsatz', 'Ventes mensuelles', 'Vendite mensili', 'Ventas mensuales'],
  ['الهدف الشهري', 'Monthly target', 'Monatsziel', 'Objectif mensuel', 'Obiettivo mensile', 'Objetivo mensual'],
  ['حدد الهدف من الإعدادات', 'Set the target in Settings', 'Ziel in den Einstellungen festlegen', 'Définir dans Paramètres', 'Imposta in Impostazioni', 'Defínalo en Ajustes'],
  ['اسم المحل', 'Shop name', 'Geschäftsname', 'Nom de la boutique', 'Nome negozio', 'Nombre de la tienda'],
  ['رقم تليفون المحل', 'Shop phone', 'Telefon', 'Téléphone', 'Telefono', 'Teléfono'],
  ['عنوان المحل', 'Shop address', 'Adresse', 'Adresse', 'Indirizzo', 'Dirección'],
  ['مقاس ورق الطباعة', 'Paper size', 'Papierformat', 'Format du papier', 'Formato carta', 'Tamaño de papel'],
  ['فحص التحديث الآن', 'Check for updates now', 'Jetzt nach Updates suchen', 'Rechercher une mise à jour', 'Cerca aggiornamenti', 'Buscar actualizaciones'],
  ['تحديث جديد متاح', 'New update available', 'Neues Update verfügbar', 'Nouvelle mise à jour disponible', 'Nuovo aggiornamento disponibile', 'Nueva actualización disponible'],
  ['تحديث الآن', 'Update now', 'Jetzt aktualisieren', 'Mettre à jour', 'Aggiorna ora', 'Actualizar ahora'],
  ['جاري تحديث البرنامج... لا تغلقه', 'Updating the app... do not close', 'App wird aktualisiert... nicht schließen', "Mise à jour en cours... ne fermez pas", 'Aggiornamento in corso... non chiudere', 'Actualizando... no cierre'],
  ['أنت على آخر نسخة', 'You are on the latest version', 'Sie haben die neueste Version', 'Vous avez la dernière version', 'Hai l\'ultima versione', 'Tiene la última versión'],
  ['لا يوجد عمليات', 'No transactions', 'Keine Vorgänge', 'Aucune opération', 'Nessuna operazione', 'Sin operaciones'],
  ['لا يوجد رصيد كافي', 'Insufficient stock', 'Nicht genug Bestand', 'Stock insuffisant', 'Scorte insufficienti', 'Existencias insuficientes'],
  ['المتاح', 'Available', 'Verfügbar', 'Disponible', 'Disponibile', 'Disponible'],
  ['مفيش منتجات لسه', 'No products yet', 'Noch keine Produkte', 'Aucun produit', 'Nessun prodotto', 'Aún no hay productos'],
  ['لسه مفيش منتجات', 'No items yet', 'Noch keine Artikel', 'Aucun article', 'Nessun articolo', 'Aún no hay artículos'],
  ['اختار المنتج بالباركود', 'Select the product by barcode', 'Produkt per Barcode wählen', 'Choisir le produit par code-barres', 'Seleziona il prodotto', 'Seleccione el producto'],
  ['اكتب الوزن والعدد', 'Enter weight and count', 'Gewicht und Anzahl eingeben', 'Saisir poids et quantité', 'Inserisci peso e quantità', 'Ingrese peso y cantidad'],
  ['اكتب الوزن', 'Enter the weight', 'Gewicht eingeben', 'Saisir le poids', 'Inserisci il peso', 'Ingrese el peso'],
  ['اكتب العدد', 'Enter the count', 'Anzahl eingeben', 'Saisir la quantité', 'Inserisci la quantità', 'Ingrese la cantidad'],
  ['اكتب سعر الجرام', 'Enter price per gram', 'Preis pro Gramm eingeben', 'Saisir le prix au gramme', 'Inserisci il prezzo al grammo', 'Ingrese el precio por gramo'],
  ['المبلغ المدفوع غير صحيح', 'Invalid amount paid', 'Ungültiger Betrag', 'Montant invalide', 'Importo non valido', 'Importe no válido'],
  ['ضيف منتج واحد على الأقل', 'Add at least one item', 'Mindestens einen Artikel hinzufügen', 'Ajoutez au moins un article', 'Aggiungi almeno un articolo', 'Añada al menos un artículo'],
  ['تم البيع', 'Sale completed', 'Verkauf abgeschlossen', 'Vente effectuée', 'Vendita completata', 'Venta realizada'],
  ['تم التسجيل', 'Recorded', 'Erfasst', 'Enregistré', 'Registrato', 'Registrado'],
  ['تم المسح', 'Deleted', 'Gelöscht', 'Supprimé', 'Eliminato', 'Eliminado'],
  ['تم التحويل', 'Converted', 'Umgerechnet', 'Converti', 'Convertito', 'Convertido'],
  ['مسح المنتج من المخزون', 'Delete product from stock', 'Produkt aus Bestand löschen', 'Supprimer du stock', 'Elimina dal magazzino', 'Eliminar del inventario'],
  ['تغيير الصورة', 'Change photo', 'Foto ändern', 'Changer la photo', 'Cambia foto', 'Cambiar foto'],
  ['إضافة صورة', 'Add photo', 'Foto hinzufügen', 'Ajouter une photo', 'Aggiungi foto', 'Añadir foto'],
  ['حذف الصورة', 'Remove photo', 'Foto entfernen', 'Supprimer la photo', 'Rimuovi foto', 'Quitar foto'],
  ['تصوير المنتج', 'Take photo', 'Foto aufnehmen', 'Prendre une photo', 'Scatta foto', 'Tomar foto'],
  ['تعديل الاسم / الوصف', 'Edit name / description', 'Name / Beschreibung ändern', 'Modifier nom / description', 'Modifica nome / descrizione', 'Editar nombre / descripción'],
  ['أوزان القطع وقت الإدخال', 'Piece weights at entry', 'Stückgewichte bei Eingabe', 'Poids des pièces', 'Pesi dei pezzi', 'Pesos de las piezas'],
  ['عليا مديونية', 'I owe', 'Ich schulde', 'Je dois', 'Devo', 'Debo'],
  ['لا توجد مديونية', 'No debt', 'Keine Schulden', 'Aucune dette', 'Nessun debito', 'Sin deuda'],
  ['المحدد', 'Selected', 'Ausgewählt', 'Sélectionné', 'Selezionato', 'Seleccionado'],
  ['اختياري', 'optional', 'optional', 'facultatif', 'facoltativo', 'opcional'],
  ['عيار الكسر', 'Scrap karat', 'Altgold-Karat', 'Carat de la casse', 'Carato rottame', 'Quilates de chatarra'],
  ['مقاس الملصق', 'Label size', 'Etikettengröße', "Taille de l'étiquette", 'Formato etichetta', 'Tamaño de etiqueta'],
  ['عدد النسخ', 'Copies', 'Kopien', 'Copies', 'Copie', 'Copias'],
  ['رقم', 'No.', 'Nr.', 'N°', 'N.', 'N.º'],
  ['اللغة', 'Language', 'Sprache', 'Langue', 'Lingua', 'Idioma'],
  ['الهدف', 'Target', 'Ziel', 'Objectif', 'Obiettivo', 'Objetivo'],
  ['رقم النسخة', 'Version', 'Version', 'Version', 'Versione', 'Versión'],
];

final Map<String, String> _trCache = {};
List<(RegExp, List<String>)>? _rx;
const Map<String, int> _langIdx = {'en': 1, 'de': 2, 'fr': 3, 'it': 4, 'es': 5};

String trText(String s) {
  final idx = _langIdx[appLang.value];
  if (idx == null) return s;
  final key = '${appLang.value}|$s';
  final hit = _trCache[key];
  if (hit != null) return hit;
  _rx ??= [
    for (final e in ([..._dict]..sort((a, b) => b[0].length.compareTo(a[0].length))))
      (RegExp('(?<![\u0621-\u064A])${RegExp.escape(e[0])}(?![\u0621-\u064A])'), e),
  ];
  var out = s;
  for (final r in _rx!) {
    out = out.replaceAll(r.$1, r.$2[idx]);
  }
  _trCache[key] = out;
  return out;
}

/// نص بيترجم نفسه حسب اللغة المختارة
class Text extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  const Text(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines,
    this.overflow,
    this.softWrap,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appLang,
      builder: (_, __, ___) => m.Text(
        trText(data),
        style: style,
        textAlign: textAlign,
        textDirection: textDirection,
        maxLines: maxLines,
        overflow: overflow,
        softWrap: softWrap,
      ),
    );
  }
}

class Prefs {
  static String shopName = 'محل الجواهر';
  static String shopPhone = '';
  static String shopAddress = '';
  static String paper = '80';
  static double targetGold = 0.0;
  static double targetSilver = 0.0;

  static double target(String metal) => metal == 'gold' ? targetGold : targetSilver;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    shopName = p.getString('shopName') ?? shopName;
    shopPhone = p.getString('shopPhone') ?? shopPhone;
    shopAddress = p.getString('shopAddress') ?? shopAddress;
    paper = p.getString('paper') ?? paper;
    targetGold = p.getDouble('targetGold') ?? 0.0;
    targetSilver = p.getDouble('targetSilver') ?? 0.0;
    appLang.value = p.getString('lang') ?? 'ar';
    appDark.value = p.getBool('dark') ?? true;
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('shopName', shopName);
    await p.setString('shopPhone', shopPhone);
    await p.setString('shopAddress', shopAddress);
    await p.setString('paper', paper);
    await p.setDouble('targetGold', targetGold);
    await p.setDouble('targetSilver', targetSilver);
    await p.setString('lang', appLang.value);
    await p.setBool('dark', appDark.value);
  }
}

ThemeData buildTheme(bool dark) {
  const gold = Color(0xFFD4AF37);
  var scheme = ColorScheme.fromSeed(
    seedColor: gold,
    brightness: dark ? Brightness.dark : Brightness.light,
  );
  scheme = dark
      ? scheme.copyWith(surface: const Color(0xFF0F1526), primary: gold, onPrimary: Colors.black)
      : scheme.copyWith(primary: const Color(0xFF8A6D00));
  return ThemeData(useMaterial3: true, colorScheme: scheme, visualDensity: VisualDensity.standard);
}

class FlagIcon extends StatelessWidget {
  final String lang;
  final double w;
  const FlagIcon(this.lang, {super.key, this.w = 30});
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(width: w, height: w * 2 / 3, child: CustomPaint(painter: _FlagPainter(lang))),
    );
  }
}

class _FlagPainter extends CustomPainter {
  final String lang;
  _FlagPainter(this.lang);

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    void rect(double x, double y, double rw, double rh, Color c) =>
        canvas.drawRect(Rect.fromLTWH(x, y, rw, rh), Paint()..color = c);
    switch (lang) {
      case 'ar':
        rect(0, 0, w, h / 3, const Color(0xFFCE1126));
        rect(0, h / 3, w, h / 3, Colors.white);
        rect(0, 2 * h / 3, w, h / 3, Colors.black);
        break;
      case 'de':
        rect(0, 0, w, h / 3, Colors.black);
        rect(0, h / 3, w, h / 3, const Color(0xFFDD0000));
        rect(0, 2 * h / 3, w, h / 3, const Color(0xFFFFCE00));
        break;
      case 'fr':
        rect(0, 0, w / 3, h, const Color(0xFF0055A4));
        rect(w / 3, 0, w / 3, h, Colors.white);
        rect(2 * w / 3, 0, w / 3, h, const Color(0xFFEF4135));
        break;
      case 'it':
        rect(0, 0, w / 3, h, const Color(0xFF009246));
        rect(w / 3, 0, w / 3, h, Colors.white);
        rect(2 * w / 3, 0, w / 3, h, const Color(0xFFCE2B37));
        break;
      case 'es':
        rect(0, 0, w, h * 0.25, const Color(0xFFAA151B));
        rect(0, h * 0.25, w, h * 0.5, const Color(0xFFF1BF00));
        rect(0, h * 0.75, w, h * 0.25, const Color(0xFFAA151B));
        break;
      default:
        rect(0, 0, w, h, const Color(0xFF012169));
        final white = Paint()
          ..color = Colors.white
          ..strokeWidth = h * 0.22;
        canvas.drawLine(const Offset(0, 0), Offset(w, h), white);
        canvas.drawLine(Offset(w, 0), Offset(0, h), white);
        final red = Paint()
          ..color = const Color(0xFFC8102E)
          ..strokeWidth = h * 0.08;
        canvas.drawLine(const Offset(0, 0), Offset(w, h), red);
        canvas.drawLine(Offset(w, 0), Offset(0, h), red);
        rect(w * 0.4, 0, w * 0.2, h, Colors.white);
        rect(0, h * 0.38, w, h * 0.24, Colors.white);
        rect(w * 0.44, 0, w * 0.12, h, const Color(0xFFC8102E));
        rect(0, h * 0.43, w, h * 0.14, const Color(0xFFC8102E));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

const List<(String, String)> _languages = [
  ('ar', 'العربية'),
  ('en', 'English'),
  ('de', 'Deutsch'),
  ('fr', 'Français'),
  ('it', 'Italiano'),
  ('es', 'Español'),
];

void pickLanguage() {
  final ctx = navKey.currentContext;
  if (ctx == null) return;
  showDialog<void>(
    context: ctx,
    builder: (dctx) => SimpleDialog(
      title: const m.Text('Language / اللغة'),
      children: [
        for (final l in _languages)
          SimpleDialogOption(
            onPressed: () {
              appLang.value = l.$1;
              Prefs.save();
              Navigator.pop(dctx);
            },
            child: Row(children: [FlagIcon(l.$1), const SizedBox(width: 12), m.Text(l.$2)]),
          ),
      ],
    ),
  );
}

/// أزرار فوق: اللغة (بالأعلام) + وضع فاتح/داكن
class TopTools extends StatelessWidget {
  const TopTools({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: pickLanguage,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: ValueListenableBuilder<String>(
                valueListenable: appLang,
                builder: (_, l, __) => FlagIcon(l, w: 26),
              ),
            ),
          ),
          const SizedBox(width: 4),
          ValueListenableBuilder<bool>(
            valueListenable: appDark,
            builder: (_, d, __) => IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              color: Colors.white,
              icon: Icon(d ? Icons.light_mode : Icons.dark_mode),
              onPressed: () {
                appDark.value = !d;
                Prefs.save();
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= التحديث التلقائي =======================

class Updater {
  static bool checking = false;

  static void _toast(String s) {
    final c = navKey.currentContext;
    if (c != null) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(s)));
  }

  static Future<File?> _download(String url, String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'jawaher-app');
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final f = File(path);
    await res.pipe(f.openWrite());
    return f;
  }

  static Future<void> check({bool manual = false}) async {
    if (checking) return;
    checking = true;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$kRepo/releases/tags/latest'));
      req.headers.set('User-Agent', 'jawaher-app');
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close();
      if (res.statusCode != 200) {
        if (manual) _toast('تعذر فحص التحديث');
        return;
      }
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final remote = int.tryParse(RegExp(r'\d+').firstMatch('${j['name']}')?.group(0) ?? '') ?? 0;
      if (remote <= kBuild) {
        if (manual) _toast('أنت على آخر نسخة');
        return;
      }
      final assets = ((j['assets'] ?? []) as List).cast<Map<String, dynamic>>();
      String? urlOf(String name) {
        for (final a in assets) {
          if (a['name'] == name) return a['browser_download_url'] as String?;
        }
        return null;
      }

      if (Platform.isWindows) {
        final u = urlOf('Jawaher-Setup.exe');
        if (u != null) await _windows(u);
      } else if (Platform.isAndroid) {
        final u = urlOf('Jawaher-Android.apk');
        if (u != null) await _android(u);
      }
    } catch (_) {
      if (manual) _toast('تعذر فحص التحديث');
    } finally {
      checking = false;
    }
  }

  static Future<void> _windows(String url) async {
    final ctx = navKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('جاري تحديث البرنامج... لا تغلقه')),
          ],
        ),
      ),
    );
    final path = '${Directory.systemTemp.path}${Platform.pathSeparator}Jawaher-Setup.exe';
    File? f;
    try {
      f = await _download(url, path);
    } catch (_) {}
    if (f == null || await f.length() < 1000000) {
      navKey.currentState?.pop();
      return;
    }
    await Process.start(
      'cmd',
      ['/c', 'ping -n 3 127.0.0.1 >nul & "$path" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }

  static Future<void> _android(String url) async {
    final ctx = navKey.currentContext;
    if (ctx == null) return;
    final go = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('تحديث جديد متاح'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('لاحقاً')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('تحديث الآن')),
        ],
      ),
    );
    if (go == true) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}


// ======================= الإعدادات =======================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final shop = TextEditingController(text: Prefs.shopName);
  final phone = TextEditingController(text: Prefs.shopPhone);
  final address = TextEditingController(text: Prefs.shopAddress);
  final tGold = TextEditingController(text: Prefs.targetGold > 0 ? Prefs.targetGold.toStringAsFixed(0) : '');
  final tSilver = TextEditingController(text: Prefs.targetSilver > 0 ? Prefs.targetSilver.toStringAsFixed(0) : '');
  String paper = Prefs.paper;

  Future<void> _save() async {
    Prefs.shopName = shop.text.trim();
    Prefs.shopPhone = phone.text.trim();
    Prefs.shopAddress = address.text.trim();
    Prefs.paper = paper;
    Prefs.targetGold = parseNum(tGold) ?? 0.0;
    Prefs.targetSilver = parseNum(tSilver) ?? 0.0;
    await Prefs.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الحفظ')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          tf('اسم المحل', shop, type: TextInputType.text),
          tf('رقم تليفون المحل', phone, type: TextInputType.phone),
          tf('عنوان المحل', address, type: TextInputType.text),
          DropdownButtonFormField<String>(
            value: paper,
            decoration: const InputDecoration(label: Text('مقاس ورق الطباعة'), border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: '58', child: m.Text('58 mm')),
              DropdownMenuItem(value: '80', child: m.Text('80 mm')),
              DropdownMenuItem(value: 'A5', child: m.Text('A5')),
              DropdownMenuItem(value: 'A4', child: m.Text('A4')),
            ],
            onChanged: (v) => setState(() => paper = v ?? '80'),
          ),
          const SizedBox(height: 12),
          tf('الهدف الشهري - الذهب', tGold),
          tf('الهدف الشهري - الفضة', tSilver),
          FilledButton(
            onPressed: _save,
            child: const Padding(padding: EdgeInsets.all(12), child: Text('حفظ')),
          ),
          const Divider(height: 36),
          OutlinedButton.icon(
            onPressed: () => Updater.check(manual: true),
            icon: const Icon(Icons.system_update),
            label: const Text('فحص التحديث الآن'),
          ),
          const SizedBox(height: 8),
          Center(child: Text('رقم النسخة: $kBuild')),
        ],
      ),
    );
  }
}

// ======================= الفاتورة والطباعة =======================

Future<void> printPng(
  Uint8List png,
  int imgW,
  int imgH,
  PdfPageFormat fmt,
  String name, {
  int copies = 1,
  bool roll = true,
}) async {
  final doc = pw.Document();
  final image = pw.MemoryImage(png);
  for (var i = 0; i < copies; i++) {
    doc.addPage(
      pw.Page(
        pageFormat: fmt,
        margin: roll ? const pw.EdgeInsets.all(0) : const pw.EdgeInsets.all(24),
        build: (_) => pw.Align(
          alignment: pw.Alignment.topCenter,
          child: pw.Image(image, fit: roll ? pw.BoxFit.fill : pw.BoxFit.fitWidth),
        ),
      ),
    );
  }
  await Printing.layoutPdf(onLayout: (_) async => doc.save(), name: name, format: fmt);
}

class InvoiceScreen extends StatefulWidget {
  final Map<String, dynamic> op;
  final bool isSale;
  const InvoiceScreen({super.key, required this.op, required this.isSale});
  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen> {
  final key = GlobalKey();
  String paper = Prefs.paper;

  double get _w {
    switch (paper) {
      case '58':
        return 232.0;
      case '80':
        return 320.0;
      case 'A5':
        return 480.0;
      default:
        return 620.0;
    }
  }

  Future<void> _print() async {
    final b = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return;
    final img = await b.toImage(pixelRatio: 3.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) return;
    final roll = paper == '58' || paper == '80';
    PdfPageFormat fmt;
    if (roll) {
      final wpt = (paper == '58' ? 58.0 : 80.0) * PdfPageFormat.mm;
      fmt = PdfPageFormat(wpt, wpt * img.height / img.width, marginAll: 0);
    } else {
      fmt = paper == 'A5' ? PdfPageFormat.a5 : PdfPageFormat.a4;
    }
    await printPng(bd.buffer.asUint8List(), img.width, img.height, fmt, '${widget.op['serial'] ?? 'invoice'}',
        roll: roll);
  }

  Widget _row(String a, String b, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(a, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.bold : FontWeight.normal))),
            Text(b, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      );

  Widget _cell(String t, int flex, {bool bold = false}) => Expanded(
        flex: flex,
        child: Text(t,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
      );

  Widget _invoice() {
    final op = widget.op;
    final isSale = widget.isSale;
    final lines = linesOf(op, isSale);
    final ts = (op['ts'] as Timestamp).toDate();
    final when = '${ts.year}-${_two(ts.month)}-${_two(ts.day)}  ${_two(ts.hour)}:${_two(ts.minute)}';
    final total = nd(isSale ? op['total'] : op['price']);
    final paid = nd(op['paid']);
    final rest = total - paid;
    final fee = isSale ? nd(op['fee']) : 0.0;
    final cust = [op['customerName'], op['customerPhone']].where((e) => e != null && '$e'.isNotEmpty).join(' - ');
    return DefaultTextStyle(
      style: const TextStyle(color: Colors.black, fontSize: 12),
      child: Container(
        width: _w,
        color: Colors.white,
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Prefs.shopName,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (Prefs.shopPhone.isNotEmpty)
              Text(Prefs.shopPhone, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
            if (Prefs.shopAddress.isNotEmpty)
              Text(Prefs.shopAddress, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
            const Divider(color: Colors.black54),
            Text(isSale ? 'فاتورة بيع' : 'إيصال شراء',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            _row('رقم', '${op['serial'] ?? '-'}', bold: true),
            _row(when, ''),
            if (cust.isNotEmpty) _row('العميل', cust),
            const Divider(color: Colors.black54),
            Row(children: [
              _cell('الصنف', 4, bold: true),
              _cell('الوزن', 2, bold: true),
              _cell('العدد', 1, bold: true),
              _cell('الإجمالي', 2, bold: true),
            ]),
            const Divider(color: Colors.black26, height: 8),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  _cell(
                    l['scrap'] == true
                        ? '${metalNames[op['metal']] ?? ''} عيار ${l['karat']}'
                        : 'عيار ${l['karat']}',
                    4,
                  ),
                  _cell(money(nd(l['weight'])), 2),
                  _cell(l['scrap'] == true || (l['count'] ?? 0) == 0 ? '-' : '${l['count']}', 1),
                  _cell(money(nd(isSale ? l['total'] : (l['price'] ?? l['total'] ?? 0))), 2),
                ]),
              ),
            const Divider(color: Colors.black54),
            if (fee > 0.005) _row('المصنعية', money(fee)),
            _row('الإجمالي', money(total), bold: true),
            _row('المدفوع', money(paid)),
            if (rest > 0.005) _row('المتبقي', money(rest), bold: true),
            _row('طريقة الدفع', payLabel(op['payMethod'])),
            const Divider(color: Colors.black54),
            const Text('شكراً لتعاملكم معنا', textAlign: TextAlign.center, style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الفاتورة')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Text('مقاس ورق الطباعة'),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: paper,
                  items: const [
                    DropdownMenuItem(value: '58', child: m.Text('58 mm')),
                    DropdownMenuItem(value: '80', child: m.Text('80 mm')),
                    DropdownMenuItem(value: 'A5', child: m.Text('A5')),
                    DropdownMenuItem(value: 'A4', child: m.Text('A4')),
                  ],
                  onChanged: (v) => setState(() => paper = v ?? '80'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _print,
                  icon: const Icon(Icons.print),
                  label: const Text('طباعة'),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Center(child: RepaintBoundary(key: key, child: _invoice())),
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= ملصق الباركود =======================

class LabelScreen extends StatefulWidget {
  final String barcode;
  final int karat;
  final int copies;
  const LabelScreen({super.key, required this.barcode, required this.karat, this.copies = 1});
  @override
  State<LabelScreen> createState() => _LabelScreenState();
}

class _LabelScreenState extends State<LabelScreen> {
  final key = GlobalKey();
  String size = '50x30';
  late final TextEditingController copies = TextEditingController(text: '${widget.copies < 1 ? 1 : widget.copies}');

  (double, double) get _mm {
    final p = size.split('x');
    return (double.parse(p[0]), double.parse(p[1]));
  }

  Future<void> _print() async {
    final b = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return;
    final img = await b.toImage(pixelRatio: 4.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) return;
    final fmt = PdfPageFormat(_mm.$1 * PdfPageFormat.mm, _mm.$2 * PdfPageFormat.mm, marginAll: 0);
    final n = (int.tryParse(copies.text.trim()) ?? 1).clamp(1, 500);
    await printPng(bd.buffer.asUint8List(), img.width, img.height, fmt, widget.barcode, copies: n);
  }

  @override
  Widget build(BuildContext context) {
    final w = _mm.$1 * 6, h = _mm.$2 * 6;
    return Scaffold(
      appBar: AppBar(title: const Text('طباعة ملصق الباركود')),
      body: PageList(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            value: size,
            decoration: const InputDecoration(label: Text('مقاس الملصق'), border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: '40x25', child: m.Text('40 x 25 mm')),
              DropdownMenuItem(value: '50x30', child: m.Text('50 x 30 mm')),
              DropdownMenuItem(value: '58x40', child: m.Text('58 x 40 mm')),
              DropdownMenuItem(value: '60x40', child: m.Text('60 x 40 mm')),
              DropdownMenuItem(value: '70x40', child: m.Text('70 x 40 mm')),
            ],
            onChanged: (v) => setState(() => size = v ?? '50x30'),
          ),
          const SizedBox(height: 12),
          tf('عدد النسخ', copies, type: TextInputType.number),
          Center(
            child: RepaintBoundary(
              key: key,
              child: Container(
                width: w,
                height: h,
                color: Colors.white,
                padding: const EdgeInsets.all(6),
                child: DefaultTextStyle(
                  style: const TextStyle(color: Colors.black, fontSize: 10),
                  child: Column(
                    children: [
                      Text(Prefs.shopName, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                      Expanded(
                        child: BarcodeWidget(
                          barcode: Barcode.code128(),
                          data: widget.barcode,
                          drawText: true,
                          style: const TextStyle(fontSize: 9, color: Colors.black),
                        ),
                      ),
                      Text('عيار ${widget.karat}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _print,
            icon: const Icon(Icons.print),
            label: const Padding(padding: EdgeInsets.all(12), child: Text('طباعة')),
          ),
        ],
      ),
    );
  }
}

// ======================= الإحصائيات =======================

class _LinePainter extends CustomPainter {
  final List<double> v;
  final Color color;
  _LinePainter(this.v, this.color);
  @override
  void paint(Canvas canvas, Size s) {
    if (v.isEmpty) return;
    final maxV = v.reduce((a, b) => a > b ? a : b);
    final top = maxV <= 0 ? 1.0 : maxV;
    final dx = v.length > 1 ? s.width / (v.length - 1) : s.width;
    final path = Path();
    final fill = Path();
    for (var i = 0; i < v.length; i++) {
      final x = i * dx;
      final y = s.height - (v[i] / top) * (s.height - 8) - 4;
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, s.height);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo((v.length - 1) * dx, s.height);
    fill.close();
    canvas.drawPath(fill, Paint()..color = color.withAlpha(50));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => old.v != v || old.color != color;
}

class _BarPainter extends CustomPainter {
  final List<double> v;
  final Color color;
  _BarPainter(this.v, this.color);
  @override
  void paint(Canvas canvas, Size s) {
    if (v.isEmpty) return;
    final maxV = v.reduce((a, b) => a > b ? a : b);
    final top = maxV <= 0 ? 1.0 : maxV;
    final slot = s.width / v.length;
    for (var i = 0; i < v.length; i++) {
      final h = (v[i] / top) * (s.height - 6);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * slot + slot * 0.2, s.height - h, slot * 0.6, h < 2 ? 2 : h),
        const Radius.circular(4),
      );
      canvas.drawRRect(r, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => old.v != v || old.color != color;
}

class _DonutPainter extends CustomPainter {
  final List<double> parts;
  final List<Color> colors;
  _DonutPainter(this.parts, this.colors);
  @override
  void paint(Canvas canvas, Size s) {
    final total = parts.fold<double>(0.0, (a, b) => a + b);
    final rect = Rect.fromLTWH(14, 14, s.width - 28, s.height - 28);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 26;
    if (total <= 0) {
      canvas.drawArc(rect, 0, 6.2831, false, base..color = Colors.grey.withAlpha(80));
      return;
    }
    var start = -1.5708;
    for (var i = 0; i < parts.length; i++) {
      final sweep = parts[i] / total * 6.2831;
      canvas.drawArc(rect, start, sweep, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 26
        ..color = colors[i % colors.length]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => old.parts != parts;
}

class StatsScreen extends StatefulWidget {
  final String metal;
  const StatsScreen({super.key, required this.metal});
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month, 1);

  void _shift(int d) => setState(() => month = DateTime(month.year, month.month + d, 1));

  Widget _kpi(String title, String value, {String? sub, Color? subColor}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              if (sub != null) Text(sub, style: TextStyle(fontSize: 12, color: subColor)),
            ],
          ),
        ),
      );

  Widget _chartCard(String title, Widget chart) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              chart,
            ],
          ),
        ),
      );

  Widget _body(BuildContext context, MultiData d) {
    final scheme = Theme.of(context).colorScheme;
    bool inMonth(Map<String, dynamic> m, DateTime ms) {
      final t = (m['ts'] as Timestamp).toDate();
      return t.year == ms.year && t.month == ms.month;
    }

    double sum(Iterable<Map<String, dynamic>> l, String k) => l.fold<double>(0.0, (a, m) => a + nd(m[k]));
    final prev = DateTime(month.year, month.month - 1, 1);
    final sales = d.sales.where((m) => inMonth(m, month)).toList();
    final prevSales = d.sales.where((m) => inMonth(m, prev)).toList();
    final cur = sum(sales, 'total');
    final prv = sum(prevSales, 'total');
    final growth = prv > 0 ? (cur - prv) / prv * 100 : (cur > 0 ? 100.0 : 0.0);
    final customers = <String>{
      for (final m in sales)
        if (custKey(m).isNotEmpty) custKey(m),
    }.length;
    final avg = sales.isEmpty ? 0.0 : cur / sales.length;
    final purchases = sum(d.purchases.where((m) => inMonth(m, month)), 'price');
    final expenses = sum(d.expenses.where((m) => inMonth(m, month)), 'amount');

    final days = DateTime(month.year, month.month + 1, 0).day;
    final daily = List<double>.filled(days, 0.0);
    for (final m in sales) {
      daily[(m['ts'] as Timestamp).toDate().day - 1] += nd(m['total']);
    }
    final months = List<double>.filled(12, 0.0);
    for (final m in d.sales) {
      final t = (m['ts'] as Timestamp).toDate();
      if (t.year == month.year) months[t.month - 1] += nd(m['total']);
    }
    final byKarat = <int, double>{};
    for (final m in sales) {
      for (final l in linesOf(m, true)) {
        final k = (l['karat'] as num?)?.toInt() ?? 0;
        byKarat[k] = (byKarat[k] ?? 0.0) + nd(l['total'] ?? 0);
      }
    }
    final karats = byKarat.keys.toList()..sort();
    const palette = [Color(0xFF4F8EF7), Color(0xFFD4AF37), Color(0xFF2FBF71), Color(0xFFE5575A), Color(0xFF9B6BFF)];
    final target = Prefs.target(widget.metal);
    final pct = target > 0 ? cur / target * 100 : 0.0;

    return PageList(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _shift(-1)),
            Text('${month.year}-${_two(month.month)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shift(1)),
          ],
        ),
        LayoutBuilder(builder: (c, cons) {
          final cols = cons.maxWidth > 700 ? 4 : 2;
          final w = (cons.maxWidth - 12 * (cols - 1)) / cols;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: w,
                child: _kpi('إجمالي المبيعات', money(cur),
                    sub: '${growth >= 0 ? '+' : ''}${growth.toStringAsFixed(1)}%',
                    subColor: growth >= 0 ? Colors.green : Colors.red),
              ),
              SizedBox(width: w, child: _kpi('عدد الفواتير', '${sales.length}')),
              SizedBox(width: w, child: _kpi('عدد العملاء', '$customers')),
              SizedBox(width: w, child: _kpi('متوسط الفاتورة', money(avg))),
              SizedBox(width: w, child: _kpi('إجمالي المشتريات', money(purchases))),
              SizedBox(width: w, child: _kpi('مصاريف', money(expenses))),
            ],
          );
        }),
        const SizedBox(height: 8),
        _chartCard(
          'المبيعات اليومية',
          SizedBox(height: 170, width: double.infinity, child: CustomPaint(painter: _LinePainter(daily, scheme.primary))),
        ),
        _chartCard(
          'المبيعات الشهرية',
          SizedBox(height: 170, width: double.infinity, child: CustomPaint(painter: _BarPainter(months, scheme.primary))),
        ),
        _chartCard(
          'توزيع المبيعات حسب العيار',
          Row(
            children: [
              SizedBox(
                width: 150,
                height: 150,
                child: CustomPaint(painter: _DonutPainter([for (final k in karats) byKarat[k]!], palette)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < karats.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Container(width: 12, height: 12, color: palette[i % palette.length]),
                          const SizedBox(width: 8),
                          Text('عيار ${karats[i]}: ${money(byKarat[karats[i]]!)}'),
                        ]),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _chartCard(
          'نسبة تحقيق الهدف',
          Row(
            children: [
              SizedBox(
                width: 110,
                height: 110,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 110,
                      height: 110,
                      child: CircularProgressIndicator(
                        value: target > 0 ? (pct / 100).clamp(0.0, 1.0) : 0.0,
                        strokeWidth: 12,
                      ),
                    ),
                    Text('${pct.toStringAsFixed(0)}%', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(target > 0 ? 'الهدف الشهري: ${money(target)}' : 'حدد الهدف من الإعدادات'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 60),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('إحصائيات ${metalNames[widget.metal]}')),
      body: Multi(metal: widget.metal, builder: (ctx, d) => _body(ctx, d)),
    );
  }
}

// ======================= التجار والموردين =======================

class SuppliersScreen extends StatelessWidget {
  final String metal;
  const SuppliersScreen({super.key, required this.metal});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('التجار والموردين - ${metalNames[metal]}')),
      body: Multi(
        metal: metal,
        builder: (context, d) {
          final byName = <String, List<Map<String, dynamic>>>{};
          for (final m in d.purchases) {
            final s = '${m['supplier'] ?? ''}'.trim();
            if (s.isEmpty) continue;
            byName.putIfAbsent(s, () => <Map<String, dynamic>>[]).add(m);
          }
          if (byName.isEmpty) return emptyNote('لا يوجد تجار أو موردين بعد');
          final rows = <(String, double, double, int, double)>[];
          byName.forEach((name, list) {
            var owed = 0.0, total = 0.0, weight = 0.0;
            var pieces = 0;
            for (final m in list) {
              owed += d.restOf(m, false);
              total += nd(m['price']);
              weight += nd(m['weight']);
              for (final l in linesOf(m, false)) {
                if (l['scrap'] != true) pieces += (l['count'] as num?)?.toInt() ?? 0;
              }
            }
            rows.add((name, owed, total, pieces, weight));
          });
          rows.sort((a, b) => b.$2.compareTo(a.$2));
          return PageList(
            padding: const EdgeInsets.all(12),
            children: [
              for (final r in rows)
                Card(
                  child: ListTile(
                    title: Text(r.$1),
                    subtitle: Text('${r.$4} قطعة | ${money(r.$5)} جم | إجمالي المشتريات ${money(r.$3)}'),
                    trailing: Text(
                      r.$2 > 0.005 ? 'علينا ${money(r.$2)}' : 'خالص',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: r.$2 > 0.005 ? Colors.red : Colors.green,
                      ),
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => SupplierDetailScreen(metal: metal, name: r.$1)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class SupplierDetailScreen extends StatelessWidget {
  final String metal, name;
  const SupplierDetailScreen({super.key, required this.metal, required this.name});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Multi(
        metal: metal,
        builder: (context, d) {
          final ps = d.purchases.where((m) => '${m['supplier'] ?? ''}'.trim() == name).toList();
          var owed = 0.0, total = 0.0;
          for (final m in ps) {
            owed += d.restOf(m, false);
            total += nd(m['price']);
          }
          return PageList(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('إجمالي المشتريات: ${money(total)}'),
                      const SizedBox(height: 4),
                      Text('الواقف على التاجر: ${money(owed)}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              if (owed > 0.005)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.payments),
                    label: const Padding(padding: EdgeInsets.all(10), child: Text('تسجيل دفعة للتاجر')),
                    onPressed: () async {
                      final v = await askAmount(context, 'دفعة للتاجر $name', owed);
                      if (v == null) return;
                      var left = v;
                      final asc = [...ps]
                        ..sort((a, b) => (a['ts'] as Timestamp).compareTo(b['ts'] as Timestamp));
                      for (final m in asc) {
                        if (left <= 0.005) break;
                        final rest = d.restOf(m, false);
                        if (rest <= 0.005) continue;
                        final pay = rest < left ? rest : left;
                        Ops.addPayment(
                          metal: metal,
                          kind: 'purchase',
                          refId: m['id'] as String,
                          amount: pay,
                          customerName: name,
                          customerPhone: '',
                        );
                        left -= pay;
                      }
                    },
                  ),
                ),
              for (final m in ps)
                Card(
                  child: ListTile(
                    title: Text(fmtDate(m['ts'] as Timestamp)),
                    subtitle: Text([
                      for (final l in linesOf(m, false))
                        '• عيار ${l['karat']} | ${money(nd(l['weight']))} جم | ${l['count'] ?? '-'} قطعة | بـ ${money(nd(l['price'] ?? 0))}',
                    ].join('\n')),
                    trailing: Text(
                      d.restOf(m, false) > 0.005 ? 'باقي ${money(d.restOf(m, false))}' : 'مدفوع',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: d.restOf(m, false) > 0.005 ? Colors.red : Colors.green,
                      ),
                    ),
                    onTap: () => opActions(context, m, false, d),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ======================= سهمين فوق وتحت =======================

class PageList extends StatefulWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  const PageList({super.key, required this.children, this.padding});
  @override
  State<PageList> createState() => _PageListState();
}

class _PageListState extends State<PageList> {
  final c = ScrollController();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _go(bool top) {
    if (!c.hasClients) return;
    final p = c.position;
    c.animateTo(
      top ? p.minScrollExtent : p.maxScrollExtent,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  Widget _btn(IconData icon, bool top) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _go(top),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 22, color: Colors.white),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ListView(controller: c, padding: widget.padding, children: widget.children),
        Positioned(
          right: 8,
          bottom: 14,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _btn(Icons.keyboard_arrow_up, true),
              const SizedBox(height: 6),
              _btn(Icons.keyboard_arrow_down, false),
            ],
          ),
        ),
      ],
    );
  }
}
