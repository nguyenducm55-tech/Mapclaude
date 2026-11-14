import 'dart:async';
import 'dart:convert';
import 'dart:math' as m;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() => runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
    home: const Home()));

const ua = {'User-Agent': 'TroLyTaiXe/1.0 (ung dung ca nhan)'};
const dist = Distance();
const names = {'cam': 'camera giám sát', 'ban': 'biển cấm', 'chot': 'chốt kiểm tra', 'haz': 'điểm nguy hiểm'};
const icons = {'cam': '📸', 'ban': '🚫', 'chot': '🚔', 'haz': '⚠️'};
const act = {
  4: 'bạn sẽ đến nơi', 5: 'bạn sẽ đến nơi', 6: 'bạn sẽ đến nơi',
  9: 'đi chếch sang phải', 10: 'rẽ phải', 11: 'rẽ phải gấp',
  12: 'quay đầu', 13: 'quay đầu', 14: 'rẽ trái gấp', 15: 'rẽ trái', 16: 'đi chếch sang trái',
  18: 'đi theo nhánh bên phải', 19: 'đi theo nhánh bên trái', 20: 'ra lối bên phải', 21: 'ra lối bên trái',
  23: 'giữ làn bên phải', 24: 'giữ làn bên trái', 26: 'vào vòng xuyến', 27: 'ra khỏi vòng xuyến',
};

class Hz {
  final String id, type;
  final LatLng p;
  const Hz(this.id, this.type, this.p);
}

class Step {
  final int type, idx;
  final String street;
  const Step(this.type, this.street, this.idx);
}

