import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'chat.dart';
import 'launcher.dart';
import 'theme.dart';

/// Places around you, from OpenStreetMap (free, no key). Directions and reviews open in Google Maps.
/// Your exact location goes only to the map search, never to any AI.

const _ua = 'VibeLauncher/$vibeVersion (personal Android launcher)';
const mapsPkg = 'com.google.android.apps.maps';

/// A kind of place: what to call it and how to find it in OpenStreetMap.
class PlaceCat {
  final String id, label, emoji;
  final List<String> filters; // Overpass filters, e.g. '[amenity=restaurant]'
  final bool wide; // usually far apart (hospitals, stations): search a bigger area
  const PlaceCat(this.id, this.label, this.emoji, this.filters, {this.wide = false});
}

const _cats = <(String, PlaceCat)>[
  (r'restos?|restaurants?|restaurent?s?|hotels? to eat|places? to eat|food|eat|dining|dinner|lunch|breakfast|dhabas?|mess',
      PlaceCat('food', 'Restaurants', '🍽️', ['[amenity~"^(restaurant|fast_food|food_court)\$"]'])),
  (r'bars?|pubs?|breweries|brewery|lounges?|taverns?|drinks?|beer',
      PlaceCat('bar', 'Bars & pubs', '🍺', ['[amenity~"^(bar|pub|biergarten|nightclub)\$"]', '[craft=brewery]'])),
  (r'cafes?|caf[eé]s?|coffee|coffee shops?|tea|chai|tea stalls?',
      PlaceCat('cafe', 'Cafes', '☕', ['[amenity=cafe]'])),
  (r'fast ?food|takeaways?|street food',
      PlaceCat('fastfood', 'Fast food', '🍔', ['[amenity=fast_food]'])),
  (r'bakery|bakeries|cake shops?|cakes?|pastry|pastries|sweet shops?|sweets',
      PlaceCat('bakery', 'Bakeries & sweets', '🧁', ['[shop~"^(bakery|pastry|confectionery)\$"]'])),
  (r'ice ?creams?|ice ?cream parlou?rs?|desserts?|gelato',
      PlaceCat('icecream', 'Ice cream', '🍨', ['[amenity=ice_cream]', '[shop=ice_cream]'])),
  (r'atms?|cash machines?|cash points?',
      PlaceCat('atm', 'ATMs', '🏧', ['[amenity=atm]', '[amenity=bank][atm=yes]'])),
  (r'banks?', PlaceCat('bank', 'Banks', '🏦', ['[amenity=bank]'])),
  (r'pharmacy|pharmacies|medical shops?|medicals?|chemists?|drug ?stores?|medicine shops?',
      PlaceCat('pharmacy', 'Pharmacies', '💊', ['[amenity=pharmacy]', '[shop=chemist]', '[healthcare=pharmacy]'])),
  (r'hospitals?|emergency',
      PlaceCat('hospital', 'Hospitals', '🏥', ['[amenity=hospital]', '[healthcare=hospital]'], wide: true)),
  (r'clinics?|doctors?|dentists?',
      PlaceCat('clinic', 'Clinics & doctors', '🩺', ['[amenity~"^(clinic|doctors|dentist)\$"]'])),
  (r'petrol( pumps?| bunks?| stations?)?|fuel( stations?)?|gas stations?|diesel|bunks?|cng',
      PlaceCat('fuel', 'Petrol pumps', '⛽', ['[amenity=fuel]'], wide: true)),
  (r'ev chargers?|ev charging( stations?)?|charging stations?|chargers?',
      PlaceCat('ev', 'EV charging', '🔌', ['[amenity=charging_station]'], wide: true)),
  (r'parking|parking lots?|car parks?', PlaceCat('parking', 'Parking', '🅿️', ['[amenity=parking]'])),
  (r'toilets?|washrooms?|restrooms?|loos?|bathrooms?', PlaceCat('toilet', 'Toilets', '🚻', ['[amenity=toilets]'])),
  (r'police( stations?)?', PlaceCat('police', 'Police stations', '🚓', ['[amenity=police]'], wide: true)),
  (r'hotels?|lodges?|stays?|places? to stay|hostels?|guest ?houses?|resorts?|rooms?',
      PlaceCat('hotel', 'Hotels', '🏨', ['[tourism~"^(hotel|guest_house|hostel|motel|apartment)\$"]'])),
  (r'supermarkets?|groceries|grocery( stores?| shops?)?|kirana( stores?)?|marts?|general stores?|vegetables?|fruits?',
      PlaceCat('grocery', 'Groceries', '🛒', ['[shop~"^(supermarket|convenience|greengrocer|general)\$"]'])),
  (r'malls?|shopping( malls?| centres?| centers?)?', PlaceCat('mall', 'Malls', '🛍️', ['[shop=mall]'], wide: true)),
  (r'gyms?|fitness( centres?| centers?)?|yoga', PlaceCat('gym', 'Gyms', '🏋️', ['[leisure=fitness_centre]', '[leisure=sports_centre]'])),
  (r'parks?|gardens?|playgrounds?', PlaceCat('park', 'Parks', '🌳', ['[leisure~"^(park|garden)\$"]'])),
  (r'cinemas?|movie halls?|movie theaters?|movie theatres?|theaters?|theatres?|multiplex(es)?|pvr|inox',
      PlaceCat('cinema', 'Cinemas', '🎬', ['[amenity=cinema]'], wide: true)),
  (r'temples?|mandirs?', PlaceCat('temple', 'Temples', '🛕', ['[amenity=place_of_worship][religion=hindu]'])),
  (r'mosques?|masjids?', PlaceCat('mosque', 'Mosques', '🕌', ['[amenity=place_of_worship][religion=muslim]'])),
  (r'churches|church', PlaceCat('church', 'Churches', '⛪', ['[amenity=place_of_worship][religion=christian]'])),
  (r'bus stops?|bus stands?', PlaceCat('busstop', 'Bus stops', '🚏', ['[highway=bus_stop]'])),
  (r'bus stations?|bus depots?', PlaceCat('busstation', 'Bus stations', '🚌', ['[amenity=bus_station]'], wide: true)),
  (r'metro( stations?)?|subway( stations?)?', PlaceCat('metro', 'Metro stations', '🚇', ['[railway=station][station=subway]', '[railway=station][subway=yes]'], wide: true)),
  (r'railway stations?|train stations?|railway',
      PlaceCat('rail', 'Railway stations', '🚉', ['[railway=station][station!=subway]'], wide: true)),
  (r'salons?|barbers?|barber shops?|hair ?cuts?|parlou?rs?|beauty parlou?rs?|spas?',
      PlaceCat('salon', 'Salons', '💇', ['[shop~"^(hairdresser|beauty|massage)\$"]', '[leisure=spa]'])),
  (r'mechanics?|garages?|car repairs?|bike repairs?|service centres?|service centers?|tyres?|tires?|puncture( shops?)?',
      PlaceCat('mechanic', 'Mechanics', '🔧', ['[shop~"^(car_repair|motorcycle_repair|tyres|bicycle)\$"]'])),
  (r'wine shops?|liquor( shops?| stores?)?|alcohol|wines?',
      PlaceCat('liquor', 'Wine shops', '🍷', ['[shop~"^(alcohol|wine|beverages)\$"]'])),
  (r'tourist (places|spots|attractions)|attractions?|things to do|places to visit|sightseeing|monuments?|museums?|viewpoints?',
      PlaceCat('sights', 'Places to visit', '📸', ['[tourism~"^(attraction|museum|viewpoint|gallery|zoo|theme_park)\$"]', '[historic~"^(monument|fort|castle|memorial)\$"]'], wide: true)),
  (r'post offices?', PlaceCat('post', 'Post offices', '📮', ['[amenity=post_office]'])),
  (r'schools?', PlaceCat('school', 'Schools', '🏫', ['[amenity=school]'])),
  (r'colleges?|universities|university', PlaceCat('college', 'Colleges', '🎓', ['[amenity~"^(college|university)\$"]'], wide: true)),
  (r'electronics?( shops?| stores?)?|mobile shops?|phone shops?', PlaceCat('electronics', 'Electronics & phones', '📱', ['[shop~"^(electronics|mobile_phone|computer)\$"]'])),
  (r'clothes|clothing( stores?)?|clothes shops?|boutiques?|tailors?', PlaceCat('clothes', 'Clothes', '👕', ['[shop~"^(clothes|boutique|tailor|fashion)\$"]'])),
];

