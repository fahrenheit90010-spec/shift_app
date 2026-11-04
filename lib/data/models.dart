import 'package:flutter/material.dart';

// Флаги функций (заглушки для будущей монетизации)
class Features {
  static const bool widgets = false;       // Pro: виджеты
  static const bool pdfExport = false;     // Pro: PDF
  static const bool advancedStats = false; // Pro: продвинутая статистика
  static const bool cloudSync = false;     // Подписка: облако
  static const bool showMyApps = false;    // Страница "Мои приложения"
  static const bool proSectionVisible = true; // Показывать раздел Pro (заглушка)
}

// Тип смены (День, Ночь, Сутки, Больничный, Отпуск + свои)
class ShiftType {
  final String id;          // уникальный идентификатор (например, 'day')
  final String name;        // название ("День")
  final String letter;      // буква для кружка ("Д")
  final Color color;        // цвет кружка
  final double plannedHours; // плановые часы
  final bool countInSalary;  // считать ли в зарплате

  const ShiftType({
    required this.id,
    required this.name,
    required this.letter,
    required this.color,
    required this.plannedHours,
    required this.countInSalary,
  });

  // Предустановленные типы
static List<ShiftType> defaults() => [
  const ShiftType(id: 'day', name: 'День', letter: 'Д', color: Color(0xFF90CAF9), plannedHours: 8, countInSalary: true),      // светло-синий
  const ShiftType(id: 'night', name: 'Ночь', letter: 'Н', color: Color(0xFFCE93D8), plannedHours: 12, countInSalary: true),     // светло-фиолетовый
  const ShiftType(id: 'daily', name: 'Сутки', letter: 'С', color: Color(0xFFFFCC80), plannedHours: 24, countInSalary: true),     // светло-оранжевый
  const ShiftType(id: 'sick', name: 'Больничный', letter: 'Б', color: Color(0xFFEF9A9A), plannedHours: 0, countInSalary: false), // светло-красный
  const ShiftType(id: 'vacation', name: 'Отпуск', letter: 'О', color: Color(0xFFA5D6A7), plannedHours: 0, countInSalary: false), // светло-зелёный
];

  // Для сохранения в JSON (потом пригодится)
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'letter': letter,
    'color': color.toARGB32(),
    'plannedHours': plannedHours,
    'countInSalary': countInSalary,
  };

  factory ShiftType.fromJson(Map<String, dynamic> json) => ShiftType(
    id: json['id'],
    name: json['name'],
    letter: json['letter'],
    color: Color((json['color'] as num).toInt()),
    plannedHours: json['plannedHours'].toDouble(),
    countInSalary: json['countInSalary'],
  );
}

// Ставка (за час / за смену / за неделю / за месяц)
enum RateType { perHour, perShift, perWeek, perMonth }

class Rate {
  final String id;
  final String name;       // "Дневная"
  final RateType type;     // за час / смену / неделю / месяц
  final double value;      // 300, 5000 и т.д.

  const Rate({
    required this.id,
    required this.name,
    required this.type,
    required this.value,
  });

  static List<Rate> defaults() => [
    const Rate(id: 'day_rate', name: 'Дневная', type: RateType.perHour, value: 300),
    const Rate(id: 'night_rate', name: 'Ночная', type: RateType.perHour, value: 400),
    const Rate(id: 'daily_rate', name: 'Сутки', type: RateType.perShift, value: 5000),
  ];
}   // <-- ЗАКРЫВАЕМ КЛАСС Rate

// Запись смены: тип + фактические часы + ставка
class ShiftEntry {
  String typeId;        // id типа смены ('day', 'night', ...)
  double actualHours;   // фактические часы (план + переработка - недоработка)
  String? rateId;       // id выбранной ставки (может быть null, пока не выбрана)

  ShiftEntry({
    required this.typeId,
    required this.actualHours,
    this.rateId,
  });

  // Для сохранения в shared_preferences (строка "typeId|hours|rateId")
  String toStorageString() {
    return '$typeId|$actualHours|${rateId ?? ''}';
  }

  factory ShiftEntry.fromStorageString(String s) {
    final parts = s.split('|');
    return ShiftEntry(
      typeId: parts[0],
      actualHours: double.tryParse(parts[1]) ?? 0,
      rateId: parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null,
    );
  }
}   // <-- ЗАКРЫВАЕМ КЛАСС ShiftEntry

