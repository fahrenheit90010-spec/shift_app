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
  static const bool photos = true; // Pro: фото в заметках
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
  final String id;
  String typeId;
  DateTime startTime;
  DateTime endTime;
  int breakMinutes;
  double? overrideRateValue;
  RateType? overrideRateType;
  double? overrideCoefOvertime;
  double? overrideCoefUndertime;

  ShiftEntry({
    required this.id,
    required this.typeId, required this.startTime, required this.endTime,
    this.breakMinutes = 0,
    this.overrideRateValue, this.overrideRateType,
    this.overrideCoefOvertime, this.overrideCoefUndertime,
  });

  double get actualHours {
    final diff = endTime.difference(startTime).inMinutes - breakMinutes;
    return diff > 0 ? diff / 60.0 : 0;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'typeId': typeId,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime.toIso8601String(),
    'breakMinutes': breakMinutes,
    'overrideRateValue': overrideRateValue,
    'overrideRateType': overrideRateType?.index,
    'overrideCoefOvertime': overrideCoefOvertime,
    'overrideCoefUndertime': overrideCoefUndertime,
  };

  factory ShiftEntry.fromJson(Map<String, dynamic> json) => ShiftEntry(
    id: json['id'] as String,
    typeId: json['typeId'] as String,
    startTime: DateTime.parse(json['startTime'] as String),
    endTime: DateTime.parse(json['endTime'] as String),
    breakMinutes: (json['breakMinutes'] ?? 0) as int,
    overrideRateValue: (json['overrideRateValue'] as num?)?.toDouble(),
    overrideRateType: json['overrideRateType'] != null
        ? RateType.values[json['overrideRateType'] as int]
        : null,
    overrideCoefOvertime: (json['overrideCoefOvertime'] as num?)?.toDouble(),
    overrideCoefUndertime: (json['overrideCoefUndertime'] as num?)?.toDouble(),
  );
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
  final String? fixedTypeId;

  const ShiftTemplate({
    required this.id, required this.name, required this.cycle,
    required this.description, required this.priority, this.isCustom = false,
    this.fixedTypeId,
  });

  static List<ShiftTemplate> predefined() => [
    const ShiftTemplate(id: '2_2', name: '2/2', cycle: ['work','work','rest','rest'], description: '2 работы, 2 отдыха (цикл 4 дня)', priority: 1),
    const ShiftTemplate(id: '5_2', name: '5/2', cycle: ['work','work','work','work','work','rest','rest'], description: '5 работ, 2 отдыха (цикл 7 дней)', priority: 2),
    const ShiftTemplate(id: '3_3', name: '3/3', cycle: ['work','work','work','rest','rest','rest'], description: '3 работы, 3 отдыха (цикл 6 дней)', priority: 3),
    const ShiftTemplate(id: '4_3', name: '4/3', cycle: ['work','work','work','work','rest','rest','rest'], description: '4 работы, 3 отдыха (цикл 7 дней)', priority: 4),
    const ShiftTemplate(id: '1_3', name: '1/3', cycle: ['work','rest','rest','rest'], description: '1 работа, 3 отдыха (цикл 4 дня)', priority: 5),
  ];

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'cycle': cycle, 'description': description,
    'priority': priority, 'isCustom': isCustom,
    'fixedTypeId': fixedTypeId,
  };

  factory ShiftTemplate.fromJson(Map<String, dynamic> json) => ShiftTemplate(
    id: json['id'], name: json['name'],
    cycle: List<String>.from(json['cycle']),
    description: json['description'] ?? '',
    priority: json['priority'] ?? 1,
    isCustom: json['isCustom'] ?? false,
    fixedTypeId: json['fixedTypeId'],
  );
}

// Заметка (без чекбоксов, с несколькими фото)
class Note {
  final String id;
  final String date;
  final String title;
  final String text;
  final List<String> photoPaths;
  final String? photoComment;
  final DateTime createdAt;

  Note({
    required this.id,
    required this.date,
    this.title = '',
    required this.text,
    List<String>? photoPaths,
    this.photoComment,
    required this.createdAt,
  }) : photoPaths = photoPaths ?? [];

  Map<String, dynamic> toJson() => {
    'id': id, 'date': date, 'title': title, 'text': text,
    'photoPaths': photoPaths,
    'photoComment': photoComment,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Note.fromJson(Map<String, dynamic> json) {
    // Миграция: старые заметки хранили photoPath (String?), новые — photoPaths (List<String>)
    List<String> paths;
    if (json['photoPaths'] is List) {
      paths = List<String>.from((json['photoPaths'] as List).whereType<String>());
    } else if (json['photoPath'] is String && (json['photoPath'] as String).isNotEmpty) {
      paths = [json['photoPath'] as String];
    } else {
      paths = [];
    }
    return Note(
      id: json['id'],
      date: json['date'],
      title: json['title'] ?? '',
      text: json['text'] ?? '',
      photoPaths: paths,
      photoComment: json['photoComment'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}

// Задача (одна строка, чекбокс)
class Task {
  final String id;
  final String date;
  final String text;
  final bool isDone;
  final DateTime createdAt;

  Task({
    required this.id,
    required this.date,
    required this.text,
    this.isDone = false,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'date': date, 'text': text,
    'isDone': isDone,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Task.fromJson(Map<String, dynamic> json) => Task(
    id: json['id'],
    date: json['date'],
    text: json['text'],
    isDone: json['isDone'] ?? false,
    createdAt: DateTime.parse(json['createdAt']),
  );
}