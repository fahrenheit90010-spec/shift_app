import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

class Holiday {
  final DateTime date;
  final String name;
  final bool isWorkday;
  final String? transferFrom;
  final String? transferReason;

  Holiday({
    required this.date,
    required this.name,
    required this.isWorkday,
    this.transferFrom,
    this.transferReason,
  });

  // Превращает JSON-объект в Holiday
  factory Holiday.fromJson(Map<String, dynamic> json) {
    return Holiday(
      date: DateTime.parse(json['date'] as String),
      name: json['name'] as String? ?? '',
      isWorkday: json['is_workday'] as bool? ?? false,
      transferFrom: json['transfer_from'] as String?,
      transferReason: json['transfer_reason'] as String?,
    );
  }
}

// Загружает список праздников из assets/holidays.json
Future<List<Holiday>> loadHolidays() async {
  // 1. Читаем файл как строку
  final raw = await rootBundle.loadString('assets/holidays.json');
  
  // 2. Парсим строку как JSON
  final data = jsonDecode(raw) as Map<String, dynamic>;
  
  // 3. Достаём список "holidays"
  final list = data['holidays'] as List<dynamic>;
  
  // 4. Превращаем каждый элемент в объект Holiday
  return list.map((e) => Holiday.fromJson(e as Map<String, dynamic>)).toList();
}