/// Food words that narrow restaurants: "biryani near me", "south indian in kondapur".
const _cuisines = [
  'biryani', 'pizza', 'burger', 'burgers', 'chinese', 'south indian', 'north indian', 'mandi', 'shawarma', 'dosa', 'idli',
  'kebab', 'kebabs', 'momos', 'momo', 'sushi', 'seafood', 'arabian', 'arabic', 'italian', 'thai', 'korean', 'japanese',
  'mexican', 'punjabi', 'andhra', 'hyderabadi', 'kerala', 'chettinad', 'tandoori', 'vegetarian', 'veg', 'vegan', 'pure veg',
  'non veg', 'haleem', 'irani', 'chaat', 'pani puri', 'sandwich', 'sandwiches', 'noodles', 'chicken', 'mutton', 'fish',
  'kfc', 'mcdonalds', 'dominos', 'starbucks', 'barbeque', 'bbq', 'buffet', 'rooftop',
];

class PlaceCmd {
  final String kind; // where / share / nearby / named
  final PlaceCat? cat;
  final String cuisine, name, area;
  final bool openNow;
  const PlaceCmd(this.kind, {this.cat, this.cuisine = '', this.name = '', this.area = '', this.openNow = false});
}

class Place {
  final String name, kind, emoji, address, phone, hours, website, cuisine;
  final double lat, lon;
  double dist; // metres from you (or from the area searched)
  Place(this.name, this.kind, this.emoji, this.lat, this.lon,
      {this.address = '', this.phone = '', this.hours = '', this.website = '', this.cuisine = '', this.dist = 0});

