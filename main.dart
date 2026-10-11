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
                          context, MaterialPageRoute(builder: (_) => InventoryScreen(metal: m))),
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

