import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart' show MobileScanner;
import 'package:shared_preferences/shared_preferences.dart';
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
    );
  }

  List<int> get available => [for (var n = 0; n < weights.length; n++) if (!soldIdx.contains(n)) n];

  Uint8List? get photoBytes => photo.isEmpty ? null : base64Decode(photo);
}

class Store {
  static String user = '';

  static final _db = FirebaseFirestore.instance;

  static CollectionReference<Map<String, dynamic>> get items =>
      _db.collection('users').doc(user).collection('items');

  /// الذهب والفضة منفصلين بالـ metal
  static Stream<List<Item>> watchItems(String metal) => items
      .where('metal', isEqualTo: metal)
      .snapshots()
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
    items.doc().set({
      'metal': metal,
      'karat': karat,
      'name': name,
      'barcode': barcode,
      'photo': photo,
      'weights': weights,
      'remaining': weights.fold<double>(0, (a, b) => a + b),
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
    );
  }
}


class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('تغيير اليوزر؟'),
        content: const Text('الداتا هتفضل محفوظة، بس هتحتاج تكتب اليوزر تاني.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('تأكيد')),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('username');
    if (!context.mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('المحل: ${Store.user}'),
        actions: [IconButton(icon: const Icon(Icons.logout), onPressed: () => _logout(context))],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final m in ['gold', 'silver'])
                Expanded(
                  child: Card(
                    color: metalColors[m],
                    child: InkWell(
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => MetalMenuScreen(metal: m))),
                      child: Center(
                        child: Text(metalNames[m]!,
                            style: const TextStyle(fontSize: 36, color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}


class InventoryScreen extends StatelessWidget {
  final String metal;
  const InventoryScreen({super.key, required this.metal});

  @override
  Widget build(BuildContext context) {
    final color = metalColors[metal]!;
    return Scaffold(
      appBar: AppBar(title: Text('مخزون ${metalNames[metal]}'), backgroundColor: color, foregroundColor: Colors.white),
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
          final items = snap.data!;
          if (items.isEmpty) return const Center(child: Text('مفيش منتجات لسه'));
          final totals = <int, double>{};
          for (final i in items) {
            totals[i.karat] = (totals[i.karat] ?? 0) + i.remaining;
          }
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(spacing: 8, children: [
                for (final k in karatsOf(metal))
                  Chip(label: Text('عيار $k: ${(totals[k] ?? 0).toStringAsFixed(2)} جم')),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, n) {
                  final i = items[n];
                  return ListTile(
                    leading: i.photoBytes == null
                        ? const Icon(Icons.image_not_supported, size: 40)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(i.photoBytes!, width: 50, height: 50, fit: BoxFit.cover)),
                    title: Text('عيار ${i.karat}${i.name.isEmpty ? '' : ' - ${i.name}'}'),
                    subtitle: Text('${i.available.length} قطعة | المتبقي ${i.remaining.toStringAsFixed(2)} جم'),
                    trailing: Text(i.barcode, textDirection: TextDirection.ltr),
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => ItemDetailScreen(item: i))),
                  );
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class ItemDetailScreen extends StatelessWidget {
  final Item item;
  const ItemDetailScreen({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('عيار ${item.karat} ${item.name}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (item.photoBytes != null)
          Center(child: Image.memory(item.photoBytes!, height: 220)),
        const SizedBox(height: 16),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: BarcodeWidget(
              barcode: Barcode.code128(), data: item.barcode, height: 90, drawText: true),
        ),
        const SizedBox(height: 16),
        Text('المتبقي: ${item.remaining.toStringAsFixed(2)} جم',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('أوزان القطع وقت الإدخال:'),
        for (var n = 0; n < item.weights.length; n++)
          ListTile(dense: true, title: Text('قطعة ${n + 1}'), trailing: Text('${item.weights[n]} جم')),
      ]),
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
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('إضافة منتج ${metalNames[widget.metal]}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
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
          decoration: const InputDecoration(labelText: 'العيار', border: OutlineInputBorder()),
          items: [for (final k in karatsOf(widget.metal)) DropdownMenuItem(value: k, child: Text('عيار $k'))],
          onChanged: (v) => setState(() {
            karat = v!;
            _barcode = Store.newBarcode(widget.metal, karat);
          }),
        ),
        const SizedBox(height: 12),
        TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'وصف (اختياري) مثال: خاتم', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(
          controller: _count,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'العدد', border: OutlineInputBorder()),
          onChanged: _onCount,
        ),
        const SizedBox(height: 12),
        for (var n = 0; n < _weights.length; n++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: _weights[n],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'وزن القطعة ${n + 1} (جرام)', border: const OutlineInputBorder()),
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
        FilledButton(onPressed: _save, child: const Padding(padding: EdgeInsets.all(12), child: Text('حفظ'))),
      ]),
    );
  }
}



Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true, // الداتا تتحفظ على الجهاز وتشتغل من غير نت
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  final prefs = await SharedPreferences.getInstance();
  final user = prefs.getString('username');
  if (user != null) Store.user = user;
  runApp(App(loggedIn: user != null));
}

class App extends StatelessWidget {
  final bool loggedIn;
  const App({super.key, required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'محل الذهب والفضة',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFFB8860B), useMaterial3: true),
      builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: loggedIn ? const HomeScreen() : const LoginScreen(),
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
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      onChanged: (_) => onChanged?.call(),
    ),
  );
}

