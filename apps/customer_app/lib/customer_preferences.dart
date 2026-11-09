import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QuickRideCustomerPreferences {
  QuickRideCustomerPreferences._();

  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.system);
  static final ValueNotifier<Locale> locale =
      ValueNotifier<Locale>(const Locale('en'));
  static final ValueNotifier<List<Map<String, dynamic>>> recentPlaces =
      ValueNotifier<List<Map<String, dynamic>>>(const []);
  static final ValueNotifier<List<Map<String, dynamic>>> savedPlaces =
      ValueNotifier<List<Map<String, dynamic>>>(const []);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final theme = prefs.getString('customer_theme_mode');
    themeMode.value = ThemeMode.values.firstWhere(
      (value) => value.name == theme,
      orElse: () => ThemeMode.system,
    );
    locale.value = Locale(prefs.getString('customer_language_code') == 'hi' ? 'hi' : 'en');
    savedPlaces.value = (prefs.getStringList('customer_saved_places') ?? const [])
        .map((value) {
          try {
            final decoded = jsonDecode(value);
            return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
          } catch (_) {
            return <String, dynamic>{};
          }
        })
        .where((place) => place['name'] is String && place['address'] is String &&
            place['latitude'] is num && place['longitude'] is num)
        .take(20)
        .toList(growable: false);
    recentPlaces.value = (prefs.getStringList('customer_recent_places') ?? const [])
        .map((value) {
          try {
            final decoded = jsonDecode(value);
            return decoded is Map
                ? Map<String, dynamic>.from(decoded)
                : <String, dynamic>{};
          } catch (_) {
            return <String, dynamic>{};
          }
        })
        .where((place) =>
            place['name'] is String &&
            place['address'] is String &&
            place['latitude'] is num &&
            place['longitude'] is num)
        .take(6)
        .toList(growable: false);
  }

  static Future<void> addRecentPlace(Map<String, dynamic> place) async {
    final key = '${place['latitude']},${place['longitude']}';
    final updated = [
      place,
      ...recentPlaces.value.where(
        (item) => '${item['latitude']},${item['longitude']}' != key,
      ),
    ].take(6).toList(growable: false);
    recentPlaces.value = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'customer_recent_places',
      updated.map(jsonEncode).toList(growable: false),
    );
  }

  static Future<void> addSavedPlace(Map<String, dynamic> place) async {
    final key = '${place['latitude']},${place['longitude']}';
    final updated = [
      place,
      ...savedPlaces.value.where(
        (item) => '${item['latitude']},${item['longitude']}' != key,
      ),
    ].take(20).toList(growable: false);
    savedPlaces.value = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'customer_saved_places',
      updated.map(jsonEncode).toList(growable: false),
    );
  }

  static Future<void> removeSavedPlace(Map<String, dynamic> place) async {
    final key = '${place['latitude']},${place['longitude']}';
    final updated = savedPlaces.value
        .where((item) => '${item['latitude']},${item['longitude']}' != key)
        .toList(growable: false);
    savedPlaces.value = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'customer_saved_places',
      updated.map(jsonEncode).toList(growable: false),
    );
  }

  static Future<void> clearRecentPlaces() async {
    recentPlaces.value = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('customer_recent_places');
  }

  static Future<void> setThemeMode(ThemeMode value) async {
    themeMode.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('customer_theme_mode', value.name);
  }

  static Future<void> setLanguage(String value) async {
    final code = value == 'hi' ? 'hi' : 'en';
    locale.value = Locale(code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('customer_language_code', code);
  }
}