  Map toMap() => {
        'n': name, 'k': kind, 'e': emoji, 'la': lat, 'lo': lon, 'd': dist.round(),
        if (address.isNotEmpty) 'a': address, if (phone.isNotEmpty) 'p': phone,
        if (hours.isNotEmpty) 'h': hours, if (website.isNotEmpty) 'w': website, if (cuisine.isNotEmpty) 'c': cuisine,
      };

  static Place fromMap(Map m) => Place('${m['n'] ?? ''}', '${m['k'] ?? ''}', '${m['e'] ?? '📍'}',
      (m['la'] as num?)?.toDouble() ?? 0, (m['lo'] as num?)?.toDouble() ?? 0,
      address: '${m['a'] ?? ''}', phone: '${m['p'] ?? ''}', hours: '${m['h'] ?? ''}', website: '${m['w'] ?? ''}',
      cuisine: '${m['c'] ?? ''}', dist: (m['d'] as num?)?.toDouble() ?? 0);
}

class Places {
  // ---------- understanding what you asked ----------
  static final _hereRe = RegExp(
      r'\s+(?:(?:near|around|close to|nearby)\s+(?:me|here|us|my (?:location|place|area))|near ?by|nearby|around here|around me|around|close by|closeby|in (?:my|this|the) (?:area|locality|vicinity|neighbou?rhood)|here)$');
  static final _openRe = RegExp(r'\s+(?:(?:that are |which are |that is )?open(?: now| right now| today| late| 24 ?(?:hours|hrs|7|x7))?|24 ?(?:hours|hrs|7|x7))$');
  static final _lead = RegExp(
      r'^(?:(?:hey )?vibe |please |can you |could you |show me |show |find me |find |search for |search |look for |looking for |list |get me |i want |i need |i m looking for |suggest |recommend |where can i (?:find|get|buy|eat|have) |where to (?:find|get|eat|buy) |is there an? |are there (?:any )?|any |some |good |best |top |nice |cheap |the |a |an |nearest |closest |near |nearby )+');

  static PlaceCmd? parse(String text) {
    final low = Brain.norm(text);
    // Other kinds of commands that happen to mention a place word
    if (RegExp(r'^(?:remind|tell|text|message|msg|send|call|ring|set|add|schedule|play|launch|draw|create|make|write|translate|whatsapp|email|mail)\b').hasMatch(low) &&
        !RegExp(r'^(?:send|share) (?:my )?(?:current |live )?location$').hasMatch(low)) {
      return null;
    }
    if (RegExp(r'^(?:where am i|where are we|where i am|where am i (?:right )?now|locate me|my (?:current )?(?:location|address)|current location|'
            r'what s my (?:current )?(?:location|address)|whats my (?:current )?(?:location|address)|what is my (?:current )?(?:location|address)|'
            r'show (?:me )?(?:my|where i am|on map)(?: location)?|show my location on (?:the )?maps?|which area (?:is this|am i in)|what area (?:is this|am i in))$')
        .hasMatch(low)) {
      return const PlaceCmd('where');
    }
    if (RegExp(r'^(?:share|send)(?: my)?(?: current| live)? location$').hasMatch(low)) return const PlaceCmd('share');

    var s = low;
    var here = false, openNow = false;
    final hadLead = _lead.hasMatch(s);
    final nearestWord = RegExp(r'^(?:\w+ )*?(?:nearest|closest|nearby|near)\b').hasMatch(s);
    for (var i = 0; i < 2; i++) {
      final o = _openRe.firstMatch(s);
      if (o != null) {
        openNow = true;
        s = s.substring(0, o.start);
      }
      final h = _hereRe.firstMatch(s);
      if (h != null) {
        here = true;
        s = s.substring(0, h.start);
      }
    }
    s = s.replaceFirst(_lead, '').trim();
    var area = '';
    final inArea = RegExp(r'^(.+?)\s+(?:in|at|near|around|close to)\s+(.+)$').firstMatch(s);
    if (inArea != null && !here) {
      s = inArea.group(1)!.trim();
      area = inArea.group(2)!.trim();
    }
    s = s.replaceFirst(_lead, '').trim();
    if (s.isEmpty) return null;

    var cuisine = '';
    for (final w in _cuisines) {
      if (RegExp('(^| )$w( |\$)').hasMatch(s)) {
        cuisine = w;
        break;
      }
    }
    PlaceCat? cat;
    var exact = false; // nothing but the kind of place (and a food word) was asked for
    for (final (re, c) in _cats) {
      final m = RegExp('(?:^| )(?:$re)(?: |\$)').firstMatch(s);
      if (m != null) {
        cat = c;
        final rest = s.replaceRange(m.start, m.end, ' ').replaceFirst(RegExp('(^| )${RegExp.escape(cuisine)}( |\$)'), ' ').trim();
        exact = rest.isEmpty || cuisine.isEmpty && rest.split(' ').length == 1 && _cuisines.contains(rest);
        break;
      }
    }
    // "hotels" with a food word means restaurants (in India "hotel" often means a place to eat)
    if (cuisine.isNotEmpty && (cat == null || cat.id == 'hotel')) cat = _cats.first.$2;
    if (cat != null && !const {'food', 'fastfood', 'cafe', 'bakery', 'bar', 'icecream'}.contains(cat.id)) cuisine = '';
    final hint = here || openNow || nearestWord || area.isNotEmpty;
    if (cat != null && (hint || (hadLead && (exact || cuisine.isNotEmpty)))) {
      return PlaceCmd('nearby', cat: cat, cuisine: cuisine, area: area, openNow: openNow);
    }
    // A name near you: "kfc near me", "nearest decathlon", "apollo pharmacy nearby"
    if (cat == null &&
        RegExp(r'\b(?:near me|nearby|near by|nearest|closest|around me|close by|close to me)\b').hasMatch(low) &&
        s.split(' ').length <= 5 &&
        !RegExp(r'^(?:who|what|how|why|when|which|whose|is|are|do|does|did|can|could|will|would|should|me|you|it|this|that|people|friends?|anyone|someone|somebody|weather|traffic|news|time|rain|temperature)\b').hasMatch(s)) {
      return PlaceCmd('named', name: s, openNow: openNow);
    }
    return null;
  }