/// عمليات البيع والشراء. بنستخدم batch من غير await عشان تشتغل من غير نت.
class Ops {
  static CollectionReference<Map<String, dynamic>> col(String name) =>
      FirebaseFirestore.instance.collection('users').doc(Store.user).collection(name);

  static Stream<List<Map<String, dynamic>>> watch(String name, String metal) =>
      col(name).where('metal', isEqualTo: metal).snapshots().map((s) {
        final l = s.docs.map((d) => <String, dynamic>{...d.data(), 'id': d.id}).toList();
        l.sort((a, b) => (b['ts'] as Timestamp).compareTo(a['ts'] as Timestamp));
        return l;
      });

  static void sell({
    required Item item,
    required double weight,
    required double pricePerGram,
    required double fee,
    required double total,
    required double paid,
    required String customerName,
    required String customerPhone,
    List<int> pieces = const <int>[],
  }) {
    final batch = FirebaseFirestore.instance.batch();
    batch.update(Store.items.doc(item.id), {
      'remaining': FieldValue.increment(-weight),
      if (pieces.isNotEmpty) 'soldIdx': FieldValue.arrayUnion(pieces),
    });
    batch.set(col('sales').doc(), {
      'metal': item.metal,
      'karat': item.karat,
      'barcode': item.barcode,
      'itemId': item.id,
      'pieces': pieces,
      'weight': weight,
      'pricePerGram': pricePerGram,
      'fee': fee,
      'total': total,
      'paid': paid,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'ts': Timestamp.now(),
    });
    batch.commit();
  }

  static void buy({
    Item? existing,
    required String metal,
    required int karat,
    required String barcode,
    required String photo,
    required String desc,
    required double weight,
    required double price,
    required double paid,
    required String customerName,
    required String customerPhone,
    bool cut = false,
  }) {
    final batch = FirebaseFirestore.instance.batch();
    final ref = existing != null ? Store.items.doc(existing.id) : Store.items.doc();
    if (existing != null) {
      batch.update(ref, {
        'remaining': FieldValue.increment(weight),
        'weights': [...existing.weights, weight],
      });
    } else {
      batch.set(ref, {
        'metal': metal,
        'karat': karat,
        'name': desc,
        'barcode': barcode,
        'photo': photo,
        'weights': [weight],
        'remaining': weight,
        'createdAt': Timestamp.now(),
      });
    }
    batch.set(col('purchases').doc(), {
      'metal': metal,
      'karat': karat,
      'barcode': barcode,
      'itemId': ref.id,
      'cut': cut,
      'newItem': existing == null,
      'pieceIdx': existing != null ? existing.weights.length : 0,
      'weight': weight,
      'price': price,
      'paid': paid,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'ts': Timestamp.now(),
    });
    batch.commit();
  }

