import 'package:flutter/material.dart';

class Features {
  static const bool widgets = false;
  static const bool pdfExport = false;
  static const bool advancedStats = false;
  static const bool cloudSync = false;
  static const bool showMyApps = false;
  static const bool proSectionVisible = true;
}

class ShiftType {
  final String id;
  final String name;
  final String letter;
  final Color color;
  final double plannedHours;
  final bool countInSalary;
  final double rateValue;
  final RateType rateType;
  final double coefOvertime;
  final double coefUndertime;

  const ShiftType({
    required this.id,
    required this.name,
    required this.letter,
    required this.color,
    required this.plannedHours,
    required this.countInSalary,
    required this.rateValue,
    required this.rateType,
    required this.coefOvertime,
    required this.coefUndertime,
  });

  static List<ShiftType> defaults() => [
    const ShiftType(id: 'day', name: 'День', letter: 'Д', color: Color(0xFF90CAF9), plannedHours: 8, countInSalary: true, rateValue: 300, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0),
    const ShiftType(id: 'night', name: 'Ночь', letter: 'Н', color: Color(0xFFCE93D8), plannedHours: 12, countInSalary: true, rateValue: 400, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0),
    const ShiftType(id: 'daily', name: 'Сутки', letter: 'С', color: Color(0xFFFFCC80), plannedHours: 24, countInSalary: true, rateValue: 5000, rateType: RateType.perShift, coefOvertime: 1.0, coefUndertime: 1.0),
    const ShiftType(id: 'sick', name: 'Больничный', letter: 'Б', color: Color(0xFFEF9A9A), plannedHours: 0, countInSalary: false, rateValue: 0, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0),
    const ShiftType(id: 'vacation', name: 'Отпуск', letter: 'О', color: Color(0xFFA5D6A7), plannedHours: 0, countInSalary: false, rateValue: 0, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0),
  ];

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'letter': letter, 'color': color.toARGB32(),
    'plannedHours': plannedHours, 'countInSalary': countInSalary,
    'rateValue': rateValue, 'rateType': rateType.index,
    'coefOvertime': coefOvertime, 'coefUndertime': coefUndertime,
  };

  factory ShiftType.fromJson(Map<String, dynamic> json) => ShiftType(
    id: json['id'], name: json['name'], letter: json['letter'],
    color: Color((json['color'] as num).toInt()),
    plannedHours: json['plannedHours'].toDouble(),
    countInSalary: json['countInSalary'],
    rateValue: (json['rateValue'] ?? 0).toDouble(),
    rateType: RateType.values[json['rateType'] ?? 0],
    coefOvertime: (json['coefOvertime'] ?? 1.0).toDouble(),
    coefUndertime: (json['coefUndertime'] ?? 1.0).toDouble(),
  );
}

enum RateType { perHour, perShift }

class ShiftEntry {
  String typeId;
  double actualHours;
  double? overrideRateValue;
  RateType? overrideRateType;
  double? overrideCoefOvertime;
  double? overrideCoefUndertime;

  ShiftEntry({
    required this.typeId,
    required this.actualHours,
    this.overrideRateValue,
    this.overrideRateType,
    this.overrideCoefOvertime,
    this.overrideCoefUndertime,
  });

  String toStorageString() {
    return '$typeId|$actualHours|${overrideRateValue ?? ''}|${overrideRateType?.index ?? ''}|${overrideCoefOvertime ?? ''}|${overrideCoefUndertime ?? ''}';
  }

  factory ShiftEntry.fromStorageString(String s) {
    final parts = s.split('|');
    return ShiftEntry(
      typeId: parts[0],
      actualHours: double.tryParse(parts[1]) ?? 0,
      overrideRateValue: parts.length > 2 && parts[2].isNotEmpty ? double.tryParse(parts[2]) : null,
      overrideRateType: parts.length > 3 && parts[3].isNotEmpty ? RateType.values[int.parse(parts[3])] : null,
      overrideCoefOvertime: parts.length > 4 && parts[4].isNotEmpty ? double.tryParse(parts[4]) : null,
      overrideCoefUndertime: parts.length > 5 && parts[5].isNotEmpty ? double.tryParse(parts[5]) : null,
    );
  }
}

// Запись о закрытом месяце
class MonthRecord {
  final int year;
  final int month;
  final int workShifts;
  final int sickDays;
  final int vacationDays;
  final double totalHours;
  final double overtimeHours;
  final double undertimeHours;
  final double totalAmount;
  final String rateSnapshot;
  final DateTime closedAt;

  MonthRecord({
    required this.year,
    required this.month,
    required this.workShifts,
    required this.sickDays,
    required this.vacationDays,
    required this.totalHours,
    required this.overtimeHours,
    required this.undertimeHours,
    required this.totalAmount,
    required this.rateSnapshot,
    required this.closedAt,
  });

  String toStorageString() {
    return '$year|$month|$workShifts|$sickDays|$vacationDays|$totalHours|$overtimeHours|$undertimeHours|$totalAmount|$rateSnapshot|${closedAt.toIso8601String()}';
  }

  factory MonthRecord.fromStorageString(String s) {
    final p = s.split('|');
    return MonthRecord(
      year: int.parse(p[0]),
      month: int.parse(p[1]),
      workShifts: int.parse(p[2]),
      sickDays: int.parse(p[3]),
      vacationDays: int.parse(p[4]),
      totalHours: double.parse(p[5]),
      overtimeHours: double.parse(p[6]),
      undertimeHours: double.parse(p[7]),
      totalAmount: double.parse(p[8]),
      rateSnapshot: p[9],
      closedAt: DateTime.parse(p[10]),
    );
  }
}