  // ---------- network ----------
  static Future<dynamic> _http(String method, String url, {String? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final r = await client.openUrl(method, Uri.parse(url));
      r.headers.set('user-agent', _ua);
      r.headers.set('accept', 'application/json');
      if (body != null) {
        r.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
        r.write(body);
      }
      final res = await r.close().timeout(const Duration(seconds: 25));
      final raw = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('map server said ${res.statusCode}');
      return jsonDecode(raw);
    } finally {
      client.close();
    }
  }

  static const _overpass = ['https://overpass-api.de/api/interpreter', 'https://overpass.private.coffee/api/interpreter'];

  static Future<List> _query(String q) async {
    Object? last;
    for (final u in _overpass) {
      try {
        final j = await _http('POST', u, body: 'data=${Uri.encodeQueryComponent(q)}');
        return (j as Map)['elements'] as List? ?? const [];
      } catch (e) {
        last = e;
      }
    }
    throw last ?? 'map search failed';
  }

  static String _rx(String s) => s.replaceAll(RegExp(r'[\\^$.|?*+()\[\]{}"]'), ' ').trim();

  static double distance(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLa = rad(la2 - la1), dLo = rad(lo2 - lo1);
    final a = math.pow(math.sin(dLa / 2), 2) + math.cos(rad(la1)) * math.cos(rad(la2)) * math.pow(math.sin(dLo / 2), 2);
    return 2 * r * math.asin(math.sqrt(a.toDouble()));
  }

  static String human(double m) =>
      m < 1000 ? '${(m / 10).round() * 10} m' : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';

  static String _kindOf(Map t, PlaceCat? cat) {
    String nice(String v) => v.replaceAll('_', ' ').split(';').first;
    final cu = '${t['cuisine'] ?? ''}';
    for (final k in ['amenity', 'shop', 'tourism', 'leisure', 'healthcare', 'historic', 'craft', 'railway', 'highway', 'office']) {
      final v = t[k];
      if (v != null && v != 'yes') {
        final base = nice('$v');
        return cu.isNotEmpty && (k == 'amenity') ? '${nice(cu)} $base' : base;
      }
    }
    return cat?.label ?? 'Place';
  }

  static String _addrOf(Map t) {
    final parts = <String>[
      [t['addr:housenumber'], t['addr:street']].whereType<String>().join(' '),
      ...[t['addr:place'], t['addr:suburb'], t['addr:city']].whereType<String>(),
    ].where((x) => x.trim().isNotEmpty).toList();
    return parts.isEmpty ? '${t['addr:full'] ?? ''}' : parts.toSet().join(', ');
  }

  static List<Place> _parse(List els, double la, double lo, PlaceCat? cat) {
    final out = <Place>[];
    final seen = <String>{};
    for (final e in els) {
      if (e is! Map) continue;
      final t = (e['tags'] as Map?) ?? const {};
      final pla = ((e['lat'] ?? (e['center'] as Map?)?['lat']) as num?)?.toDouble();
      final plo = ((e['lon'] ?? (e['center'] as Map?)?['lon']) as num?)?.toDouble();
      if (pla == null || plo == null) continue;
      var name = '${t['name:en'] ?? t['name'] ?? t['brand'] ?? t['operator'] ?? ''}'.trim();
      if (name.isEmpty) {
        final k = _kindOf(t, cat);
        name = k == 'atm' ? 'ATM' : _cap(k);
      }
      final key = '${name.toLowerCase()}|${pla.toStringAsFixed(3)}|${plo.toStringAsFixed(3)}';
      if (!seen.add(key)) continue;
      out.add(Place(name, _kindOf(t, cat), cat?.emoji ?? '📍', pla, plo,
          address: _addrOf(t),
          phone: '${t['phone'] ?? t['contact:phone'] ?? t['contact:mobile'] ?? t['mobile'] ?? ''}'.split(';').first.trim(),
          hours: '${t['opening_hours'] ?? ''}',
          website: '${t['website'] ?? t['contact:website'] ?? ''}',
          cuisine: '${t['cuisine'] ?? ''}'.replaceAll('_', ' ').replaceAll(';', ', '),
          dist: distance(la, lo, pla, plo)));
    }
    out.sort((a, b) => a.dist.compareTo(b.dist));
    return out;
  }