  static void addPayment({
    required String metal,
    required String kind, // sale | purchase
    required String refId,
    required double amount,
    required String customerName,
    required String customerPhone,
  }) {
    col('payments').doc().set({
      'metal': metal,
      'kind': kind,
      'refId': refId,
      'amount': amount,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'ts': Timestamp.now(),
    });
  }

  static void addExpense({
    required String metal,
    required String type, // expense | salary
    required String title,
    required double amount,
  }) {
    col('expenses').doc().set({
      'metal': metal,
      'type': type,
      'title': title,
      'amount': amount,
      'ts': Timestamp.now(),
    });
  }

  static void deleteSale(Map<String, dynamic> m, List<String> paymentIds) {
    final b = FirebaseFirestore.instance.batch();
    final pieces = ((m['pieces'] ?? []) as List).map((e) => (e as num).toInt()).toList();
    b.update(Store.items.doc(m['itemId'] as String), {
      'remaining': FieldValue.increment(nd(m['weight'])),
      if (pieces.isNotEmpty) 'soldIdx': FieldValue.arrayRemove(pieces),
    });
    b.delete(col('sales').doc(m['id'] as String));
    for (final id in paymentIds) {
      b.delete(col('payments').doc(id));
    }
    b.commit();
  }

  static void deletePurchase(Map<String, dynamic> m, List<String> paymentIds) {
    final b = FirebaseFirestore.instance.batch();
    final idx = m['pieceIdx'];
    b.update(Store.items.doc(m['itemId'] as String), {
      'remaining': FieldValue.increment(-nd(m['weight'])),
      if (idx != null) 'soldIdx': FieldValue.arrayUnion([(idx as num).toInt()]),
    });
    b.delete(col('purchases').doc(m['id'] as String));
    for (final id in paymentIds) {
      b.delete(col('payments').doc(id));
    }
    b.commit();
  }

  static void convert({
    required String metal,
    required Item from,
    required double weight,
    required int toKarat,
    Item? to,
    required double toWeight,
  }) {
    final b = FirebaseFirestore.instance.batch();
    b.update(Store.items.doc(from.id), {'remaining': FieldValue.increment(-weight)});
    final String toBarcode;
    if (to != null) {
      toBarcode = to.barcode;
      b.update(Store.items.doc(to.id), {
        'remaining': FieldValue.increment(toWeight),
        'weights': [...to.weights, toWeight],
      });
    } else {
      toBarcode = Store.newBarcode(metal, toKarat);
      b.set(Store.items.doc(), {
        'metal': metal,
        'karat': toKarat,
        'name': 'محوّل من عيار ${from.karat}',
        'barcode': toBarcode,
        'photo': '',
        'weights': [toWeight],
        'remaining': toWeight,
        'createdAt': Timestamp.now(),
      });
    }
    b.set(col('conversions').doc(), {
      'metal': metal,
      'fromKarat': from.karat,
      'toKarat': toKarat,
      'fromWeight': weight,
      'toWeight': toWeight,
      'fromBarcode': from.barcode,
      'toBarcode': toBarcode,
      'ts': Timestamp.now(),
    });
    b.commit();
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
      (Icons.payments, 'مصاريف وقبض العاملين', ExpensesScreen(metal: metal)),
      (Icons.swap_horiz, 'تحويل بين العيارات', ConvertScreen(metal: metal)),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(metalNames[metal]!),
        backgroundColor: metalColors[metal],
        foregroundColor: Colors.white,
      ),
      body: ListView(
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
  const ItemPicker({super.key, required this.metal, required this.onSelected});

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
        final items = snap.data ?? <Item>[];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Autocomplete<Item>(
            displayStringForOption: (i) => i.barcode,
            optionsBuilder: (v) {
              final q = v.text.trim().toUpperCase();
              return items.where((i) =>
                  q.isEmpty || i.barcode.toUpperCase().contains(q) || '${i.karat}' == q);
            },
            onSelected: onSelected,
            fieldViewBuilder: (ctx, ctrl, focus, submit) => TextField(
              controller: ctrl,
              focusNode: focus,
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
                labelText: 'الباركود (اكتبه أو امسحه أو اختار)',
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
                              'عيار ${i.karat}${i.name.isEmpty ? '' : ' - ${i.name}'} | المتبقي ${money(i.remaining)} جم'),
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
        subtitle: Text('المتبقي: ${money(item.remaining)} جم'),
      ),
    );
  }
}

