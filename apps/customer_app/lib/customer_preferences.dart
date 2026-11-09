import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QuickRideCustomerPreferences {
  QuickRideCustomerPreferences._();

  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.system);
  static final ValueNotifier<Locale> locale =
      ValueNotifier<Locale>(const Locale('en'));

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final theme = prefs.getString('customer_theme_mode');
    themeMode.value = ThemeMode.values.firstWhere(
      (value) => value.name == theme,
      orElse: () => ThemeMode.system,
    );
    locale.value = Locale(prefs.getString('customer_language_code') == 'hi' ? 'hi' : 'en');
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