  /// Places of one kind around a point. Widens the search when there's little nearby.
  static Future<List<Place>> nearby(PlaceCat cat, double la, double lo, {String cuisine = '', bool openNow = false}) async {
    final radii = cat.wide ? [3000, 10000] : [1500, 5000];
    var list = <Place>[];
    for (final r in radii) {
      final f = cuisine.isEmpty ? '' : '[~"^(name|cuisine|name:en)\$"~"${_rx(cuisine).replaceAll(' ', '.?')}",i]';
      final body = cat.filters.map((x) => 'nwr$x$f(around:$r,$la,$lo);').join();
      final els = await _query('[out:json][timeout:25];($body);out center tags 120;');
      list = _parse(els, la, lo, cat);
      if (openNow) list = list.where((p) => openAt(p.hours, DateTime.now()) != false).toList();
      if (list.length >= 6) break;
    }
    return list.take(30).toList();
  }

  /// Named places near a point: "kfc", "apollo pharmacy", "decathlon".
  static Future<List<Place>> named(String name, double la, double lo) async {
    final n = _rx(name).replaceAll(' ', '.?');
    if (n.isEmpty) return [];
    var list = <Place>[];
    for (final r in [5000, 20000]) {
      final els = await _query('[out:json][timeout:25];'
          '(nwr[~"^(name|brand|name:en)\$"~"$n",i][~"^(amenity|shop|tourism|leisure|office|healthcare|craft|historic|railway)\$"~"."](around:$r,$la,$lo););'
          'out center tags 60;');
      list = _parse(els, la, lo, null);
      if (list.isNotEmpty) break;
    }
    return list.take(25).toList();
  }

  /// "Banjara Hills" → its centre, preferring matches near you.
  static Future<(String, double, double)?> findArea(String q, {double? la, double? lo}) async {
    try {
      var url = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&accept-language=en&q=${Uri.encodeQueryComponent(q)}';
      if (la != null && lo != null) url += '&viewbox=${lo - 0.6},${la + 0.6},${lo + 0.6},${la - 0.6}';
      final j = await _http('GET', url) as List;
      if (j.isEmpty) return null;
      final r = j.first as Map;
      final name = '${r['display_name'] ?? q}'.split(',').take(2).join(',').trim();
      return (name, double.parse('${r['lat']}'), double.parse('${r['lon']}'));
    } catch (_) {
      return null;
    }
  }

  /// Your street and area from coordinates.
  static Future<Map?> reverse(double la, double lo) async {
    try {
      final j = await _http('GET',
          'https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=18&addressdetails=1&accept-language=en&lat=$la&lon=$lo') as Map;
      final a = (j['address'] as Map?) ?? const {};
      String? f(List<String> ks) {
        for (final k in ks) {
          final v = a[k];
          if (v is String && v.isNotEmpty) return v;
        }
        return null;
      }
      final street = [f(['house_number']), f(['road', 'pedestrian', 'footway'])].whereType<String>().join(' ');
      final place = '${j['name'] ?? ''}';
      final area = f(['neighbourhood', 'suburb', 'quarter', 'residential', 'hamlet', 'city_district']) ?? '';
      final city = f(['city', 'town', 'village', 'municipality', 'county', 'state_district']) ?? '';
      return {
        'place': place != street ? place : '',
        'street': street,
        'area': area,
        'city': city,
        'state': f(['state']) ?? '',
        'pin': f(['postcode']) ?? '',
        'full': '${j['display_name'] ?? ''}',
      };
    } catch (_) {
      return null;
    }
  }

  // ---------- opening hours ("Mo-Sa 10:00-22:00; Su off") ----------
  static const _days = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