class SellScreen extends StatefulWidget {
  final String metal;
  const SellScreen({super.key, required this.metal});
  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  Item? item;
  final w = TextEditingController();
  final price = TextEditingController();
  final fee = TextEditingController();
  final paid = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  bool feePerGram = true;
  bool byPiece = false;
  final Set<int> picked = {};

  double get weight => byPiece
      ? picked.fold<double>(0, (a, n) => a + (item?.weights[n] ?? 0))
      : (parseNum(w) ?? 0);
  double get feeTotal => (parseNum(fee) ?? 0) * (feePerGram ? weight : 1);
  double get total => weight * (parseNum(price) ?? 0) + feeTotal;

  void _err(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void save() {
    final it = item;
    if (it == null) return _err('اختار المنتج بالباركود');
    if (byPiece && picked.isEmpty) return _err('اختار القطع اللي اتباعت');
    if (weight <= 0 || weight > it.remaining + 0.0001) {
      return _err('الوزن لازم يكون أكبر من صفر ولا يزيد عن المتبقي (${money(it.remaining)} جم)');
    }
    final p = parseNum(price);
    if (p == null || p <= 0) return _err('اكتب سعر الجرام');
    final t = total;
    final pd = paid.text.trim().isEmpty ? t : (parseNum(paid) ?? -1);
    if (pd < 0 || pd > t + 0.005) return _err('المبلغ المدفوع غير صحيح');
    if (pd < t - 0.005 && name.text.trim().isEmpty && phone.text.trim().isEmpty) {
      return _err('في حالة الدفع الجزئي لازم اسم أو رقم العميل');
    }
    Ops.sell(
      item: it,
      weight: weight,
      pricePerGram: p,
      fee: feeTotal,
      total: t,
      paid: pd,
      customerName: name.text.trim(),
      customerPhone: phone.text.trim(),
      pieces: byPiece ? (picked.toList()..sort()) : <int>[],
    );
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(SnackBar(content: Text('تم البيع. الإجمالي ${money(t)}')));
  }

  @override
  Widget build(BuildContext context) {
    final it = item;
    return Scaffold(
      appBar: AppBar(title: Text('بيع ${metalNames[widget.metal]}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ItemPicker(
            metal: widget.metal,
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
          if (!byPiece)
            tf('الوزن المباع (جرام)', w, onChanged: () => setState(() {}))
          else if (it == null)
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
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('الوزن: ${money(weight)} جم'),
                  const SizedBox(height: 4),
                  Text('مجمل المصنعية: ${money(feeTotal)}'),
                  const SizedBox(height: 4),
                  Text('مجمل السعر: ${money(total)}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          tf('المبلغ المدفوع (سيبه فاضي لو دفع كامل)', paid),
          tf('اسم العميل (اختياري)', name, type: TextInputType.text),
          tf('رقم العميل (اختياري)', phone, type: TextInputType.phone),
          FilledButton(
            onPressed: save,
            child: const Padding(padding: EdgeInsets.all(12), child: Text('تأكيد البيع')),
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
  bool isNew = false;
  bool cut = false;
  Item? old;
  late int karat = karatsOf(widget.metal).first;
  late String barcode = Store.newBarcode(widget.metal, karat);
  String photo = '';
  final desc = TextEditingController();
  final w = TextEditingController();
  final price = TextEditingController();
  final paid = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();

  void _err(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  double get debt {
    final pr = parseNum(price) ?? 0;
    final pd = paid.text.trim().isEmpty ? pr : (parseNum(paid) ?? 0);
    return pr - pd;
  }

  void save() {
    if (!isNew && old == null) return _err('اختار المنتج القديم بالباركود');
    final wt = parseNum(w);
    if (wt == null || wt <= 0) return _err('اكتب الوزن');
    final pr = parseNum(price);
    if (pr == null || pr <= 0) return _err('اكتب سعر الشراء');
    final pd = paid.text.trim().isEmpty ? pr : (parseNum(paid) ?? -1);
    if (pd < 0 || pd > pr + 0.005) return _err('المبلغ المدفوع غير صحيح');
    if (!cut && pd < pr - 0.005 && name.text.trim().isEmpty && phone.text.trim().isEmpty) {
      return _err('في حالة الدفع الجزئي لازم اسم أو رقم العميل');
    }
    Ops.buy(
      cut: cut,
      existing: isNew ? null : old,
      metal: widget.metal,
      karat: isNew ? karat : old!.karat,
      barcode: isNew ? barcode : old!.barcode,
      photo: photo,
      desc: desc.text.trim(),
      weight: wt,
      price: pr,
      paid: pd,
      customerName: cut ? '' : name.text.trim(),
      customerPhone: cut ? '' : phone.text.trim(),
    );
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(SnackBar(
        content: Text(pr - pd > 0.005 ? 'تم التسجيل. عليا مديونية ${money(pr - pd)}' : 'تم تسجيل الشراء. لا توجد مديونية')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('شراء ${metalNames[widget.metal]}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('منتج قديم')),
              ButtonSegment(value: true, label: Text('منتج جديد')),
            ],
            selected: {isNew},
            onSelectionChanged: (s) => setState(() => isNew = s.first),
          ),
          const SizedBox(height: 16),
          if (!isNew) ...[
            ItemPicker(metal: widget.metal, onSelected: (i) => setState(() => old = i)),
            if (old != null) ItemInfo(old!),
          ] else ...[
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
              decoration: const InputDecoration(labelText: 'العيار', border: OutlineInputBorder()),
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
            tf('وصف (اختياري)', desc, type: TextInputType.text),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 12),
              child: BarcodeWidget(barcode: Barcode.code128(), data: barcode, height: 70),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('قطع (من غير اسم ورقم عميل)'),
            value: cut,
            onChanged: (v) => setState(() => cut = v),
          ),
          tf('الوزن (جرام)', w),
          tf('سعر الشراء الإجمالي', price, onChanged: () => setState(() {})),
          tf('المبلغ المدفوع (سيبه فاضي لو دفعت كامل)', paid, onChanged: () => setState(() {})),
          Card(
            color: debt > 0.005 ? Colors.red.shade100 : Colors.green.shade100,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                debt > 0.005 ? 'عليا مديونية: ${money(debt)}' : 'لا توجد مديونية',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!cut) ...[
            tf('اسم العميل (اختياري)', name, type: TextInputType.text),
            tf('رقم العميل (اختياري)', phone, type: TextInputType.phone),
          ],
          FilledButton(
            onPressed: save,
            child: const Padding(padding: EdgeInsets.all(12), child: Text('تأكيد الشراء')),
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
      m[k] = (m[k] ?? 0) + nd(p['amount']);
    }
    paySum = m;
  }

  double restOf(Map<String, dynamic> m, bool isSale) =>
      nd(isSale ? m['total'] : m['price']) - nd(m['paid']) - (paySum[m['id'] as String] ?? 0);

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

  void _listen<T>(String key, Stream<T> st, void Function(T) set) {
    subs.add(st.listen((v) {
      set(v);
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
            labelText: 'المبلغ (المتبقي ${money(max)})', border: const OutlineInputBorder()),
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

Future<void> editOp(BuildContext context, Map<String, dynamic> m, bool isSale, MultiData d) async {
  final msg = ScaffoldMessenger.of(context);
  void err(String s) => msg.showSnackBar(SnackBar(content: Text(s)));
  final id = m['id'] as String;
  if (isSale) {
    final r = await editDialog(context, 'تعديل عملية البيع', {
      'سعر الجرام': money(nd(m['pricePerGram'])),
      'المصنعية الإجمالية': money(nd(m['fee'])),
      'المبلغ المدفوع وقت البيع': money(nd(m['paid'])),
      'اسم العميل': '${m['customerName'] ?? ''}',
      'رقم العميل': '${m['customerPhone'] ?? ''}',
    });
    if (r == null) return;
    final ppg = pn(r['سعر الجرام']);
    final fee = pn(r['المصنعية الإجمالية']);
    final paid = pn(r['المبلغ المدفوع وقت البيع']);
    if (ppg == null || ppg <= 0 || fee == null || fee < 0 || paid == null || paid < 0) {
      return err('قيم غير صحيحة');
    }
    final total = nd(m['weight']) * ppg + fee;
    if (paid + (d.paySum[id] ?? 0) > total + 0.005) return err('المدفوع أكبر من الإجمالي الجديد');
    Ops.col('sales').doc(id).update({
      'pricePerGram': ppg,
      'fee': fee,
      'total': total,
      'paid': paid,
      'customerName': r['اسم العميل'],
      'customerPhone': r['رقم العميل'],
    });
  } else {
    final r = await editDialog(context, 'تعديل عملية الشراء', {
      'سعر الشراء الإجمالي': money(nd(m['price'])),
      'المبلغ المدفوع وقت الشراء': money(nd(m['paid'])),
      'اسم العميل': '${m['customerName'] ?? ''}',
      'رقم العميل': '${m['customerPhone'] ?? ''}',
    });
    if (r == null) return;
    final price = pn(r['سعر الشراء الإجمالي']);
    final paid = pn(r['المبلغ المدفوع وقت الشراء']);
    if (price == null || price <= 0 || paid == null || paid < 0) return err('قيم غير صحيحة');
    if (paid + (d.paySum[id] ?? 0) > price + 0.005) return err('المدفوع أكبر من السعر الجديد');
    Ops.col('purchases').doc(id).update({
      'price': price,
      'paid': paid,
      'customerName': r['اسم العميل'],
      'customerPhone': r['رقم العميل'],
    });
  }
}

Future<void> deleteOp(BuildContext context, Map<String, dynamic> m, bool isSale, MultiData d) async {
  final msg = ScaffoldMessenger.of(context);
  final ids = d.payments
      .where((p) => p['refId'] == m['id'])
      .map((p) => p['id'] as String)
      .toList();
  if (!isSale) {
    final it = d.itemById(m['itemId'] as String);
    if (it != null && it.remaining < nd(m['weight']) - 0.0001) {
      msg.showSnackBar(const SnackBar(
          content: Text('اتباع من المنتج ده بعد الشراء، امسح عملية البيع الأول')));
      return;
    }
  }
  if (!await confirmDialog(context, 'مسح العملية دي؟ المخزون هيتعدّل تلقائيًا.')) return;
  if (isSale) {
    Ops.deleteSale(m, ids);
  } else {
    Ops.deletePurchase(m, ids);
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
  final extra = d.paySum[m['id'] as String] ?? 0;
  final paid = nd(m['paid']) + extra;
  final rest = amount - paid;
  final who = [m['customerName'], m['customerPhone']]
      .where((e) => e != null && '$e'.isNotEmpty)
      .join(' - ');
  final pieces = (m['pieces'] as List?) ?? const [];
  final lines = <String>[
    fmtDate(m['ts'] as Timestamp),
    '${m['barcode']}',
    if (pieces.isNotEmpty) 'عدد القطع: ${pieces.length}',
    if (who.isNotEmpty) 'العميل: $who',
    if (isSale) 'مصنعية ${money(nd(m['fee']))} | سعر الجرام ${money(nd(m['pricePerGram']))}',
    'مدفوع ${money(paid)}'
        '${rest > 0.005 ? (isSale ? ' | متبقي عليه ${money(rest)}' : ' | متبقي علينا ${money(rest)}') : ''}',
  ];
  return Card(
    child: ListTile(
      isThreeLine: true,
      title: Text('عيار ${m['karat']} - ${money(nd(m['weight']))} جم${m['cut'] == true ? ' (قطع)' : ''}'),
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
            tabs: [Tab(text: 'مبيعات'), Tab(text: 'مشتريات'), Tab(text: 'مصاريف'), Tab(text: 'تحويلات')],
          ),
        ),
        body: Multi(
          metal: metal,
          builder: (context, d) => TabBarView(children: [
            d.sales.isEmpty
                ? emptyNote()
                : ListView(children: [for (final m in d.sales) opTile(context, m, true, d)]),
            d.purchases.isEmpty
                ? emptyNote()
                : ListView(children: [for (final m in d.purchases) opTile(context, m, false, d)]),
            d.expenses.isEmpty
                ? emptyNote('لا يوجد مصاريف')
                : ListView(children: [
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
                            }
                          },
                        ),
                      ),
                  ]),
            d.conversions.isEmpty
                ? emptyNote('لا يوجد تحويلات')
                : ListView(children: [
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

    return ListView(
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
                      labelText: 'بحث بالاسم أو الرقم',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search)),
                  onChanged: (v) => setState(() => q = v.trim()),
                ),
              ),
              Expanded(
                child: list.isEmpty
                    ? emptyNote('لا يوجد عملاء مسجلين')
                    : ListView(
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
          return ListView(
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
  final title = TextEditingController();
  final amount = TextEditingController();

  void save() {
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
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(const SnackBar(content: Text('تم الحفظ')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مصاريف وقبض العاملين')),
      body: ListView(
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
            onPressed: save,
            child: const Padding(padding: EdgeInsets.all(12), child: Text('حفظ')),
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
  late int toKarat = karatsOf(widget.metal).first;
  final w = TextEditingController();
  final toW = TextEditingController();

  void _recalc() {
    final f = from;
    final wt = parseNum(w);
    if (f != null && wt != null) toW.text = money(wt * f.karat / toKarat);
    setState(() {});
  }

  void _err(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void save() {
    final f = from;
    if (f == null) return _err('اختار المنتج اللي هيتحول منه');
    final wt = parseNum(w);
    if (wt == null || wt <= 0 || wt > f.remaining + 0.0001) {
      return _err('الوزن لازم يكون أكبر من صفر ولا يزيد عن المتبقي (${money(f.remaining)} جم)');
    }
    if (toKarat == f.karat) return _err('اختار عيار مختلف');
    final tw = parseNum(toW);
    if (tw == null || tw <= 0) return _err('اكتب الوزن الناتج');
    Item? dest;
    if (toExisting) {
      dest = to;
      if (dest == null) return _err('اختار المنتج اللي هيتحول إليه');
      if (dest.karat != toKarat) return _err('المنتج المختار مش من عيار $toKarat');
    }
    Ops.convert(metal: widget.metal, from: f, weight: wt, toKarat: toKarat, to: dest, toWeight: tw);
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(SnackBar(content: Text('تم التحويل: ${money(wt)} جم ← ${money(tw)} جم')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تحويل بين العيارات')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('التحويل من:'),
          const SizedBox(height: 8),
          ItemPicker(
            metal: widget.metal,
            onSelected: (i) {
              from = i;
              _recalc();
            },
          ),
          if (from != null) ItemInfo(from!),
          tf('الوزن المحوّل (جرام)', w, onChanged: _recalc),
          DropdownButtonFormField<int>(
            value: toKarat,
            decoration: const InputDecoration(labelText: 'التحويل إلى عيار', border: OutlineInputBorder()),
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
            ItemPicker(metal: widget.metal, onSelected: (i) => setState(() => to = i)),
            if (to != null) ItemInfo(to!),
          ],
          tf('الوزن الناتج (جرام) - بيتحسب تلقائي وتقدر تعدله', toW),
          const Text(
            'الحساب: الوزن × عيار المصدر ÷ عيار الهدف (بنفس كمية الذهب الصافي).',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: save,
            child: const Padding(padding: EdgeInsets.all(12), child: Text('تأكيد التحويل')),
          ),
        ],
      ),
    );
  }
}