double angd(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

List<LatLng> decode(String s) {
  final out = <LatLng>[];
  int i = 0, lat = 0, lng = 0;
  while (i < s.length) {
    int sh = 0, r = 0, b;
    do { b = s.codeUnitAt(i++) - 63; r |= (b & 31) << sh; sh += 5; } while (b >= 32);
    lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
    sh = 0; r = 0;
    do { b = s.codeUnitAt(i++) - 63; r |= (b & 31) << sh; sh += 5; } while (b >= 32);
    lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
    out.add(LatLng(lat / 1e6, lng / 1e6));
  }
  return out;
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final map = MapController();
  final tts = FlutterTts();
  final q = TextEditingController();
  StreamSubscription<Position>? sub;
  LatLng? me, dest, lastLim, lastCam;
  double speed = 0;
  double? hdg;
  int lim = 50, userLim = 50, over = 0, off = 0, ri = 0;
  bool limOsm = false, scooter = false, nav = false, noVi = false, first = true;
  List<LatLng> route = [];
  List<Step> steps = [];
  List<Hz> osmHz = [], mine = [];
  List<Map<String, dynamic>> results = [];
  String msg = 'Nhập điểm đến, hoặc nhấn giữ trên bản đồ để chọn.', lastSay = '';
  DateTime lastAt = DateTime(2000), lastOver = DateTime(2000), lastRoute = DateTime(2000), lastLimAt = DateTime(2000);
  final said = <String>{};

  @override
  void initState() {
    super.initState();
    init();
  }

  @override
  void dispose() {
    sub?.cancel();
    WakelockPlus.disable();
    tts.stop();
    super.dispose();
  }

  Future<void> init() async {
    WakelockPlus.enable();
    await tts.setLanguage('vi-VN');
    await tts.setSpeechRate(0.5);
    final ok = await tts.isLanguageAvailable('vi-VN');
    if (!(ok == true || ok == 1)) setState(() => noVi = true);
    final sp = await SharedPreferences.getInstance();
    userLim = sp.getInt('lim') ?? 50;
    final now = DateTime.now().millisecondsSinceEpoch;
    final ls = <Hz>[];
    for (final s in sp.getStringList('pts') ?? <String>[]) {
      final a = s.split('|');
      if (a.length < 4) continue;
      final ttl = {'chot': 6, 'haz': 12}[a[1]];
      if (ttl != null && now - (int.tryParse(a[0].substring(1)) ?? 0) > ttl * 3600000) continue;
      ls.add(Hz(a[0], a[1], LatLng(double.parse(a[2]), double.parse(a[3]))));
    }
    setState(() { mine = ls; lim = userLim; });
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      setState(() => msg = 'Cần cấp quyền vị trí cho app trong Cài đặt.');
      return;
    }
    sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 2),
    ).listen(onPos, onError: (_) => setState(() => msg = 'Hãy bật định vị (GPS) trên điện thoại.'));
  }

  Future<void> say(String t, {bool urgent = false}) async {
    final now = DateTime.now();
    if (t == lastSay && now.difference(lastAt).inSeconds < 8) return;
    lastSay = t;
    lastAt = now;
    if (mounted) setState(() => msg = t);
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.mediumImpact();
    if (noVi) return;
    try {
      if (urgent) await tts.stop();
      await tts.speak(t);
    } catch (_) {}
  }

  void onPos(Position p) {
    final c = LatLng(p.latitude, p.longitude);
    final v = (p.speed.isNaN || p.speed < 0 ? 0 : p.speed) * 3.6;
    if (v > 4 && p.heading >= 0) hdg = p.heading;
    setState(() { me = c; speed = v; });
    try {
      if (first) { map.move(c, 16); first = false; } else if (nav) { map.move(c, map.camera.zoom); }
    } catch (_) {}
    speedChk(v.round());
    fetchLimit(c);
    fetchCams(c);
    nearHz(c);
    if (nav && route.isNotEmpty) guide(c);
  }

  void speedChk(int v) {
    if (v > lim + 3) {
      if (++over >= 3 && DateTime.now().difference(lastOver).inSeconds > 12) {
        lastOver = DateTime.now();
        over = 0;
        say('Bạn đang chạy $v ki-lô-mét trên giờ, tốc độ tối đa là $lim. Hãy giảm tốc.', urgent: true);
      }
    } else {
      over = 0;
    }
  }

  Future<List?> overpass(String qy) async {
    try {
      final r = await http.post(Uri.parse('https://overpass-api.de/api/interpreter'), headers: ua, body: {'data': qy}).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      return jsonDecode(utf8.decode(r.bodyBytes))['elements'] as List;
    } catch (_) {
      return null;
    }
  }

  Future<void> fetchLimit(LatLng c) async {
    if (lastLim != null && dist.distance(lastLim!, c) < 120 && DateTime.now().difference(lastLimAt).inSeconds < 30) return;
    lastLim = c;
    lastLimAt = DateTime.now();
    final r = await overpass('[out:json][timeout:8];way(around:15,${c.latitude},${c.longitude})[highway][maxspeed];out tags 5;');
    if (r == null || !mounted) return;
    for (final e in r) {
      final t = (e['tags'] ?? {}) as Map;
      final n = int.tryParse(RegExp(r'\d+').firstMatch('${t['maxspeed']}')?.group(0) ?? '');
      if (n != null && n >= 10 && n <= 120) {
        setState(() { lim = n; limOsm = true; });
        return;
      }
    }
    setState(() { lim = userLim; limOsm = false; });
  }

  Future<void> fetchCams(LatLng c) async {
    if (lastCam != null && dist.distance(lastCam!, c) < 1500) return;
    lastCam = c;
    final r = await overpass('[out:json][timeout:10];(node(around:3000,${c.latitude},${c.longitude})["highway"="speed_camera"];node(around:3000,${c.latitude},${c.longitude})["enforcement"];);out;');
    if (r == null || !mounted) return;
    setState(() => osmHz = [
          for (final e in r)
            if (e['lat'] != null) Hz('o${e['id']}', 'cam', LatLng((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble()))
        ]);
  }

  void nearHz(LatLng c) {
    for (final h in [...osmHz, ...mine]) {
      final d = dist.distance(c, h.p);
      if (d > 600) { said.remove(h.id); continue; }
      if (d <= 300 && !said.contains(h.id)) {
        final b = (dist.bearing(c, h.p) + 360) % 360;
        if (hdg == null || angd(hdg!, b) < 70) {
          said.add(h.id);
          say('Phía trước khoảng ${m.max(50, (d / 50).round() * 50)} mét có ${names[h.type]}.', urgent: true);
        }
      }
    }
  }

  Future<void> savePt(String t) async {
    if (me == null) { say('Chưa có tín hiệu GPS.'); return; }
    final h = Hz('u${DateTime.now().millisecondsSinceEpoch}', t, me!);
    said.add(h.id);
    setState(() => mine = [...mine, h]);
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('pts', [for (final x in mine) '${x.id}|${x.type}|${x.p.latitude}|${x.p.longitude}']);
    say('Đã lưu ${names[t]} tại vị trí này.');
  }

  void cycleLim() {
    const o = [40, 50, 60, 70, 80];
    userLim = o[(o.indexOf(userLim) + 1) % o.length];
    SharedPreferences.getInstance().then((sp) => sp.setInt('lim', userLim));
    setState(() { if (!limOsm) lim = userLim; });
  }

  Future<void> search() async {
    final t = q.text.trim();
    if (t.isEmpty) return;
    FocusScope.of(context).unfocus();
    try {
      final r = await http.get(
        Uri.https('nominatim.openstreetmap.org', '/search', {'format': 'json', 'q': t, 'countrycodes': 'vn', 'limit': '5', 'accept-language': 'vi'}),
        headers: ua,
      ).timeout(const Duration(seconds: 12));
      final l = (jsonDecode(utf8.decode(r.bodyBytes)) as List).map((e) => Map<String, dynamic>.from(e)).toList();
      setState(() => results = l);
      if (l.isEmpty) say('Không tìm thấy địa điểm này.');
    } catch (_) {
      say('Không tìm được, hãy kiểm tra kết nối mạng.');
    }
  }

  void pick(LatLng p) {
    setState(() { dest = p; results = []; });
    buildRoute();
  }

  Future<void> buildRoute() async {
    if (me == null || dest == null) { say('Chưa có vị trí hiện tại.'); return; }
    lastRoute = DateTime.now();
    try {
      final r = await http.post(
        Uri.parse('https://valhalla1.openstreetmap.de/route'),
        headers: {...ua, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'locations': [
            {'lat': me!.latitude, 'lon': me!.longitude},
            {'lat': dest!.latitude, 'lon': dest!.longitude}
          ],
          'costing': scooter ? 'motor_scooter' : 'motorcycle',
          'directions_options': {'units': 'kilometers'},
        }),
      ).timeout(const Duration(seconds: 20));
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode != 200 || j['trip'] == null) { say('Không tìm được đường đi cho xe máy tới đó.'); return; }
      final leg = j['trip']['legs'][0];
      final pts = decode(leg['shape'] as String);
      final st = <Step>[];
      for (final mv in leg['maneuvers'] as List) {
        final sn = (mv['street_names'] as List?) ?? const [];
        st.add(Step(mv['type'] as int, sn.isEmpty ? '' : '${sn[0]}', mv['begin_shape_index'] as int));
      }
      said.removeWhere((e) => e.startsWith('s'));
      if (!mounted) return;
      setState(() { route = pts; steps = st; ri = 0; off = 0; });
      final s = j['trip']['summary'];
      say('Đã tìm thấy đường, ${(s['length'] as num).toStringAsFixed(1).replaceAll('.', ',')} ki-lô-mét, khoảng ${((s['time'] as num) / 60).round()} phút.');
      try { map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(48))); } catch (_) {}
    } catch (_) {
      say('Không tìm được đường, hãy kiểm tra kết nối mạng.');
    }
  }

  void guide(LatLng c) {
    int best = ri;
    double bd = 1e9;
    final end = m.min(route.length, ri + 80);
    for (int i = ri; i < end; i++) {
      final d = dist.distance(c, route[i]);
      if (d < bd) { bd = d; best = i; }
    }
    ri = best;
    if (bd > 60) {
      if (++off >= 3 && DateTime.now().difference(lastRoute).inSeconds > 15) {
        off = 0;
        say('Bạn đã đi lệch tuyến, đang tính lại đường.', urgent: true);
        buildRoute();
      }
      return;
    }
    off = 0;
    for (int i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (s.idx <= ri || s.idx >= route.length || !act.containsKey(s.type)) continue;
      final d = dist.distance(c, route[s.idx]);
      final on = s.street.isEmpty ? '' : ' vào ${s.street}';
      final txt = '${act[s.type]}${s.type >= 4 && s.type <= 6 ? '' : on}';
      if (d <= 40 && said.add('s${i}c')) {
        say('${txt[0].toUpperCase()}${txt.substring(1)}.', urgent: true);
        if (s.type >= 4 && s.type <= 6) stopNav();
      } else if (d <= 120 && said.add('s${i}b')) {
        say('Phía trước 100 mét, $txt.', urgent: true);
      } else if (d <= 350 && said.add('s${i}a')) {
        say('Phía trước ${m.max(200, (d / 50).round() * 50)} mét, $txt.');
      }
      break;
    }
  }

  void toggleNav() {
    if (nav) { stopNav(); return; }
    if (route.isEmpty) { say('Hãy chọn điểm đến trước.'); return; }
    said.removeWhere((e) => e.startsWith('s'));
    setState(() { nav = true; ri = 0; });
    say('Bắt đầu dẫn đường. Chúc bạn lái xe an toàn.', urgent: true);
  }

  void stopNav() => setState(() => nav = false);

  @override
  Widget build(BuildContext context) {
    final over3 = speed.round() > lim + 3;
    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: map,
          options: MapOptions(initialCenter: const LatLng(16.05, 108.2), initialZoom: 6, onLongPress: (tp, p) => pick(p)),
          children: [
            TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'vn.taixe.tro_ly_tai_xe'),
            if (route.isNotEmpty) PolylineLayer(polylines: [Polyline(points: route, strokeWidth: 6, color: Colors.blue)]),
            MarkerLayer(markers: [
              for (final h in [...osmHz, ...mine]) Marker(point: h.p, width: 32, height: 32, child: Text(icons[h.type]!, style: const TextStyle(fontSize: 22))),
              if (dest != null) Marker(point: dest!, width: 40, height: 40, child: const Icon(Icons.place, color: Colors.red, size: 40)),
              if (me != null) Marker(point: me!, width: 28, height: 28, child: const Icon(Icons.navigation, color: Colors.blue, size: 28)),
            ]),
          ],
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Card(
                  child: Row(children: [
                    const SizedBox(width: 12),
                    Expanded(child: TextField(controller: q, onSubmitted: (_) => search(), decoration: const InputDecoration(hintText: 'Tìm điểm đến (vd: Bến xe Mỹ Đình)', border: InputBorder.none))),
                    IconButton(icon: const Icon(Icons.search), onPressed: search),
                    IconButton(icon: const Icon(Icons.volume_up), onPressed: () => say('Giọng Tiếng Việt đang hoạt động tốt. Chúc bạn chạy xe an toàn.', urgent: true)),
                  ]),
                ),
                if (results.isNotEmpty)
                  Card(
                    child: Column(children: [
                      for (final r in results)
                        ListTile(
                          dense: true,
                          title: Text('${r['display_name']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                          onTap: () => pick(LatLng(double.parse('${r['lat']}'), double.parse('${r['lon']}'))),
                        ),
                    ]),
                  ),
              ]),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Card(
              margin: const EdgeInsets.all(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (noVi)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('Máy chưa có giọng Tiếng Việt nên app chỉ phát chuông. Cài đặt > Văn bản sang giọng nói > Google > tải Tiếng Việt.', style: TextStyle(fontSize: 12, color: Colors.deepOrange)),
                    ),
                  Row(children: [
                    Column(children: [
                      Text('${speed.round()}', style: TextStyle(fontSize: 54, height: 1, fontWeight: FontWeight.w800, color: over3 ? Colors.red : null)),
                      const Text('km/h', style: TextStyle(fontSize: 12)),
                    ]),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: cycleLim,
                      child: Column(children: [
                        Container(
                          width: 64, height: 64, alignment: Alignment.center,
                          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: Colors.red, width: 6)),
                          child: Text('$lim', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 22)),
                        ),
                        Text(limOsm ? 'theo OSM' : 'bạn chọn', style: const TextStyle(fontSize: 10)),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(msg, style: const TextStyle(fontWeight: FontWeight.w700))),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: FilledButton(onPressed: toggleNav, child: Text(nav ? 'Dừng dẫn đường' : 'Bắt đầu dẫn đường'))),
                    const SizedBox(width: 8),
                    ChoiceChip(label: Text(scooter ? 'Xe ga' : 'Xe máy'), selected: scooter, onSelected: (v) => setState(() => scooter = v)),
                  ]),
                  const SizedBox(height: 4),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    for (final t in icons.keys) OutlinedButton(onPressed: () => savePt(t), child: Text(icons[t]!)),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
