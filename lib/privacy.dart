import 'chat.dart';

/// Keeps OTPs, bank/payment alerts and similar private details away from cloud AI.
/// On-phone AI (Gemini Nano) may still see them, because nothing leaves the phone.
class Privacy {
  static final _otp = RegExp(
      r'(otp|one.?time|verification|verify|security code|login code|passcode|pass code|\bpin\b|cvv|auth(entication)? code|2fa|code is|is your code)',
      caseSensitive: false);
  static final _digits = RegExp(r'\b\d{4,8}\b');
  static final _money = RegExp(
      r'(debited|credited|a/c|acct|account (no|number|ending)|avl\.? ?bal|available bal|balance|card ending|card no|\bupi\b|txn|transaction|ifsc|neft|imps|rtgs|emi|loan|statement|(rs\.?|inr|₹)\s?\d)',
      caseSensitive: false);
  static final _secret = RegExp(r'(password|passwd|pwd|seed phrase|recovery phrase|private key|aadhaar|aadhar|\bpan\b card|ssn)',
      caseSensitive: false);

  static const _apps = [
    'phonepe', 'paytm', 'nbu.paisa', 'npci', 'bhim', 'cred', 'groww', 'zerodha', 'kite', 'angelone', 'upstox',
    'mobikwik', 'freecharge', 'amazon.pay', 'authenticator', 'authy', 'okta', 'lastpass', 'bitwarden', '1password',
    'bank', 'banking', 'upi', 'wallet', 'finance', 'finserv', 'broking', 'demat', 'mutualfund', 'insurance', 'sbi',
    'hdfc', 'icici', 'axis', 'kotak', 'yesbank', 'idfc', 'indusind', 'bob', 'pnb', 'canara', 'federal', 'rbl',
  ];

  static bool app(String? pkg) {
    if (pkg == null) return false;
    final p = pkg.toLowerCase();
    return _apps.any(p.contains);
  }

  static bool text(String? s) {
    if (s == null || s.isEmpty) return false;
    if (_secret.hasMatch(s)) return true;
    if (_otp.hasMatch(s) && _digits.hasMatch(s)) return true;
    return _money.hasMatch(s);
  }

  /// True if this line must never be sent to a cloud AI.
  static bool msg(Msg m) => app(m.pkg) || text(m.text) || text(m.title) || text(m.quote);
}

bool isMissCmd(String input) => RegExp(
        r'^(what did i miss|what have i missed|anything i missed|catch me up|any (new )?(messages|notifications)|who (messaged|texted)( me)?|summari[sz]e (my )?notifications|what.?s new)\W*$',
        caseSensitive: false)
    .hasMatch(input.trim());