  /// true = open, false = closed, null = unknown / too complex to read.
  static bool? openAt(String hours, DateTime t) {
    final h = hours.trim();
    if (h.isEmpty) return null;
    if (h == '24/7') return true;
    try {
      // Rules for each weekday (0 = Monday); later rules replace earlier ones
      final rules = List<List<(int, int)>?>.filled(7, null);
      for (var rule in h.split(';')) {
        rule = rule.trim();
        if (rule.isEmpty) continue;
        if (RegExp(r'PH|SH|easter|week|[A-Z][a-z]{2} ?\d', caseSensitive: true).hasMatch(rule.replaceAll(RegExp(r'\b(Mo|Tu|We|Th|Fr|Sa|Su)\b'), ''))) continue;
        final m = RegExp(r'^((?:(?:Mo|Tu|We|Th|Fr|Sa|Su)(?:\s*-\s*(?:Mo|Tu|We|Th|Fr|Sa|Su))?\s*,?\s*)+)?\s*(.*)$').firstMatch(rule)!;
        final daysPart = (m.group(1) ?? '').trim();
        final timePart = m.group(2)!.trim();
        final days = <int>{};
        if (daysPart.isEmpty) {
          days.addAll(List.generate(7, (i) => i));
        } else {
          for (final d in daysPart.split(',')) {
            final r = d.trim().split(RegExp(r'\s*-\s*'));
            if (r.first.isEmpty) continue;
            final a = _days.indexOf(r.first.trim());
            final b = r.length > 1 ? _days.indexOf(r[1].trim()) : a;
            if (a < 0 || b < 0) return null;
            for (var i = a;; i = (i + 1) % 7) {
              days.add(i);
              if (i == b) break;
            }
          }
        }
        List<(int, int)> spans;
        if (RegExp(r'^(off|closed)$', caseSensitive: false).hasMatch(timePart)) {
          spans = [];
        } else if (timePart == '24/7' || timePart == '00:00-24:00') {
          spans = [(0, 1440)];
        } else {
          spans = [];
          for (final p in timePart.split(',')) {
            final mm = RegExp(r'^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\+?$').firstMatch(p.trim());
            if (mm == null) return null;
            final s = int.parse(mm.group(1)!) * 60 + int.parse(mm.group(2)!);
            var e = int.parse(mm.group(3)!) * 60 + int.parse(mm.group(4)!);
            if (e <= s) e += 1440; // past midnight
            spans.add((s, e));
          }
        }
        for (final d in days) {
          rules[d] = spans;
        }
      }
      final now = t.hour * 60 + t.minute;
      final today = t.weekday - 1, yest = (today + 6) % 7;
      if (rules.every((r) => r == null)) return null;
      for (final (s, e) in rules[today] ?? const <(int, int)>[]) {
        if (now >= s && now < e) return true;
      }
      for (final (_, e) in rules[yest] ?? const <(int, int)>[]) {
        if (e > 1440 && now + 1440 < e) return true;
      }
      return rules[today] == null ? null : false;
    } catch (_) {
      return null;
    }
  }

  // ---------- Google Maps links ----------
  static String pinUrl(double la, double lo) => 'https://www.google.com/maps/search/?api=1&query=$la,$lo';

  static Future<void> openPlace(Place p) async {
    // geo: with the name finds the real listing (reviews, photos) at that spot
    final geo = 'geo:${p.lat},${p.lon}?q=${Uri.encodeComponent('${p.name}${p.address.isNotEmpty ? ', ${p.address}' : ''}')}';
    if (await Native.openUrl(geo, pkg: mapsPkg)) return;
    await Native.openUrl('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('${p.name} ${p.lat},${p.lon}')}');
  }

  static Future<void> directions(double la, double lo, {String mode = 'd'}) async {
    if (await Native.openUrl('google.navigation:q=$la,$lo&mode=$mode', pkg: mapsPkg)) return;
    await Native.openUrl('https://www.google.com/maps/dir/?api=1&destination=$la,$lo');
  }

  static Future<void> routePreview(double la, double lo) async {
    if (await Native.openUrl('https://www.google.com/maps/dir/?api=1&destination=$la,$lo', pkg: mapsPkg)) return;
    await Native.openUrl('https://www.google.com/maps/dir/?api=1&destination=$la,$lo');
  }

  static Future<void> showAllOnMap(String what, double la, double lo) async {
    if (await Native.openUrl('geo:$la,$lo?q=${Uri.encodeComponent(what)}', pkg: mapsPkg)) return;
    await Native.openUrl('https://www.google.com/maps/search/${Uri.encodeComponent(what)}/@$la,$lo,15z');
  }

  static Future<void> share(Place p) => Native.shareText(
      [p.name, if (p.address.isNotEmpty) p.address, pinUrl(p.lat, p.lon)].join('\n'),
      title: 'Share place');

  static Future<void> shareHere(double la, double lo, String label) =>
      Native.shareText('📍 I\'m here${label.isNotEmpty ? ' ($label)' : ''}: ${pinUrl(la, lo)}', title: 'Share location');
}

// =====================================================================================
// UI
// =====================================================================================

/// A small OpenStreetMap picture with a pin in the middle.
class MiniMap extends StatelessWidget {
  final double lat, lon;
  final double height;
  final int zoom;
  final VoidCallback? onTap;
  const MiniMap({super.key, required this.lat, required this.lon, this.height = 150, this.zoom = 16, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final n = math.pow(2, zoom).toDouble();
    final x = (lon + 180) / 360 * n;
    final latR = lat * math.pi / 180;
    final y = (1 - math.log(math.tan(latR) + 1 / math.cos(latR)) / math.pi) / 2 * n;
    final tx = x.floor(), ty = y.floor();
    final px = (x - tx) * 256, py = (y - ty) * 256; // the spot inside its tile
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth.isFinite ? box.maxWidth : 340.0;
      // Tile (tx,ty) placed so the spot lands in the centre
      final ox = w / 2 - px, oy = height / 2 - py;
      final tiles = <Widget>[];
      for (var dx = -2; dx <= 2; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final left = ox + dx * 256, top = oy + dy * 256;
          if (left > w || left + 256 < 0 || top > height || top + 256 < 0) continue;
          final xx = (tx + dx) % n.toInt(), yy = ty + dy;
          if (yy < 0 || yy >= n) continue;
          tiles.add(Positioned(
            left: left,
            top: top,
            width: 256,
            height: 256,
            child: Image.network('https://tile.openstreetmap.org/$zoom/$xx/$yy.png',
                headers: const {'User-Agent': _ua},
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => Container(color: c.input)),
          ));
        }
      }
      Widget map = Stack(clipBehavior: Clip.hardEdge, children: [
        Positioned.fill(child: Container(color: c.input)),
        ...tiles,
        Positioned(
          left: w / 2 - 14,
          top: height / 2 - 34,
          child: const Icon(Icons.location_on_rounded, size: 34, color: Color(0xFFEA4335), shadows: [Shadow(blurRadius: 6, color: Colors.black38)]),
        ),
        Positioned(
          right: 4,
          bottom: 2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            color: Colors.white70,
            child: const Text('© OpenStreetMap', style: TextStyle(fontSize: 9, color: Colors.black87)),
          ),
        ),
      ]);
      if (c.dark) {
        // Softer in dark mode
        map = ColorFiltered(colorFilter: const ColorFilter.mode(Color(0x33000000), BlendMode.darken), child: map);
      }
      return GestureDetector(
        onTap: onTap,
        child: ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: w, height: height, child: map)),
      );
    });
  }
}

