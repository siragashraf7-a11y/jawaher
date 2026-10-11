import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
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
  Item({
    required this.id,
    required this.metal,
    required this.karat,
    required this.name,
    required this.barcode,
    required this.photo,
    required this.weights,
    required this.remaining,
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
    );
  }

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
                    subtitle: Text('${i.weights.length} قطعة | المتبقي ${i.remaining.toStringAsFixed(2)} جم'),
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
  }) {
    final batch = FirebaseFirestore.instance.batch();
    batch.update(Store.items.doc(item.id), {'remaining': FieldValue.increment(-weight)});
    batch.set(col('sales').doc(), {
      'metal': item.metal,
      'karat': item.karat,
      'barcode': item.barcode,
      'itemId': item.id,
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
      'weight': weight,
      'price': price,
      'paid': paid,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'ts': Timestamp.now(),
    });
    batch.commit();
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
              decoration: const InputDecoration(
                labelText: 'الباركود (اكتبه أو اختار)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.qr_code),
              ),
            ),
            optionsViewBuilder: (ctx, onSel, opts) => Align(
              alignment: Alignment.topRight,
              child: Material(
                elevation: 4,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260, maxWidth: 340),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final i in opts)
                        ListTile(
                          dense: true,
                          title: Text(i.barcode, textDirection: TextDirection.ltr),
                          subtitle: Text('عيار ${i.karat} | المتبقي ${money(i.remaining)} جم'),
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

  double get weight => parseNum(w) ?? 0;
  double get feeTotal => (parseNum(fee) ?? 0) * (feePerGram ? weight : 1);
  double get total => weight * (parseNum(price) ?? 0) + feeTotal;

  void _err(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  void save() {
    final it = item;
    if (it == null) return _err('اختار المنتج بالباركود');
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
    );
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(SnackBar(content: Text('تم البيع. الإجمالي ${money(t)}')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('بيع ${metalNames[widget.metal]}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ItemPicker(metal: widget.metal, onSelected: (i) => setState(() => item = i)),
          if (item != null) ItemInfo(item!),
          tf('الوزن المباع (جرام)', w, onChanged: () => setState(() {})),
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

  void save() {
    if (!isNew && old == null) return _err('اختار المنتج القديم بالباركود');
    final wt = parseNum(w);
    if (wt == null || wt <= 0) return _err('اكتب الوزن');
    final pr = parseNum(price);
    if (pr == null || pr <= 0) return _err('اكتب سعر الشراء');
    final pd = paid.text.trim().isEmpty ? pr : (parseNum(paid) ?? -1);
    if (pd < 0 || pd > pr + 0.005) return _err('المبلغ المدفوع غير صحيح');
    if (pd < pr - 0.005 && name.text.trim().isEmpty && phone.text.trim().isEmpty) {
      return _err('في حالة الدفع الجزئي لازم اسم أو رقم العميل');
    }
    Ops.buy(
      existing: isNew ? null : old,
      metal: widget.metal,
      karat: isNew ? karat : old!.karat,
      barcode: isNew ? barcode : old!.barcode,
      photo: photo,
      desc: desc.text.trim(),
      weight: wt,
      price: pr,
      paid: pd,
      customerName: name.text.trim(),
      customerPhone: phone.text.trim(),
    );
    final m = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    m.showSnackBar(const SnackBar(content: Text('تم تسجيل الشراء')));
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
          tf('الوزن (جرام)', w),
          tf('سعر الشراء الإجمالي', price),
          tf('المبلغ المدفوع (سيبه فاضي لو دفعت كامل)', paid),
          tf('اسم العميل (اختياري)', name, type: TextInputType.text),
          tf('رقم العميل (اختياري)', phone, type: TextInputType.phone),
          FilledButton(
            onPressed: save,
            child: const Padding(padding: EdgeInsets.all(12), child: Text('تأكيد الشراء')),
          ),
        ],
      ),
    );
  }
}

class HistoryScreen extends StatelessWidget {
  final String metal;
  const HistoryScreen({super.key, required this.metal});

  Widget _list(String kind) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Ops.watch(kind, metal),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final rows = snap.data!;
        if (rows.isEmpty) return const Center(child: Text('لا يوجد عمليات'));
        final isSale = kind == 'sales';
        return ListView.builder(
          itemCount: rows.length,
          itemBuilder: (_, n) {
            final m = rows[n];
            final amount = nd(isSale ? m['total'] : m['price']);
            final paid = nd(m['paid']);
            final rest = amount - paid;
            final who = [m['customerName'], m['customerPhone']]
                .where((e) => e != null && '$e'.isNotEmpty)
                .join(' - ');
            final lines = <String>[
              fmtDate(m['ts'] as Timestamp),
              '${m['barcode']}',
              if (who.isNotEmpty) 'العميل: $who',
              if (isSale) 'مصنعية ${money(nd(m['fee']))} | سعر الجرام ${money(nd(m['pricePerGram']))}',
              'مدفوع ${money(paid)}'
                  '${rest > 0.005 ? (isSale ? ' | متبقي عليه ${money(rest)}' : ' | متبقي علينا ${money(rest)}') : ''}',
            ];
            return Card(
              child: ListTile(
                isThreeLine: true,
                title: Text('عيار ${m['karat']} - ${money(nd(m['weight']))} جم'),
                subtitle: Text(lines.join('\n')),
                trailing: Text(money(amount), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('عمليات ${metalNames[metal]}'),
          bottom: const TabBar(tabs: [Tab(text: 'مبيعات'), Tab(text: 'مشتريات')]),
        ),
        body: TabBarView(children: [_list('sales'), _list('purchases')]),
      ),
    );
  }
}
