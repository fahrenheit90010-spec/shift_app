import 'package:flutter/material.dart';

class Features {
  static const bool widgets = false;
  static const bool pdfExport = false;
  static const bool advancedStats = false;
  static const bool cloudSync = false;
  static const bool showMyApps = false;
  static const bool proSectionVisible = true;
  static const bool multipleTemplates = true;
  static const bool customTemplates = true;
  static const bool categories = true;
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
  final int startHour;
  final int startMinute;

  const ShiftType({
    required this.id, required this.name, required this.letter, required this.color,
    required this.plannedHours, required this.countInSalary,
    required this.rateValue, required this.rateType,
    required this.coefOvertime, required this.coefUndertime,
    this.startHour = 8, this.startMinute = 0,
  });

  static List<ShiftType> defaults() => [
    const ShiftType(id: 'day', name: 'День', letter: 'Д', color: Color(0xFF90CAF9), plannedHours: 8, countInSalary: true, rateValue: 300, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0, startHour: 8),
    const ShiftType(id: 'night', name: 'Ночь', letter: 'Н', color: Color(0xFFCE93D8), plannedHours: 12, countInSalary: true, rateValue: 400, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0, startHour: 20),
    const ShiftType(id: 'daily', name: 'Сутки', letter: 'С', color: Color(0xFFFFCC80), plannedHours: 24, countInSalary: true, rateValue: 5000, rateType: RateType.perShift, coefOvertime: 1.0, coefUndertime: 1.0, startHour: 8),
    const ShiftType(id: 'sick', name: 'Больничный', letter: 'Б', color: Color(0xFFEF9A9A), plannedHours: 0, countInSalary: false, rateValue: 0, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0),
    const ShiftType(id: 'vacation', name: 'Отпуск', letter: 'О', color: Color(0xFFA5D6A7), plannedHours: 0, countInSalary: false, rateValue: 0, rateType: RateType.perHour, coefOvertime: 1.0, coefUndertime: 1.0),
  ];

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'letter': letter, 'color': color.toARGB32(),
    'plannedHours': plannedHours, 'countInSalary': countInSalary,
    'rateValue': rateValue, 'rateType': rateType.index,
    'coefOvertime': coefOvertime, 'coefUndertime': coefUndertime,
    'startHour': startHour, 'startMinute': startMinute,
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
    startHour: json['startHour'] ?? 8,
    startMinute: json['startMinute'] ?? 0,
  );
}

enum RateType { perHour, perShift }

class ShiftEntry {
  String typeId;
  DateTime startTime;
  DateTime endTime;
  int breakMinutes;
  String? groupId;
  bool isContinuation;
  double? overrideRateValue;
  RateType? overrideRateType;
  double? overrideCoefOvertime;
  double? overrideCoefUndertime;

  ShiftEntry({
    required this.typeId, required this.startTime, required this.endTime,
    this.breakMinutes = 0, this.groupId, this.isContinuation = false,
    this.overrideRateValue, this.overrideRateType,
    this.overrideCoefOvertime, this.overrideCoefUndertime,
  });

  double get actualHours {
    final diff = endTime.difference(startTime).inMinutes - breakMinutes;
    return diff > 0 ? diff / 60.0 : 0;
  }

  String toStorageString() {
    return '$typeId|${startTime.toIso8601String()}|${endTime.toIso8601String()}|$breakMinutes|${groupId ?? ''}|$isContinuation|${overrideRateValue ?? ''}|${overrideRateType?.index ?? ''}|${overrideCoefOvertime ?? ''}|${overrideCoefUndertime ?? ''}';
  }

  factory ShiftEntry.fromStorageString(String s) {
    final parts = s.split('|');
    return ShiftEntry(
      typeId: parts[0],
      startTime: DateTime.parse(parts[1]),
      endTime: DateTime.parse(parts[2]),
      breakMinutes: int.tryParse(parts[3]) ?? 0,
      groupId: parts.length > 4 && parts[4].isNotEmpty ? parts[4] : null,
      isContinuation: parts.length > 5 && parts[5] == 'true',
      overrideRateValue: parts.length > 6 && parts[6].isNotEmpty ? double.tryParse(parts[6]) : null,
      overrideRateType: parts.length > 7 && parts[7].isNotEmpty ? RateType.values[int.parse(parts[7])] : null,
      overrideCoefOvertime: parts.length > 8 && parts[8].isNotEmpty ? double.tryParse(parts[8]) : null,
      overrideCoefUndertime: parts.length > 9 && parts[9].isNotEmpty ? double.tryParse(parts[9]) : null,
    );
  }
}

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
    required this.year, required this.month,
    required this.workShifts, required this.sickDays, required this.vacationDays,
    required this.totalHours, required this.overtimeHours, required this.undertimeHours,
    required this.totalAmount, required this.rateSnapshot, required this.closedAt,
  });

  String toStorageString() {
    return '$year|$month|$workShifts|$sickDays|$vacationDays|$totalHours|$overtimeHours|$undertimeHours|$totalAmount|$rateSnapshot|${closedAt.toIso8601String()}';
  }

  factory MonthRecord.fromStorageString(String s) {
    final p = s.split('|');
    return MonthRecord(
      year: int.parse(p[0]), month: int.parse(p[1]),
      workShifts: int.parse(p[2]), sickDays: int.parse(p[3]), vacationDays: int.parse(p[4]),
      totalHours: double.parse(p[5]), overtimeHours: double.parse(p[6]), undertimeHours: double.parse(p[7]),
      totalAmount: double.parse(p[8]), rateSnapshot: p[9],
      closedAt: DateTime.parse(p[10]),
    );
  }
}

class TemplateStep {
  final String? typeId;
  const TemplateStep({this.typeId});
  bool get isRest => typeId == null;
}

class ShiftTemplate {
  final String id;
  final String name;
  final List<String> cycle;
  final String description;
  final int priority;
  final bool isCustom;

  const ShiftTemplate({
    required this.id, required this.name, required this.cycle,
    required this.description, required this.priority, this.isCustom = false,
  });

  static List<ShiftTemplate> predefined() => [
    const ShiftTemplate(id: '2_2', name: '2/2', cycle: ['work','work','rest','rest'], description: '2 рабочих, 2 отдыха', priority: 1),
    const ShiftTemplate(id: '5_2', name: '5/2', cycle: ['work','work','work','work','work','rest','rest'], description: '5 рабочих, 2 отдыха', priority: 2),
    const ShiftTemplate(id: '3_3', name: '3/3', cycle: ['work','work','work','rest','rest','rest'], description: '3 рабочих, 3 отдыха', priority: 3),
    const ShiftTemplate(id: '2_2_3', name: '2/2/3', cycle: ['work','work','rest','rest','work','work','work'], description: '2 рабочих, 2 отдыха, 3 рабочих', priority: 4),
    const ShiftTemplate(id: '1_3', name: 'Сутки через трое', cycle: ['work','rest','rest','rest'], description: '1 рабочий, 3 отдыха', priority: 5),
  ];

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'cycle': cycle, 'description': description,
    'priority': priority, 'isCustom': isCustom,
  };

  factory ShiftTemplate.fromJson(Map<String, dynamic> json) => ShiftTemplate(
    id: json['id'], name: json['name'],
    cycle: List<String>.from(json['cycle']),
    description: json['description'] ?? '',
    priority: json['priority'] ?? 1,
    isCustom: json['isCustom'] ?? false,
  );
}