Widget _pill(VC c, IconData icon, String label, VoidCallback onTap, {bool primary = false}) => Padding(
      padding: const EdgeInsets.only(right: 8, top: 8),
      child: Material(
        color: primary ? VC.blurple : c.input,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            prefs.tap();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: primary ? Colors.white : c.text),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: primary ? Colors.white : c.text, fontWeight: FontWeight.w600, fontSize: 13.5)),
            ]),
          ),
        ),
      ),
    );

/// "Where am I": a map, your street and area, and quick searches around you.
class WhereCard extends StatelessWidget {
  final Map card; // {type: where, lat, lon, acc, place, street, area, city, state, pin, approx}
  final void Function(String query) onSearch;
  const WhereCard({super.key, required this.card, required this.onSearch});

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final la = (card['lat'] as num).toDouble(), lo = (card['lon'] as num).toDouble();
    final acc = (card['acc'] as num?)?.toDouble() ?? 0;
    final title = [card['place'], card['street'], card['area']].map((e) => '${e ?? ''}').firstWhere((e) => e.isNotEmpty, orElse: () => 'You are here');
    final sub = [
      if ('${card['street'] ?? ''}'.isNotEmpty && title != card['street']) card['street'],
      if ('${card['area'] ?? ''}'.isNotEmpty && title != card['area']) card['area'],
      card['city'],
      card['pin'],
    ].map((e) => '${e ?? ''}').where((e) => e.isNotEmpty).join(', ');
    const quick = [('🍽️', 'Food', 'restaurants'), ('☕', 'Cafes', 'cafes'), ('🍺', 'Bars', 'bars'), ('🏧', 'ATM', 'atm'),
      ('⛽', 'Petrol', 'petrol pump'), ('💊', 'Pharmacy', 'pharmacy'), ('🏥', 'Hospital', 'hospital'), ('🛒', 'Groceries', 'groceries')];
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxWidth: 400),
      decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.divider)),
      padding: const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        MiniMap(lat: la, lon: lo, onTap: () => Native.openUrl(Places.pinUrl(la, lo), pkg: mapsPkg)),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: c.text, fontWeight: FontWeight.w800, fontSize: 17)),
            if (sub.isNotEmpty) Text(sub, style: TextStyle(color: c.muted, fontSize: 13.5)),
            const SizedBox(height: 2),
            Text(
                card['approx'] == true
                    ? 'Approximate: from your weather city'
                    : '${la.toStringAsFixed(5)}, ${lo.toStringAsFixed(5)}${acc > 0 ? '  ·  ±${Places.human(acc)}' : ''}',
                style: TextStyle(color: c.faint, fontSize: 11.5)),
            Wrap(children: [
              _pill(c, Icons.map_rounded, 'Open in Maps', () => Native.openUrl(Places.pinUrl(la, lo), pkg: mapsPkg), primary: true),
              _pill(c, Icons.share_rounded, 'Share', () => Places.shareHere(la, lo, '${card['area'] ?? card['city'] ?? ''}')),
            ]),
            const SizedBox(height: 10),
            Text('NEARBY', style: TextStyle(color: c.faint, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
            const SizedBox(height: 2),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (e, l, q) in quick)
                Material(
                  color: c.input,
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () {
                      prefs.tap();
                      onSearch('$q near me');
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text('$e $l', style: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// A list of places: name, distance, open now, and a directions button. Tap one for details.
class PlacesCard extends StatefulWidget {
  final Map card; // {type: places, title, emoji, near, lat, lon, query, items: [...]}
  const PlacesCard({super.key, required this.card});
  @override
  State<PlacesCard> createState() => _PlacesCardState();
}

class _PlacesCardState extends State<PlacesCard> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final c = VC.of(context);
    final card = widget.card;
    final items = List<Map>.from(card['items'] ?? const []).map(Place.fromMap).toList();
    final shown = _all ? items : items.take(6).toList();
    final la = (card['lat'] as num?)?.toDouble() ?? 0, lo = (card['lon'] as num?)?.toDouble() ?? 0;
    final now = DateTime.now();
    return Container(
      margin: const EdgeInsets.only(top: 6),
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(color: c.pane, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.divider)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
          child: Row(children: [
            Text('${card['emoji'] ?? '📍'}', style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${card['title']}', style: TextStyle(color: c.text, fontWeight: FontWeight.w800, fontSize: 15.5)),
                Text('${items.length} found · ${card['near']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.faint, fontSize: 12)),
              ]),
            ),
            TextButton.icon(
              onPressed: () {
                prefs.tap();
                Places.showAllOnMap('${card['query']}', la, lo);
              },
              icon: Icon(Icons.map_rounded, size: 18, color: VC.blurple),
              label: Text('Map', style: TextStyle(color: VC.blurple, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) Divider(height: 1, indent: 60, color: c.divider),
          _row(c, shown[i], now),
        ],
        if (items.length > 6)
          InkWell(
            onTap: () {
              prefs.tap();
              setState(() => _all = !_all);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(_all ? 'Show less' : 'Show ${items.length - 6} more',
                    style: TextStyle(color: VC.blurple, fontWeight: FontWeight.w700, fontSize: 13.5)),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
          child: Text('From OpenStreetMap · tap a place for reviews & photos in Google Maps',
              style: TextStyle(color: c.faint, fontSize: 10.5)),
        ),
      ]),
    );
  }

  Widget _row(VC c, Place p, DateTime now) {
    final open = Places.openAt(p.hours, now);
    return InkWell(
      onTap: () {
        prefs.tap();
        showPlaceSheet(context, p);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.input, borderRadius: BorderRadius.circular(10)),
            child: Text(p.emoji, style: const TextStyle(fontSize: 19)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontWeight: FontWeight.w700, fontSize: 14.5)),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: Places.human(p.dist)),
                  TextSpan(text: ' · ${_cap(p.cuisine.isNotEmpty ? p.cuisine : p.kind)}'),
                  if (open != null)
                    TextSpan(
                        text: open ? ' · Open' : ' · Closed',
                        style: TextStyle(color: open ? VC.green : VC.red, fontWeight: FontWeight.w700)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.faint, fontSize: 12),
              ),
              if (p.address.isNotEmpty)
                Text(p.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.faint, fontSize: 11.5)),
            ]),
          ),
          if (p.phone.isNotEmpty)
            IconButton(
              tooltip: 'Call',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.call_rounded, color: c.muted, size: 20),
              onPressed: () {
                prefs.tap();
                Native.call(p.phone);
              },
            ),
          Material(
            color: VC.blurple,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () {
                prefs.tap();
                Places.routePreview(p.lat, p.lon);
              },
              child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.directions_rounded, color: Colors.white, size: 20)),
            ),
          ),
        ]),
      ),
    );
  }
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Everything about one place, with Directions / Maps / Call / Share / Website.
void showPlaceSheet(BuildContext context, Place p) {
  final c = VC.of(context);
  final open = Places.openAt(p.hours, DateTime.now());
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: c.chat,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          MiniMap(lat: p.lat, lon: p.lon, height: 140, zoom: 17, onTap: () => Places.openPlace(p)),
          const SizedBox(height: 12),
          Text(p.name, style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
          Text(['${Places.human(p.dist)} away', _cap(p.cuisine.isNotEmpty ? '${p.cuisine} · ${p.kind}' : p.kind)].join(' · '),
              style: TextStyle(color: c.muted, fontSize: 13.5)),
          if (p.address.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.place_outlined, size: 18, color: c.faint),
              const SizedBox(width: 8),
              Expanded(child: Text(p.address, style: TextStyle(color: c.text, fontSize: 14))),
            ]),
          ],
          if (p.hours.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.schedule_rounded, size: 18, color: c.faint),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  if (open != null)
                    TextSpan(text: open ? 'Open now  ' : 'Closed now  ',
                        style: TextStyle(color: open ? VC.green : VC.red, fontWeight: FontWeight.w700)),
                  TextSpan(text: p.hours.replaceAll(';', '\n')),
                ]), style: TextStyle(color: c.text, fontSize: 14)),
              ),
            ]),
          ],
          if (p.phone.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.call_outlined, size: 18, color: c.faint),
              const SizedBox(width: 8),
              Text(p.phone, style: TextStyle(color: c.text, fontSize: 14)),
            ]),
          ],
          const SizedBox(height: 6),
          Wrap(children: [
            _pill(c, Icons.directions_rounded, 'Directions', () => Places.routePreview(p.lat, p.lon), primary: true),
            _pill(c, Icons.navigation_rounded, 'Start', () => Places.directions(p.lat, p.lon)),
            _pill(c, Icons.map_rounded, 'Reviews & photos', () => Places.openPlace(p)),
            if (p.phone.isNotEmpty) _pill(c, Icons.call_rounded, 'Call', () => Native.call(p.phone)),
            if (p.website.isNotEmpty)
              _pill(c, Icons.language_rounded, 'Website',
                  () => Native.openUrl(p.website.startsWith('http') ? p.website : 'https://${p.website}')),
            _pill(c, Icons.share_rounded, 'Share', () => Places.share(p)),
          ]),
        ]),
      ),
    ),
  );
}
