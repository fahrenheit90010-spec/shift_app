import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:convert';
import 'data/models.dart';
import 'data/holiday_loader.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';
/// Сжимает изображение в отдельном изоляте (не блокирует UI).
/// Возвращает JPEG-байты или null, если декодировать не удалось.
/// Должна быть на верхнем уровне файла — compute() не видит методы классов.
Future<Uint8List?> _compressImageInIsolate(Map<String, dynamic> params) async {
  final file = File(params['path'] as String);
  final bytes = await file.readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  // Ресайз: длинная сторона до 1080 px (аналог minWidth/minHeight у flutter_image_compress)
  final resized = (decoded.width >= decoded.height)
      ? img.copyResize(decoded, width: 1080)
      : img.copyResize(decoded, height: 1080);

  final jpeg = img.encodeJpg(resized, quality: params['quality'] as int);
  return Uint8List.fromList(jpeg);
}
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru_RU', null);
  runApp(const ShiftApp());
}

ThemeData _buildDarkTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFF121212),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF64B5F6), secondary: Color(0xFF64B5F6),
      surface: Color(0xFF1E1E1E), onSurface: Color(0xFFE0E0E0),
    ),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1E1E1E), foregroundColor: Color(0xFFE0E0E0), elevation: 0),
    cardColor: const Color(0xFF1E1E1E),
    dialogTheme: const DialogThemeData(backgroundColor: Color(0xFF1E1E1E)),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: Color(0xFFE0E0E0)),
      bodySmall: TextStyle(color: Color(0xFF9E9E9E)),
    ),
  );
}

ThemeData _buildLightTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF64B5F6), brightness: Brightness.light),
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(backgroundColor: Colors.white, foregroundColor: Colors.black, elevation: 0),
  );
}

class ShiftApp extends StatefulWidget {
  const ShiftApp({super.key});
  @override
  State<ShiftApp> createState() => _ShiftAppState();
}

class _ShiftAppState extends State<ShiftApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('theme_mode') ?? 'light';
    setState(() {
      _themeMode = saved == 'dark' ? ThemeMode.dark : saved == 'system' ? ThemeMode.system : ThemeMode.light;
    });
  }

  Future<void> _setTheme(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode == ThemeMode.dark ? 'dark' : mode == ThemeMode.system ? 'system' : 'light');
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'График смен: Календарь и Зарплата',
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: _themeMode,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ru'), Locale('en')],
      locale: const Locale('ru'),
      home: HomeScreen(themeMode: _themeMode, onThemeChanged: _setTheme),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  const HomeScreen({super.key, required this.themeMode, required this.onThemeChanged});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  List<ShiftType> _shiftTypes = [];
  List<ShiftTemplate> _templates = [];
  final List<ShiftEntry> _shifts = [];
  List<Holiday> _holidays = [];
  Map<String, MonthRecord> _closedMonths = {};
  Map<String, List<Note>> _notes = {};

  double _globalCoefOvertime = 1.0;
  double _globalCoefUndertime = 1.0;
  bool _salaryFromStart = true;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bgColor => _isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100;
  Color get _textColor => _isDark ? const Color(0xFFE0E0E0) : Colors.black;
  Color get _subtextColor => _isDark ? const Color(0xFF9E9E9E) : Colors.grey.shade700;
  Color get _redColor => _isDark ? const Color(0xFFEF9A9A) : Colors.red;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final loadedHolidays = await loadHolidays();
    final prefs = await SharedPreferences.getInstance();

    final savedTypes = prefs.getStringList('shift_types');
    List<ShiftType> types = [];
    if (savedTypes != null) {
      for (final s in savedTypes) {
        try { types.add(ShiftType.fromJson(jsonDecode(s) as Map<String, dynamic>)); } catch (_) {}
      }
    }
    if (types.isEmpty) types = ShiftType.defaults();

    final savedTemplates = prefs.getStringList('custom_templates') ?? [];
    final customTemplates = <ShiftTemplate>[];
    for (final s in savedTemplates) {
      try { customTemplates.add(ShiftTemplate.fromJson(jsonDecode(s) as Map<String, dynamic>)); } catch (_) {}
    }

    _globalCoefOvertime = double.tryParse(prefs.getString('coef_overtime') ?? '1.0') ?? 1.0;
    _globalCoefUndertime = double.tryParse(prefs.getString('coef_undertime') ?? '1.0') ?? 1.0;
    _salaryFromStart = prefs.getString('salary_from_start') != 'false';
    final savedNotes = prefs.getStringList('notes') ?? [];
    final notesMap = <String, List<Note>>{};
    for (final s in savedNotes) {
      try {
        final n = Note.fromJson(jsonDecode(s) as Map<String, dynamic>);
        notesMap.putIfAbsent(n.date, () => []).add(n);
      } catch (_) {}
    }

    final savedShifts = prefs.getStringList('shifts') ?? [];
    final shiftsList = <ShiftEntry>[];
    for (final s in savedShifts) {
      try {
        shiftsList.add(ShiftEntry.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }

    final savedClosed = prefs.getStringList('closed_months') ?? [];
    final closed = <String, MonthRecord>{};
    for (final s in savedClosed) {
      try {
        final rec = MonthRecord.fromStorageString(s);
        closed['${rec.year}-${rec.month}'] = rec;
      } catch (_) {}
    }

    setState(() {
      _holidays = loadedHolidays;
      _shiftTypes = types;
      _templates = [...customTemplates, ...ShiftTemplate.predefined()];
      _shifts
        ..clear()
        ..addAll(shiftsList);
      _closedMonths = closed;
      _notes = notesMap;
    });

    _autoClosePastMonths();
  }

  Future<void> _autoClosePastMonths() async {
    final now = DateTime.now();
    final prevMonth = DateTime(now.year, now.month - 1, 1);
    final key = '${prevMonth.year}-${prevMonth.month}';
    if (!_closedMonths.containsKey(key)) {
      final hasShifts = _shifts.any((s) {
        final salaryDate = _salaryDateFor(s);
        return salaryDate.year == prevMonth.year && salaryDate.month == prevMonth.month;
      });
      if (hasShifts) await _closeMonth(prevMonth.year, prevMonth.month);
    }
  }

  Future<void> _saveShifts() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _shifts.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList('shifts', list);
  }

  Future<void> _saveShiftTypes() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _shiftTypes.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList('shift_types', list);
  }

  Future<void> _saveTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    final custom = _templates.where((t) => t.isCustom).toList();
    final list = custom.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList('custom_templates', list);
  }

  Future<void> _saveGlobalSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('coef_overtime', _globalCoefOvertime.toString());
    await prefs.setString('coef_undertime', _globalCoefUndertime.toString());
    await prefs.setString('salary_from_start', _salaryFromStart.toString());
  }
  Future<void> _saveNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final list = <String>[];
    for (final e in _notes.entries) {
      for (final n in e.value) {
        list.add(jsonEncode(n.toJson()));
      }
    }
    await prefs.setStringList('notes', list);
  }

  Future<void> _saveClosedMonths() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _closedMonths.values.map((r) => r.toStorageString()).toList();
    await prefs.setStringList('closed_months', list);
  }

  bool _isMonthClosed(int year, int month) => _closedMonths.containsKey('$year-$month');

  DateTime _salaryDateFor(ShiftEntry shift) {
    return _salaryFromStart ? shift.startTime : shift.endTime;
  }

  Future<void> _closeMonth(int year, int month) async {
    int workShifts = 0, sickDays = 0, vacationDays = 0;
    double totalHours = 0, overtime = 0, undertime = 0, totalAmount = 0;
    final ratesUsed = <String>{};

    for (final shift in _shifts) {
      final salaryDate = _salaryDateFor(shift);
      if (salaryDate.year != year || salaryDate.month != month) continue;

      final type = _getShiftType(shift.typeId);
      if (type == null) continue;
      if (type.id == 'sick') { sickDays++; continue; }
      if (type.id == 'vacation') { vacationDays++; continue; }
      if (!type.countInSalary) continue;

      workShifts++;
      totalHours += shift.actualHours;
      final diff = shift.actualHours - type.plannedHours;
      if (diff > 0) overtime += diff;
      if (diff < 0) undertime += -diff;
      totalAmount += _calculateAmount(shift, type);

      ratesUsed.add('${type.rateValue.toStringAsFixed(0)} ₽ ${type.rateType == RateType.perHour ? "/ч" : "/смена"}');
    }

    final record = MonthRecord(
      year: year, month: month,
      workShifts: workShifts, sickDays: sickDays, vacationDays: vacationDays,
      totalHours: totalHours, overtimeHours: overtime, undertimeHours: undertime,
      totalAmount: totalAmount, rateSnapshot: ratesUsed.join(', '), closedAt: DateTime.now(),
    );

    setState(() => _closedMonths['$year-$month'] = record);
    await _saveClosedMonths();
  }

  Future<void> _unfreezeMonth(int year, int month) async {
    setState(() => _closedMonths.remove('$year-$month'));
    await _saveClosedMonths();
  }

  int _countShiftsInMonth(int year, int month) {
    return _shifts.where((s) {
      final d = _salaryDateFor(s);
      return d.year == year && d.month == month;
    }).length;
  }

  int _countNotesInMonth(int year, int month) {
    final prefix = '$year-${month.toString().padLeft(2, '0')}';
    return _notes.entries
        .where((e) => e.key.startsWith(prefix))
        .fold<int>(0, (sum, e) => sum + e.value.length);
  }

  Future<void> _clearMonth(int year, int month, bool deleteNotes) async {
    final toRemoveShifts = _shifts.where((s) {
      final d = _salaryDateFor(s);
      return d.year == year && d.month == month;
    }).map((s) => s.id).toSet();

    setState(() {
      _shifts.removeWhere((s) => toRemoveShifts.contains(s.id));
    });
    await _saveShifts();

    if (deleteNotes) {
      final prefix = '$year-${month.toString().padLeft(2, '0')}';
      final keysToRemove = _notes.keys.where((k) => k.startsWith(prefix)).toList();
      for (final k in keysToRemove) {
        for (final n in _notes[k] ?? []) {
          for (final p in n.photoPaths) {
            try {
              final f = File(p);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          }
        }
      }
      setState(() {
        for (final k in keysToRemove) {
          _notes.remove(k);
        }
      });
      await _saveNotes();
    }
  }

  String _dateKey(DateTime day) => '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  ShiftType? _getShiftType(String id) {
    try { return _shiftTypes.firstWhere((t) => t.id == id); } catch (_) { return null; }
  }

  Holiday? _getHoliday(DateTime day) {
    final key = _dateKey(day);
    try { return _holidays.firstWhere((h) => _dateKey(h.date) == key); } catch (_) { return null; }
  }

  bool _isRedDay(DateTime day) {
    final holiday = _getHoliday(day);
    if (holiday != null) return !holiday.isWorkday;
    return day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
  }
  // Проверка пересечения смены с существующими (на этом дне и следующем)
  List<ShiftEntry> _findAllConflicts(ShiftEntry newShift) {
    final result = <ShiftEntry>[];
    for (final existing in _shifts) {
      if (existing.id == newShift.id) continue;
      final newStart = newShift.startTime;
      final newEnd = newShift.endTime;
      final exStart = existing.startTime;
      final exEnd = existing.endTime;
      if (newStart.isBefore(exEnd) && exStart.isBefore(newEnd)) {
        result.add(existing);
      }
    }
    return result;
  }

  // Показать диалог конфликта. Возвращает: 'replace' или 'cancel'
  Future<String> _showConflictDialog(List<ShiftEntry> conflicts, ShiftEntry newShift) async {
    final newType = _getShiftType(newShift.typeId);
    final newStart = '${newShift.startTime.hour.toString().padLeft(2, '0')}:${newShift.startTime.minute.toString().padLeft(2, '0')}';
    final newEnd = '${newShift.endTime.hour.toString().padLeft(2, '0')}:${newShift.endTime.minute.toString().padLeft(2, '0')}';

    final lines = conflicts.map((c) {
      final t = _getShiftType(c.typeId);
      final date = '${c.startTime.day.toString().padLeft(2, '0')}.${c.startTime.month.toString().padLeft(2, '0')}';
      final s = '${c.startTime.hour.toString().padLeft(2, '0')}:${c.startTime.minute.toString().padLeft(2, '0')}';
      final e = '${c.endTime.hour.toString().padLeft(2, '0')}:${c.endTime.minute.toString().padLeft(2, '0')}';
      return '• «${t?.name ?? "?"}» ($date, $s–$e)';
    }).join('\n');

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Конфликт'),
        content: Text(
          'Новая смена «${newType?.name ?? "?"}» ($newStart–$newEnd) пересекается с:\n$lines\n\nЗаменить все?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, 'replace'), child: const Text('Заменить')),
        ],
      ),
    );
    return result ?? 'cancel';
  }

  // Удалить смену (или группу) по shift
  void _deleteShift(ShiftEntry shift) {
    _shifts.removeWhere((s) => s.id == shift.id);
  }

  // Добавить смену с проверкой конфликта
  Future<void> _addShiftWithConflictCheck(ShiftType type, DateTime date) async {
    final newShift = _createShiftEntry(type, date);

    final conflicts = _findAllConflicts(newShift);
    if (conflicts.isNotEmpty) {
      if (!mounted) return;
      final action = await _showConflictDialog(conflicts, newShift);
      if (action == 'cancel') return;
      if (action == 'replace') {
        setState(() {
          for (final c in conflicts) {
            _deleteShift(c);
          }
        });
      }
    }

    setState(() {
      _shifts.add(newShift);
    });
    await _saveShifts();
  }

  // Создать смену (одна запись, даже если пересекает полночь)
  ShiftEntry _createShiftEntry(ShiftType type, DateTime date) {
    final start = DateTime(date.year, date.month, date.day, type.startHour, type.startMinute);
    final totalMinutes = (type.plannedHours * 60).round();
    final end = start.add(Duration(minutes: totalMinutes));
    return ShiftEntry(
      id: 'shift_${DateTime.now().microsecondsSinceEpoch}',
      typeId: type.id,
      startTime: start,
      endTime: end,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мой график'),
        actions: [
          IconButton(icon: const Icon(Icons.sticky_note_2_outlined), tooltip: 'Все заметки', onPressed: _openNotesPage),
          IconButton(icon: const Icon(Icons.bar_chart), onPressed: _openStats),
          IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: SingleChildScrollView(
            child: Column(
              children: [
                TableCalendar(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2030, 12, 31),
                  focusedDay: _focusedDay,
                  selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                  onHeaderTapped: (focusedDay) => _showCustomMonthPicker(context, focusedDay),
                  onDaySelected: (selectedDay, focusedDay) {
                    setState(() { _selectedDay = selectedDay; _focusedDay = focusedDay; });
                  },
                  calendarFormat: CalendarFormat.month,
                  availableCalendarFormats: const {CalendarFormat.month: 'Месяц'},
                  locale: 'ru_RU',
                  startingDayOfWeek: StartingDayOfWeek.monday,
                  daysOfWeekHeight: 24.0,
                  availableGestures: AvailableGestures.none,
                  calendarStyle: CalendarStyle(
                    defaultTextStyle: TextStyle(color: _textColor),
                    weekendTextStyle: TextStyle(color: _redColor),
                    outsideTextStyle: TextStyle(color: _textColor.withValues(alpha: 0.3)),
                    todayDecoration: BoxDecoration(border: Border.all(color: _textColor, width: 1), shape: BoxShape.circle),
                    selectedDecoration: BoxDecoration(border: Border.all(color: _textColor, width: 2), shape: BoxShape.circle),
                    markersMaxCount: 0,
                  ),
                  calendarBuilders: CalendarBuilders(
                    defaultBuilder: (context, day, focusedDay) => _buildDayCell(day),
                    todayBuilder: (context, day, focusedDay) => _buildDayCell(day),
                    selectedBuilder: (context, day, focusedDay) => _buildDayCell(day, isSelected: true),
                    outsideBuilder: (context, day, focusedDay) => _buildDayCell(day, isOutside: true),
                  ),
                  headerStyle: HeaderStyle(
                    formatButtonVisible: false, titleCentered: true,
                    titleTextStyle: TextStyle(color: _textColor, fontSize: 18, fontWeight: FontWeight.bold),
                    leftChevronIcon: Icon(Icons.chevron_left, color: _textColor),
                    rightChevronIcon: Icon(Icons.chevron_right, color: _textColor),
                  ),
                  daysOfWeekStyle: DaysOfWeekStyle(weekdayStyle: TextStyle(color: _subtextColor), weekendStyle: TextStyle(color: _redColor)),
                ),
                const SizedBox(height: 8),
                if (_selectedDay != null) _buildBottomPanel(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openStats() {
    Navigator.push(context, MaterialPageRoute(
      builder: (context) => StatsScreen(
        initialYear: _focusedDay.year,
        initialMonth: _focusedDay.month,
        isMonthClosed: (y, m) => _isMonthClosed(y, m),
        getClosedRecord: (y, m) => _closedMonths['$y-$m'],
        onClose: (y, m) => _closeMonth(y, m),
        onUnfreeze: (y, m) => _unfreezeMonth(y, m),
        computeStats: (y, m) => _computeStats(y, m),
        countShiftsInMonth: _countShiftsInMonth,
        countNotesInMonth: _countNotesInMonth,
        onClearMonth: _clearMonth,
      ),
    ));
  }

  Map<String, dynamic> _computeStats(int year, int month) {
    int workShifts = 0, sickDays = 0, vacationDays = 0;
    double totalHours = 0, overtime = 0, undertime = 0, totalAmount = 0;

    for (final shift in _shifts) {
      final salaryDate = _salaryDateFor(shift);
      if (salaryDate.year != year || salaryDate.month != month) continue;
      final type = _getShiftType(shift.typeId);
      if (type == null) continue;
      if (type.id == 'sick') { sickDays++; continue; }
      if (type.id == 'vacation') { vacationDays++; continue; }
      if (!type.countInSalary) continue;

      workShifts++;
      totalHours += shift.actualHours;
      final diff = shift.actualHours - type.plannedHours;
      if (diff > 0) overtime += diff;
      if (diff < 0) undertime += -diff;
      totalAmount += _calculateAmount(shift, type);
    }

    return {
      'workShifts': workShifts, 'sickDays': sickDays, 'vacationDays': vacationDays,
      'totalHours': totalHours, 'overtime': overtime, 'undertime': undertime,
      'totalAmount': totalAmount,
    };
  }
  void _openNotesPage() {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => NotesPage(
        getNotes: () => _notes,
        dateKeyOf: _dateKey,
        onEditNote: (key, existing) async => await _showNoteDialog(key, existing),
        onViewNote: (key, note) async => await _showNoteViewDialog(key, note),
        onDeleteNote: (key, note) async => await _deleteNoteDialog(key, note),
      ),
    ));
  }
  void _openSettings() {
    Navigator.push(context, MaterialPageRoute(
      builder: (context) => SettingsScreen(
        shiftTypes: _shiftTypes,
        templates: _templates,
        themeMode: widget.themeMode,
        globalCoefOvertime: _globalCoefOvertime,
        globalCoefUndertime: _globalCoefUndertime,
        salaryFromStart: _salaryFromStart,
        onThemeChanged: widget.onThemeChanged,
        onShiftTypesChanged: (newTypes) async {
          setState(() => _shiftTypes = newTypes);
          await _saveShiftTypes();
        },
        onTemplatesChanged: (newTemplates) async {
          setState(() => _templates = newTemplates);
          await _saveTemplates();
        },
        onGlobalSettingsChanged: (coefOver, coefUnder, fromStart) async {
          setState(() {
            _globalCoefOvertime = coefOver;
            _globalCoefUndertime = coefUnder;
            _salaryFromStart = fromStart;
          });
          await _saveGlobalSettings();
        },
      ),
    ));
  }
  void _openTemplatePickerForDay(DateTime day) {
    if (_templates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет доступных шаблонов')),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: _bgColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Шаблон с ${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _textColor),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: _templates.map((t) => ListTile(
                  leading: Icon(Icons.play_arrow, color: _textColor),
                  title: Text(t.name, style: TextStyle(color: _textColor)),
                  subtitle: Text(t.description, style: TextStyle(color: _subtextColor, fontSize: 12)),
                  trailing: t.isCustom
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.blue.shade100, borderRadius: BorderRadius.circular(4)),
                          child: const Text('свой', style: TextStyle(fontSize: 10)),
                        )
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showTemplateConfigForDay(t, day);
                  },
                )).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTemplateConfigForDay(ShiftTemplate template, DateTime day) {
    String? typeId = _shiftTypes.isNotEmpty ? _shiftTypes.first.id : null;
    int months = 1;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Шаблон «${template.name}»'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Дата начала'),
                  subtitle: Text('${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}'),
                ),
                const SizedBox(height: 8),
                if (!template.isCustom)
                  DropdownButtonFormField<String>(
                    value: typeId,
                    decoration: const InputDecoration(labelText: 'Тип смены для рабочих дней'),
                    items: _shiftTypes.map((t) => DropdownMenuItem(value: t.id, child: Text(t.name))).toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => typeId = value);
                    },
                  ),
                if (!template.isCustom) const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  value: months,
                  decoration: const InputDecoration(labelText: 'Период'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 месяц')),
                    DropdownMenuItem(value: 2, child: Text('2 месяца')),
                    DropdownMenuItem(value: 3, child: Text('3 месяца')),
                    DropdownMenuItem(value: 6, child: Text('6 месяцев (полгода)')),
                    DropdownMenuItem(value: 12, child: Text('12 месяцев (год)')),
                  ],
                  onChanged: (value) { if (value != null) setDialogState(() => months = value); },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            TextButton(
              onPressed: () {
                if (!template.isCustom && typeId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Выбери тип смены')),
                  );
                  return;
                }
                Navigator.pop(ctx);
                _generateFromTemplate(template, day, typeId ?? 'day', months);
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateFromTemplate(ShiftTemplate template, DateTime startDate, String typeId, int months) async {
    final endDate = DateTime(startDate.year, startDate.month + months, 0);
    final newShifts = <ShiftEntry>[];
    int overwritten = 0;

    for (int i = 0; i <= endDate.difference(startDate).inDays; i++) {
      final date = startDate.add(Duration(days: i));
      if (date.isAfter(endDate)) break;
      if (_isMonthClosed(date.year, date.month)) continue;

      final step = template.cycle[i % template.cycle.length];
      if (step == 'rest') continue;

      final effectiveTypeId = (step == 'work')
          ? (template.fixedTypeId ?? typeId)
          : step;
      final type = _getShiftType(effectiveTypeId);
      if (type == null) continue;

      final newShift = _createShiftEntry(type, date);
      if (_findAllConflicts(newShift).isNotEmpty) { overwritten++; continue; }
      newShifts.add(newShift);
    }

    if (overwritten > 0) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Конфликты'),
          content: Text('$overwritten дней уже заняты сменами. Перезаписать?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Перезаписать')),
          ],
        ),
      );
      if (ok != true) return;

      newShifts.clear();
      for (int i = 0; i <= endDate.difference(startDate).inDays; i++) {
        final date = startDate.add(Duration(days: i));
        if (date.isAfter(endDate)) break;
        if (_isMonthClosed(date.year, date.month)) continue;
        final step = template.cycle[i % template.cycle.length];
        if (step == 'rest') continue;
        final effectiveTypeId = (step == 'work')
            ? (template.fixedTypeId ?? typeId)
            : step;
        final type = _getShiftType(effectiveTypeId);
        if (type == null) continue;
        newShifts.add(_createShiftEntry(type, date));
      }
    }

    setState(() {
      for (final ns in newShifts) {
        final conflicts = _findAllConflicts(ns);
        for (final c in conflicts) {
          _shifts.removeWhere((s) => s.id == c.id);
        }
        _shifts.add(ns);
      }
    });
    await _saveShifts();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Создано ${newShifts.length} смен по шаблону «${template.name}»')),
    );
  }

  void _showCustomMonthPicker(BuildContext context, DateTime initialDate) {
    const months = ['Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек'];
    int selectedYear = initialDate.year;
    int selectedMonth = initialDate.month;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => setDialogState(() => selectedYear--)),
              Text('$selectedYear'),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => setDialogState(() => selectedYear++)),
            ],
          ),
          content: SizedBox(
            width: 300, height: 300,
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 1.5),
              itemCount: 12,
              itemBuilder: (context, index) {
                final monthNumber = index + 1;
                final isSelected = monthNumber == selectedMonth;
                return GestureDetector(
                  onTap: () {
                    setState(() { _focusedDay = DateTime(selectedYear, monthNumber, 1); _selectedDay = null; });
                    Navigator.pop(context);
                  },
                  child: Container(
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isSelected ? (_isDark ? const Color(0xFF64B5F6).withValues(alpha: 0.3) : Colors.blue.shade100) : null,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(child: Text(months[index], style: TextStyle(color: _textColor, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal))),
                  ),
                );
              },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена'))],
        ),
      ),
    );
  }

  Widget _buildDayCell(DateTime day, {bool isSelected = false, bool isOutside = false}) {
    final isRed = _isRedDay(day);
    final isToday = isSameDay(day, DateTime.now());
    final isClosed = _isMonthClosed(day.year, day.month);

    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // Смены, пересекающиеся с этим днём
    final overlapping = _shifts.where((s) =>
        s.startTime.isBefore(dayEnd) && dayStart.isBefore(s.endTime)).toList();

    // Смены, которые НАЧАЛИСЬ в этот день
    final startedHere = overlapping.where((s) =>
        s.startTime.year == day.year &&
        s.startTime.month == day.month &&
        s.startTime.day == day.day).toList();

    // Смены-продолжения (не начались здесь, но пересекают)
    final continuations = overlapping.where((s) =>
        !(s.startTime.year == day.year &&
          s.startTime.month == day.month &&
          s.startTime.day == day.day)).toList();

    Widget? background;
    if (startedHere.length == 1) {
      final type = _getShiftType(startedHere[0].typeId);
      if (type != null) {
        background = Container(decoration: BoxDecoration(color: type.color, shape: BoxShape.circle));
      }
    } else if (startedHere.length >= 2) {
      final type1 = _getShiftType(startedHere[0].typeId);
      final type2 = _getShiftType(startedHere[1].typeId);
      if (type1 != null && type2 != null) {
        background = ClipOval(
          child: Transform.rotate(
            angle: 0.785398,
            child: Row(
              children: [
                Expanded(child: Container(color: type1.color)),
                Expanded(child: Container(color: type2.color)),
              ],
            ),
          ),
        );
      }
    }

    // Точка — если есть смена-продолжение
    Widget? continuationDot;
    if (continuations.isNotEmpty) {
      final type = _getShiftType(continuations[0].typeId);
      if (type != null) {
        continuationDot = Positioned(
          bottom: 2, right: 2,
          child: Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
          ),
        );
      }
    }

    return Opacity(
      opacity: isOutside ? 0.3 : (isClosed ? 0.6 : 1.0),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: isSelected ? Border.all(color: _textColor, width: 2) : (isToday ? Border.all(color: _textColor, width: 1) : null),
        ),
        child: Stack(
          children: [
            if (background != null) Positioned.fill(child: background),
            if (continuationDot != null) continuationDot,
            Center(
              child: Text('${day.day}', style: TextStyle(
                color: startedHere.isNotEmpty ? Colors.black : (isRed ? _redColor : _textColor),
                fontWeight: isRed || startedHere.isNotEmpty || isToday || isSelected ? FontWeight.bold : FontWeight.normal,
              )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    if (_isMonthClosed(_selectedDay!.year, _selectedDay!.month)) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: _bgColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock, color: _subtextColor, size: 32),
            const SizedBox(height: 8),
            Text('Месяц закрыт. Редактирование недоступно.', style: TextStyle(color: _textColor), textAlign: TextAlign.center),
          ],
        ),
      );
    }
    final key = _dateKey(_selectedDay!);
    final dayStart = DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final shifts = _shifts.where((s) =>
        s.startTime.isBefore(dayEnd) && dayStart.isBefore(s.endTime)).toList();
    if (shifts.isEmpty) return _buildShiftPicker();
    return _buildShiftCardList(key, shifts);
  }

  Widget _buildShiftPicker() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(color: _bgColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Выбери тип смены:', style: TextStyle(fontSize: 14, color: _subtextColor)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12, runSpacing: 12,
            children: [..._shiftTypes.map((type) => _buildShiftCircle(type)), _buildAddCircle()],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => _openTemplatePickerForDay(_selectedDay!),
            icon: const Icon(Icons.playlist_add, color: Colors.blue, size: 20),
            label: const Text('Применить шаблон', style: TextStyle(color: Colors.blue)),
          ),
        ],
      ),
    );
  }

  Widget _buildShiftCircle(ShiftType type) {
    return GestureDetector(
      onTap: () async {
        await _addShiftWithConflictCheck(type, _selectedDay!);
      },
      onLongPress: () => _openSettings(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
            child: Center(child: Text(type.letter, style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold))),
          ),
          const SizedBox(height: 4),
          Text(type.name, style: TextStyle(fontSize: 10, color: _textColor)),
        ],
      ),
    );
  }

  Widget _buildAddCircle() {
    return GestureDetector(
      onTap: _openSettings,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(color: _isDark ? const Color(0xFF2C2C2C) : Colors.grey.shade300, shape: BoxShape.circle),
            child: Icon(Icons.add, color: _isDark ? const Color(0xFF9E9E9E) : Colors.black54),
          ),
          const SizedBox(height: 4),
          Text('Добавить', style: TextStyle(fontSize: 10, color: _textColor)),
        ],
      ),
    );
  }

  Widget _buildShiftCardList(String key, List<ShiftEntry> shifts) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _bgColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_selectedDay!.day}.${_selectedDay!.month.toString().padLeft(2, '0')}.${_selectedDay!.year}',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _textColor),
          ),
          const SizedBox(height: 8),
          ...shifts.asMap().entries.map((e) => _buildShiftRow(key, e.key, e.value)),
          TextButton.icon(
            onPressed: () {
              _showAddShiftDialog(key);
            },
            icon: const Icon(Icons.add, color: Colors.blue),
            label: const Text('Добавить ещё смену', style: TextStyle(color: Colors.blue)),
          ),
          const Divider(height: 24),
          _buildNotesSection(key),
        ],
      ),
    );
  }
  Widget _buildNotesSection(String key) {
    final notes = _notes[key] ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Заметки', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _textColor)),
        const SizedBox(height: 8),
        ...notes.map((n) => _buildNoteRow(key, n)),
        TextButton.icon(
          onPressed: () => _showNoteDialog(key, null),
          icon: const Icon(Icons.add, color: Colors.blue, size: 20),
          label: const Text('Добавить заметку', style: TextStyle(color: Colors.blue)),
        ),
      ],
    );
  }

Widget _buildNoteRow(String key, Note note) {
  final lines = note.text.split('\n').take(3).toList();
  final hasMore = note.text.split('\n').length > 3;
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: _isDark ? const Color(0xFF2C2C2C) : Colors.white,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onLongPress: () => _deleteNoteDialog(key, note),
        onTap: () => _showNoteViewDialog(key, note),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.title.isNotEmpty)
                Text(note.title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _textColor)),
              if (note.title.isNotEmpty) const SizedBox(height: 4),
              ...lines.map((line) => Text(line, style: TextStyle(fontSize: 14, color: _textColor))),
              if (hasMore) Text('…', style: TextStyle(fontSize: 14, color: _subtextColor)),
              if (note.photoPaths.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.photo, size: 16, color: _subtextColor),
                    const SizedBox(width: 4),
                    Text(
                      note.photoPaths.length == 1 ? 'Фото' : 'Фото (${note.photoPaths.length})',
                      style: TextStyle(fontSize: 12, color: _subtextColor),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

  Future<void> _showNoteViewDialog(String key, Note note) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: note.title.isNotEmpty
            ? Text(note.title, style: const TextStyle(fontWeight: FontWeight.bold))
            : const Text('Заметка'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (note.text.isNotEmpty)
                Text(note.text, style: TextStyle(fontSize: 14, color: _textColor)),
              if (note.photoPaths.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...note.photoPaths.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () => _showFullScreenPhoto(e.value),
                    child: Image.file(
                      File(e.value),
                      height: 200,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 60,
                        alignment: Alignment.center,
                        child: Text('Фото ${e.key + 1} недоступно',
                            style: TextStyle(fontSize: 12, color: _subtextColor)),
                      ),
                    ),
                  ),
                )),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _deleteNoteDialog(key, note);
            },
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _showNoteDialog(key, note);
            },
            child: const Text('Редактировать'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  void _showFullScreenPhoto(String path) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(8),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                child: Center(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image,
                      color: Colors.white,
                      size: 64,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4, right: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _deleteNoteDialog(String key, Note note) async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить заметку?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          TextButton(
            onPressed: () async {
              // Удаляем все файлы фото с диска (не критично, если не существует)
              for (final p in note.photoPaths) {
                try {
                  final f = File(p);
                  if (await f.exists()) await f.delete();
                } catch (_) {}
              }
              setState(() {
                _notes[key]?.removeWhere((n) => n.id == note.id);
                if (_notes[key]?.isEmpty == true) _notes.remove(key);
              });
              await _saveNotes();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _showNoteDialog(String key, Note? existing) async {
    final titleController = TextEditingController(text: existing?.title ?? '');
    final textController = TextEditingController(text: existing?.text ?? '');
    final List<String> photoPaths = List<String>.from(existing?.photoPaths ?? []);
    bool processingPhoto = false;
    int processingCurrent = 0;
    int processingTotal = 0;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> pickPhoto(ImageSource source) async {
            final picker = ImagePicker();
            final picked = await picker.pickImage(source: source);
            if (picked == null) return;

            final dir = await getApplicationDocumentsDirectory();
            final targetPath = '${dir.path}/photo_${DateTime.now().millisecondsSinceEpoch}.jpg';

            setDialogState(() => processingPhoto = true);
            try {
              final compressedBytes = await compute(_compressImageInIsolate, {
                'path': picked.path,
                'quality': 70,
              });

              if (compressedBytes != null) {
                await File(targetPath).writeAsBytes(compressedBytes);
                if (context.mounted) {
                  setDialogState(() => photoPaths.add(targetPath));
                }
              }
            } finally {
              if (context.mounted) {
                setDialogState(() => processingPhoto = false);
              }
            }
          }
          Future<void> pickMultiplePhotos() async {
            final picker = ImagePicker();
            final picked = await picker.pickMultiImage();
            if (picked.isEmpty) return;

            final toProcess = picked;

            setDialogState(() {
              processingPhoto = true;
              processingCurrent = 0;
              processingTotal = toProcess.length;
            });
            try {
              final dir = await getApplicationDocumentsDirectory();
              for (int i = 0; i < toProcess.length; i++) {
                final file = toProcess[i];
                if (!context.mounted) break;
                setDialogState(() => processingCurrent = i + 1);

                final targetPath = '${dir.path}/photo_${DateTime.now().microsecondsSinceEpoch}_$i.jpg';
                final compressedBytes = await compute(_compressImageInIsolate, {
                  'path': file.path,
                  'quality': 70,
                });
                if (compressedBytes != null) {
                  await File(targetPath).writeAsBytes(compressedBytes);
                  if (context.mounted) {
                    setDialogState(() => photoPaths.add(targetPath));
                  }
                }
              }
            } finally {
              if (context.mounted) {
                setDialogState(() {
                  processingPhoto = false;
                  processingCurrent = 0;
                  processingTotal = 0;
                });
              }
            }
          }
          Future<void> showSourcePicker() async {
            final action = await showModalBottomSheet<String>(
              context: context,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.photo_library),
                      title: const Text('Галерея'),
                      onTap: () => Navigator.pop(ctx, 'gallery'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.photo_camera),
                      title: const Text('Камера'),
                      onTap: () => Navigator.pop(ctx, 'camera'),
                    ),
                  ],
                ),
              ),
            );
            if (action == 'gallery') {
              await pickMultiplePhotos();
            } else if (action == 'camera') {
              await pickPhoto(ImageSource.camera);
            }
          }

          return AlertDialog(
            title: Text(existing == null ? 'Новая заметка' : 'Редактировать заметку'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: titleController, decoration: const InputDecoration(labelText: 'Заголовок')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: textController,
                    minLines: 3,
                    maxLines: 8,
                    maxLength: 2000,
                    decoration: const InputDecoration(labelText: 'Текст'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  if (processingPhoto)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            processingTotal > 1
                                ? 'Обработка фото $processingCurrent/$processingTotal'
                                : 'Обработка фото…',
                            style: TextStyle(fontSize: 13, color: _subtextColor),
                          ),
                        ],
                      ),
                    ),
                  if (photoPaths.isNotEmpty)
                    SizedBox(
                      height: 100,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: photoPaths.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (ctx, i) => Stack(
                          alignment: Alignment.topRight,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(photoPaths[i]),
                                width: 100, height: 100, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 100, height: 100,
                                  color: Colors.grey.shade400,
                                  child: const Icon(Icons.broken_image, color: Colors.white),
                                ),
                              ),
                            ),
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(Icons.close, color: Colors.red, size: 18),
                              onPressed: () => setDialogState(() => photoPaths.removeAt(i)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (!processingPhoto)
                    TextButton.icon(
                      onPressed: showSourcePicker,
                      icon: const Icon(Icons.add_a_photo, size: 18),
                      label: Text(photoPaths.isEmpty ? 'Добавить фото' : 'Добавить ещё'),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
              TextButton(
                onPressed: (processingPhoto || (textController.text.trim().isEmpty && photoPaths.isEmpty))
                    ? null
                    : () async {
                  final text = textController.text.trim();

                  // Удаляем с диска фото, которые были в заметке, но убраны пользователем
                  if (existing != null) {
                    for (final oldPath in existing.photoPaths) {
                      if (!photoPaths.contains(oldPath)) {
                        try {
                          final f = File(oldPath);
                          if (await f.exists()) await f.delete();
                        } catch (_) {}
                      }
                    }
                  }

                  setState(() {
                    final list = _notes[key] ?? [];
                    if (existing == null) {
                      list.add(Note(
                        id: 'note_${DateTime.now().millisecondsSinceEpoch}',
                        date: key,
                        title: titleController.text.trim(),
                        text: text,
                        photoPaths: List<String>.from(photoPaths),
                        photoComment: null,
                        createdAt: DateTime.now(),
                      ));
                    } else {
                      final i = list.indexWhere((n) => n.id == existing.id);
                      if (i >= 0) {
                        list[i] = Note(
                          id: existing.id,
                          date: existing.date,
                          title: titleController.text.trim(),
                          text: text,
                          photoPaths: List<String>.from(photoPaths),
                          photoComment: null,
                          createdAt: existing.createdAt,
                        );
                      }
                    }
                    _notes[key] = list;
                  });
                  await _saveNotes();
                  if (mounted) Navigator.pop(context);
                },
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAddShiftDialog(String key) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Добавить смену'),
        children: [
          ..._shiftTypes.map((type) {
            return SimpleDialogOption(
              onPressed: () async {
                Navigator.pop(context);
                await _addShiftWithConflictCheck(type, _selectedDay!);
              },
              child: Row(
                children: [
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
                    child: Center(child: Text(type.letter, style: const TextStyle(fontWeight: FontWeight.bold))),
                  ),
                  const SizedBox(width: 12),
                  Text(type.name),
                ],
              ),
            );
          }),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(context);
              _openTemplatePickerForDay(_selectedDay!);
            },
            child: Row(
              children: const [
                Icon(Icons.playlist_add, color: Colors.blue),
                SizedBox(width: 12),
                Text('Применить шаблон', style: TextStyle(color: Colors.blue)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShiftRow(String key, int index, ShiftEntry shift) {
    final type = _getShiftType(shift.typeId);
    final amount = _calculateAmount(shift, type);
    final salaryDate = _salaryDateFor(shift);
    final selected = _selectedDay!;
    final isSalaryRecord = salaryDate.year == selected.year &&
        salaryDate.month == selected.month &&
        salaryDate.day == selected.day;
    final startStr = '${shift.startTime.hour.toString().padLeft(2, '0')}:${shift.startTime.minute.toString().padLeft(2, '0')}';
    final endStr = '${shift.endTime.hour.toString().padLeft(2, '0')}:${shift.endTime.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _isDark ? const Color(0xFF2C2C2C) : Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (type != null)
                Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
                  child: Center(child: Text(type.letter, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                ),
              const SizedBox(width: 8),
              Expanded(child: Text(
                () {
                  final startedToday = shift.startTime.year == selected.year &&
                      shift.startTime.month == selected.month &&
                      shift.startTime.day == selected.day;
                  final suffix = startedToday
                      ? ''
                      : ' (с ${shift.startTime.day.toString().padLeft(2, '0')}.${shift.startTime.month.toString().padLeft(2, '0')})';
                  return '${type?.name ?? '?'}$suffix';
                }(),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _textColor),
              )),
              IconButton(
                icon: Icon(Icons.more_vert, color: _textColor, size: 20),
                onPressed: () => _showShiftMenu(key, index, shift),
              ),
            ],
          ),
          Row(
            children: [
              GestureDetector(
                onTap: () async {
                  final picked = await _pickTime(shift.startTime);
                  if (picked == null) return;
                  final oldStart = shift.startTime;
                  final oldEnd = shift.endTime;
                  final oldDuration = shift.actualHours;
                  shift.startTime = picked;
                  if (!shift.endTime.isAfter(shift.startTime)) {
                    shift.endTime = shift.startTime.add(const Duration(hours: 1));
                  }
                  await _maybeAskDateFix(shift, oldDuration, true);
                  final conflicts = _findAllConflicts(shift);
                  if (conflicts.isNotEmpty) {
                    if (!mounted) return;
                    final action = await _showConflictDialog(conflicts, shift);
                    if (action == 'cancel') {
                      shift.startTime = oldStart;
                      shift.endTime = oldEnd;
                      setState(() {});
                      return;
                    }
                    setState(() {
                      for (final c in conflicts) {
                        _shifts.removeWhere((s) => s.id == c.id);
                      }
                    });
                  }
                  setState(() {});
                  await _saveShifts();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(startStr, style: TextStyle(fontSize: 16, color: _textColor)),
                ),
              ),
              const Text(' – ', style: TextStyle(fontSize: 16)),
              GestureDetector(
                onTap: () async {
                  final picked = await _pickTime(shift.endTime);
                  if (picked == null) return;
                  final oldEnd = shift.endTime;
                  final oldDuration = shift.actualHours;
                  var newEnd = picked;
                  if (!newEnd.isAfter(shift.startTime)) {
                    newEnd = newEnd.add(const Duration(days: 1));
                  }
                  shift.endTime = newEnd;
                  await _maybeAskDateFix(shift, oldDuration, false);
                  final conflicts = _findAllConflicts(shift);
                  if (conflicts.isNotEmpty) {
                    if (!mounted) return;
                    final action = await _showConflictDialog(conflicts, shift);
                    if (action == 'cancel') {
                      shift.endTime = oldEnd;
                      setState(() {});
                      return;
                    }
                    setState(() {
                      for (final c in conflicts) {
                        _shifts.removeWhere((s) => s.id == c.id);
                      }
                    });
                  }
                  setState(() {});
                  await _saveShifts();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(endStr, style: TextStyle(fontSize: 16, color: _textColor)),
                ),
              ),
              const SizedBox(width: 12),
              Text('${shift.actualHours.toStringAsFixed(1)} ч', style: TextStyle(fontSize: 14, color: _subtextColor)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isSalaryRecord ? 'Сумма: ${amount.toStringAsFixed(2)} ₽' : 'Сумма: (на ${_salaryFromStart ? "день начала" : "день конца"})',
            style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.bold,
              color: _isDark ? const Color(0xFF64B5F6) : Colors.blue,
            ),
          ),
        ],
      ),
    );
  }

  Future<DateTime?> _pickTime(DateTime initial) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (picked == null) return null;
    return DateTime(initial.year, initial.month, initial.day, picked.hour, picked.minute);
  }

  /// Если после изменения времени смена раздулась больше чем в 2 раза,
  /// даты разные, и время «перевернулось» (start < end по времени суток) —
  /// спросить, не ошибка ли это даты. Возвращает true, если пользователь
  /// согласился поменять дату (и дата уже поменяна).
  Future<void> _maybeAskDateFix(ShiftEntry shift, double oldDuration, bool isStart) async {
    final newDuration = shift.actualHours;
    if (newDuration <= oldDuration * 2) return;
    if (shift.startTime.year == shift.endTime.year &&
        shift.startTime.month == shift.endTime.month &&
        shift.startTime.day == shift.endTime.day) return;
    final startTod = shift.startTime.hour * 60 + shift.startTime.minute;
    final endTod = shift.endTime.hour * 60 + shift.endTime.minute;
    if (startTod >= endTod) return;

    final dateStr = isStart
        ? '${shift.endTime.day.toString().padLeft(2, '0')}.${shift.endTime.month.toString().padLeft(2, '0')}'
        : '${shift.startTime.day.toString().padLeft(2, '0')}.${shift.startTime.month.toString().padLeft(2, '0')}';
    final title = isStart ? 'Поменять дату начала?' : 'Поменять дату конца?';
    final body = '${newDuration.toStringAsFixed(1)} ч. '
        '${isStart ? "Дата начала" : "Дата конца"} — $dateStr?';

    if (!mounted) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Нет')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Да')),
        ],
      ),
    );
    if (result != true) return;

    if (isStart) {
      final timeOfDay = TimeOfDay.fromDateTime(shift.startTime);
      shift.startTime = DateTime(
        shift.endTime.year, shift.endTime.month, shift.endTime.day,
        timeOfDay.hour, timeOfDay.minute,
      );
    } else {
      final timeOfDay = TimeOfDay.fromDateTime(shift.endTime);
      shift.endTime = DateTime(
        shift.startTime.year, shift.startTime.month, shift.startTime.day,
        timeOfDay.hour, timeOfDay.minute,
      );
    }
  }

  void _showShiftMenu(String key, int index, ShiftEntry shift) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _bgColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.tune, color: _textColor),
              title: Text('Настройки', style: TextStyle(color: _textColor)),
              onTap: () { Navigator.pop(context); _showShiftSettings(key, index, shift); },
            ),
            ListTile(
              leading: Icon(Icons.edit_calendar, color: _textColor),
              title: Text('Перенести', style: TextStyle(color: _textColor)),
              onTap: () { Navigator.pop(context); _moveShiftToDate(shift); },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: _redColor),
              title: Text('Удалить', style: TextStyle(color: _redColor)),
              onTap: () async {
                setState(() {
                  _shifts.removeWhere((s) => s.id == shift.id);
                });
                await _saveShifts();
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
  Future<void> _moveShiftToDate(ShiftEntry shift) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: shift.startTime,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: 'Новая дата начала',
    );
    if (picked == null) return;
    final oldStart = shift.startTime;
    final oldEnd = shift.endTime;
    final diffDays = DateTime(picked.year, picked.month, picked.day)
        .difference(DateTime(oldStart.year, oldStart.month, oldStart.day))
        .inDays;
    if (diffDays == 0) return;
    shift.startTime = oldStart.add(Duration(days: diffDays));
    shift.endTime = oldEnd.add(Duration(days: diffDays));
    final conflicts = _findAllConflicts(shift);
    if (conflicts.isNotEmpty) {
      if (!mounted) return;
      final action = await _showConflictDialog(conflicts, shift);
      if (action == 'cancel') {
        shift.startTime = oldStart;
        shift.endTime = oldEnd;
        setState(() {});
        return;
      }
      setState(() {
        for (final c in conflicts) {
          _shifts.removeWhere((s) => s.id == c.id);
        }
      });
    }
    setState(() {});
    await _saveShifts();
  }
  void _showShiftSettings(String key, int index, ShiftEntry shift) {
    final type = _getShiftType(shift.typeId);
    if (type == null) return;

    final rateController = TextEditingController(text: (shift.overrideRateValue ?? type.rateValue).toStringAsFixed(0));
    final coefOverController = TextEditingController(text: (shift.overrideCoefOvertime ?? type.coefOvertime).toString());
    final coefUnderController = TextEditingController(text: (shift.overrideCoefUndertime ?? type.coefUndertime).toString());
    final breakController = TextEditingController(text: shift.breakMinutes.toString());
    RateType selectedType = shift.overrideRateType ?? type.rateType;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Настройки смены'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: rateController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Ставка')),
                const SizedBox(height: 8),
                DropdownButtonFormField<RateType>(
                  value: selectedType,
                  decoration: const InputDecoration(labelText: 'Тип расчёта'),
                  items: RateType.values.map((t) => DropdownMenuItem(value: t, child: Text(t == RateType.perHour ? 'за час' : 'за смену'))).toList(),
                  onChanged: (value) { if (value != null) setDialogState(() => selectedType = value); },
                ),
                const SizedBox(height: 8),
                TextField(controller: coefOverController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Коэфф. переработки')),
                const SizedBox(height: 8),
                TextField(controller: coefUnderController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Коэфф. недоработки')),
                const SizedBox(height: 8),
                TextField(controller: breakController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Перерыв (мин)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () async {
                setState(() {
                  shift.overrideRateValue = double.tryParse(rateController.text.trim());
                  shift.overrideRateType = selectedType;
                  shift.overrideCoefOvertime = double.tryParse(coefOverController.text.trim());
                  shift.overrideCoefUndertime = double.tryParse(coefUnderController.text.trim());
                  shift.breakMinutes = int.tryParse(breakController.text.trim()) ?? 0;
                });
                await _saveShifts();
                Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  double _calculateAmount(ShiftEntry shift, ShiftType? type) {
    if (type == null || !type.countInSalary) return 0;
    final rateValue = shift.overrideRateValue ?? type.rateValue;
    final rateType = shift.overrideRateType ?? type.rateType;
    final coefOver = shift.overrideCoefOvertime ?? type.coefOvertime;
    final coefUnder = shift.overrideCoefUndertime ?? type.coefUndertime;

    if (rateType == RateType.perHour) return shift.actualHours * rateValue;
    if (type.plannedHours <= 0) return rateValue;
    final hourCost = rateValue / type.plannedHours;
    final diff = shift.actualHours - type.plannedHours;
    if (diff > 0) return rateValue + diff * hourCost * coefOver;
    if (diff < 0) return rateValue - (-diff) * hourCost * coefUnder;
    return rateValue;
  }
}
class NotesPage extends StatefulWidget {
  final Map<String, List<Note>> Function() getNotes;
  final Future<void> Function(String dateKey, Note? existing) onEditNote;
  final Future<void> Function(String dateKey, Note note) onViewNote;
  final Future<void> Function(String dateKey, Note note) onDeleteNote;
  final String Function(DateTime) dateKeyOf;

  const NotesPage({
    super.key,
    required this.getNotes,
    required this.onEditNote,
    required this.onViewNote,
    required this.onDeleteNote,
    required this.dateKeyOf,
  });

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String _query = '';
  String? _rangeStart;
  String? _rangeEnd;
  final TextEditingController _searchController = TextEditingController();

  List<String> _filteredDates() {
    final q = _query.trim().toLowerCase();
    final dates = <String>[];
    widget.getNotes().forEach((dateKey, list) {
      if (_rangeStart != null && dateKey.compareTo(_rangeStart!) < 0) return;
      if (_rangeEnd != null && dateKey.compareTo(_rangeEnd!) > 0) return;
      if (q.isNotEmpty) {
        final matches = list.any((n) =>
            n.title.toLowerCase().contains(q) || n.text.toLowerCase().contains(q));
        if (!matches) return;
      }
      dates.add(dateKey);
    });
    dates.sort((a, b) => b.compareTo(a));
    return dates;
  }

  List<Note> _notesForDate(String dateKey) {
    final q = _query.trim().toLowerCase();
    final all = widget.getNotes()[dateKey] ?? [];
    final filtered = q.isEmpty
        ? all
        : all.where((n) =>
            n.title.toLowerCase().contains(q) || n.text.toLowerCase().contains(q)).toList();
    filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return filtered;
  }

  String _formatDate(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    final d = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    const months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
    const weekdays = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
    return '${d.day} ${months[d.month - 1]} ${d.year}, ${weekdays[d.weekday - 1]}';
  }

  Future<void> _pickDateAndAdd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked == null) return;
    final key = widget.dateKeyOf(picked);
    await widget.onEditNote(key, null);
    if (mounted) setState(() {});
  }

  Future<void> _onDelete(String key, Note note) async {
    await widget.onDeleteNote(key, note);
    if (mounted) setState(() {});
  }

  Future<void> _onView(String key, Note note) async {
    await widget.onViewNote(key, note);
    if (mounted) setState(() {});
  }

  Future<void> _pickDateRange() async {
    final initialStart = _rangeStart != null ? _parseDateKey(_rangeStart!) : null;
    final initialEnd = _rangeEnd != null ? _parseDateKey(_rangeEnd!) : null;
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      initialDateRange: (initialStart != null && initialEnd != null)
          ? DateTimeRange(start: initialStart, end: initialEnd)
          : null,
      helpText: 'Выберите диапазон дат',
      saveText: 'Применить',
    );
    if (range == null) return;
    setState(() {
      _rangeStart = widget.dateKeyOf(range.start);
      _rangeEnd = widget.dateKeyOf(range.end);
    });
  }

  DateTime _parseDateKey(String key) {
    final parts = key.split('-');
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? const Color(0xFFE0E0E0) : Colors.black;
    final subtextColor = isDark ? const Color(0xFF9E9E9E) : Colors.grey.shade700;
    final dates = _filteredDates();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Все заметки'),
        actions: [
          if (_rangeStart != null || _rangeEnd != null)
            IconButton(
              icon: const Icon(Icons.filter_alt_off, color: Colors.red),
              tooltip: 'Сбросить фильтр дат',
              onPressed: () => setState(() {
                _rangeStart = null;
                _rangeEnd = null;
              }),
            ),
          IconButton(
            icon: Icon(
              Icons.date_range,
              color: (_rangeStart != null || _rangeEnd != null) ? Colors.blue : null,
            ),
            tooltip: 'Фильтр по датам',
            onPressed: _pickDateRange,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Добавить заметку на дату',
            onPressed: _pickDateAndAdd,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: textColor),
              decoration: InputDecoration(
                hintText: 'Поиск по заголовку и тексту',
                hintStyle: TextStyle(color: subtextColor),
                prefixIcon: Icon(Icons.search, color: subtextColor),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.clear, color: subtextColor),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      body: dates.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  (_query.isEmpty && _rangeStart == null && _rangeEnd == null)
                      ? 'Заметок пока нет'
                      : 'Ничего не найдено',
                  style: TextStyle(color: subtextColor, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: dates.length,
              itemBuilder: (context, index) {
                final dateKey = dates[index];
                final dayNotes = _notesForDate(dateKey);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                      child: Text(
                        _formatDate(dateKey),
                        style: TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    ...dayNotes.map((note) => Card(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                          child: ListTile(
                            title: Text(
                              note.title.isNotEmpty
                                  ? note.title
                                  : (note.text.isNotEmpty ? note.text.split('\n').first : '(без текста)'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (note.text.isNotEmpty)
                                  Text(
                                    note.text,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: textColor, fontSize: 13),
                                  ),
                                if (note.photoPaths.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Row(
                                      children: [
                                        Icon(Icons.photo, size: 14, color: subtextColor),
                                        const SizedBox(width: 4),
                                        Text(
                                          note.photoPaths.length == 1 ? 'Фото' : 'Фото (${note.photoPaths.length})',
                                          style: TextStyle(color: subtextColor, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.red),
                              onPressed: () => _onDelete(dateKey, note),
                            ),
                            onTap: () => _onView(dateKey, note),
                          ),
                        )),
                  ],
                );
              },
            ),
    );
  }
}
class StatsScreen extends StatefulWidget {
  final int initialYear;
  final int initialMonth;
  final bool Function(int year, int month) isMonthClosed;
  final MonthRecord? Function(int year, int month) getClosedRecord;
  final Future<void> Function(int year, int month) onClose;
  final Future<void> Function(int year, int month) onUnfreeze;
  final Map<String, dynamic> Function(int year, int month) computeStats;
  final int Function(int year, int month) countShiftsInMonth;
  final int Function(int year, int month) countNotesInMonth;
  final Future<void> Function(int year, int month, bool deleteNotes) onClearMonth;

  const StatsScreen({
    super.key,
    required this.initialYear, required this.initialMonth,
    required this.isMonthClosed, required this.getClosedRecord,
    required this.onClose, required this.onUnfreeze, required this.computeStats,
    required this.countShiftsInMonth, required this.countNotesInMonth,
    required this.onClearMonth,
  });

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late int _year;
  late int _month;
  bool _isDark = false;

  static const _monthNames = [
    'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь',
    'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'
  ];

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear;
    _month = widget.initialMonth;
  }

  void _prevMonth() {
    setState(() {
      if (_month == 1) { _month = 12; _year--; } else { _month--; }
    });
  }

  void _nextMonth() {
    setState(() {
      if (_month == 12) { _month = 1; _year++; } else { _month++; }
    });
  }

  Future<void> _openClearMonthDialog() async {
    final shiftsCount = widget.countShiftsInMonth(_year, _month);
    final notesCount = widget.countNotesInMonth(_year, _month);

    if (shiftsCount == 0 && notesCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет данных за месяц')),
      );
      return;
    }

    bool deleteNotes = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Очистить ${_monthNames[_month - 1]} $_year?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Будет удалено: $shiftsCount смен.'),
              if (notesCount > 0) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Удалить также заметки ($notesCount)'),
                  value: deleteNotes,
                  onChanged: (v) => setDialogState(() => deleteNotes = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Очистить', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    await widget.onClearMonth(_year, _month, deleteNotes);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    _isDark = Theme.of(context).brightness == Brightness.dark;
    final isClosed = widget.isMonthClosed(_year, _month);
    final closedRecord = widget.getClosedRecord(_year, _month);
    final stats = isClosed && closedRecord != null
        ? {
            'workShifts': closedRecord.workShifts,
            'sickDays': closedRecord.sickDays,
            'vacationDays': closedRecord.vacationDays,
            'totalHours': closedRecord.totalHours,
            'overtime': closedRecord.overtimeHours,
            'undertime': closedRecord.undertimeHours,
            'totalAmount': closedRecord.totalAmount,
          }
        : widget.computeStats(_year, _month);

    return Scaffold(
      appBar: AppBar(title: const Text('Статистика')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: _prevMonth),
              Text('${_monthNames[_month - 1]} $_year', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: _nextMonth),
            ],
          ),
          const SizedBox(height: 12),
          if (isClosed && closedRecord != null)
            Card(
              color: _isDark ? const Color(0xFF2C3E50) : Colors.blue.shade50,
              child: ListTile(
                leading: const Icon(Icons.lock),
                title: const Text('Месяц закрыт'),
                subtitle: Text('Закрыт: ${closedRecord.closedAt.toString().substring(0, 16)}'),
              ),
            ),
          const SizedBox(height: 12),
          _buildStatRow('Рабочих смен', '${stats['workShifts']}'),
          _buildStatRow('Часов', '${(stats['totalHours'] as double).toStringAsFixed(1)}'),
          _buildStatRow('Переработка', '${(stats['overtime'] as double).toStringAsFixed(1)} ч'),
          _buildStatRow('Недоработка', '${(stats['undertime'] as double).toStringAsFixed(1)} ч'),
          _buildStatRow('Больничных', '${stats['sickDays']}'),
          _buildStatRow('Отпуск', '${stats['vacationDays']}'),
          const Divider(height: 32),
          _buildStatRow('Сумма', '${(stats['totalAmount'] as double).toStringAsFixed(2)} ₽', isTotal: true),
          const SizedBox(height: 24),
          if (!isClosed) ...[
            ElevatedButton.icon(
              onPressed: () async { await widget.onClose(_year, _month); setState(() {}); },
              icon: const Icon(Icons.lock),
              label: const Text('Закрыть месяц'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _openClearMonthDialog,
              icon: const Icon(Icons.delete_sweep, color: Colors.red),
              label: const Text('Очистить месяц', style: TextStyle(color: Colors.red)),
            ),
          ] else
            OutlinedButton.icon(
              onPressed: () async { await widget.onUnfreeze(_year, _month); setState(() {}); },
              icon: const Icon(Icons.lock_open),
              label: const Text('Разморозить месяц'),
            ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: isTotal ? 18 : 15, fontWeight: isTotal ? FontWeight.bold : FontWeight.normal)),
          Text(value, style: TextStyle(
            fontSize: isTotal ? 22 : 16,
            fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
            color: isTotal ? (_isDark ? const Color(0xFF64B5F6) : Colors.blue) : null,
          )),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final List<ShiftType> shiftTypes;
  final List<ShiftTemplate> templates;
  final ThemeMode themeMode;
  final double globalCoefOvertime;
  final double globalCoefUndertime;
  final bool salaryFromStart;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<List<ShiftType>> onShiftTypesChanged;
  final ValueChanged<List<ShiftTemplate>> onTemplatesChanged;
  final Function(double, double, bool) onGlobalSettingsChanged;

  const SettingsScreen({
    super.key,
    required this.shiftTypes, required this.templates, required this.themeMode,
    required this.globalCoefOvertime, required this.globalCoefUndertime,
    required this.salaryFromStart,
    required this.onThemeChanged, required this.onShiftTypesChanged, required this.onTemplatesChanged,
    required this.onGlobalSettingsChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late List<ShiftType> _shiftTypes;
  late List<ShiftTemplate> _templates;
  late double _coefOver;
  late double _coefUnder;
  late bool _salaryFromStart;

  @override
  void initState() {
    super.initState();
    _shiftTypes = List.from(widget.shiftTypes);
    _templates = List.from(widget.templates);
    _coefOver = widget.globalCoefOvertime;
    _coefUnder = widget.globalCoefUndertime;
    _salaryFromStart = widget.salaryFromStart;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ExpansionTile(
              title: const Text('Тема'),
              subtitle: Text(_themeLabel(widget.themeMode)),
              children: [
                _buildThemeTile('Светлая', ThemeMode.light),
                _buildThemeTile('Тёмная', ThemeMode.dark),
                _buildThemeTile('Системная', ThemeMode.system),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              title: const Text('Типы смен'),
              children: [
                ..._shiftTypes.map((t) => _buildShiftTypeTile(t)),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ElevatedButton.icon(onPressed: _addShiftType, icon: const Icon(Icons.add), label: const Text('Добавить тип смены')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              title: const Text('Шаблоны смен'),
              children: [
                ..._templates.map((t) => _buildTemplateTile(t)),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ElevatedButton.icon(onPressed: _createCustomTemplate, icon: const Icon(Icons.add), label: const Text('Создать свой шаблон')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              title: const Text('Коэффициенты (глобальные)'),
              subtitle: Text('Переработка ${_coefOver.toStringAsFixed(2)}, недоработка ${_coefUnder.toStringAsFixed(2)}'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      _buildNumberField('Переработка', _coefOver, (v) { setState(() => _coefOver = v); widget.onGlobalSettingsChanged(_coefOver, _coefUnder, _salaryFromStart); }),
                      _buildNumberField('Недоработка', _coefUnder, (v) { setState(() => _coefUnder = v); widget.onGlobalSettingsChanged(_coefOver, _coefUnder, _salaryFromStart); }),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ExpansionTile(
              title: const Text('Зарплата'),
              subtitle: Text(_salaryFromStart ? 'От начала смены' : 'От конца смены'),
              children: [
                SwitchListTile(
                  title: const Text('Считать от начала смены'),
                  subtitle: const Text('Если выключено — от конца смены'),
                  value: _salaryFromStart,
                  onChanged: (v) {
                    setState(() => _salaryFromStart = v);
                    widget.onGlobalSettingsChanged(_coefOver, _coefUnder, _salaryFromStart);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _themeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'Светлая';
      case ThemeMode.dark:
        return 'Тёмная';
      case ThemeMode.system:
        return 'Системная';
    }
  }

  Widget _buildThemeTile(String label, ThemeMode mode) {
    final isSelected = widget.themeMode == mode;
    return Card(
      child: ListTile(
        title: Text(label),
        leading: Icon(isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: isSelected ? Theme.of(context).colorScheme.primary : null),
        onTap: () { widget.onThemeChanged(mode); Navigator.pop(context); },
      ),
    );
  }

  Widget _buildShiftTypeTile(ShiftType type) {
    final startStr = '${type.startHour.toString().padLeft(2, '0')}:${type.startMinute.toString().padLeft(2, '0')}';
    return Card(
      child: ListTile(
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
          child: Center(child: Text(type.letter, style: const TextStyle(fontWeight: FontWeight.bold))),
        ),
        title: Text(type.name),
        subtitle: Text('$startStr • ${type.plannedHours} ч • ${type.rateValue.toStringAsFixed(0)} ₽ ${type.rateType == RateType.perHour ? "/ч" : "/смена"}'),
        trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _editShiftType(type)),
      ),
    );
  }

  Widget _buildTemplateTile(ShiftTemplate template) {
    return Card(
      child: ListTile(
        title: Row(
          children: [
            Expanded(child: Text(template.name)),
            if (template.isCustom)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.blue.shade100, borderRadius: BorderRadius.circular(4)),
                child: const Text('свой', style: TextStyle(fontSize: 10)),
              ),
          ],
        ),
        subtitle: Text('${template.description} • приоритет ${template.priority}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (template.isCustom)
              IconButton(icon: const Icon(Icons.edit), onPressed: () => _editCustomTemplate(template)),
            if (template.isCustom)
              IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _deleteTemplate(template)),
          ],
        ),
      ),
    );
  }

  void _deleteTemplate(ShiftTemplate template) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить шаблон?'),
        content: Text('Шаблон «${template.name}» будет удалён.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          TextButton(
            onPressed: () {
              setState(() => _templates.removeWhere((t) => t.id == template.id));
              widget.onTemplatesChanged(_templates);
              Navigator.pop(context);
            },
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildNumberField(String label, double value, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        initialValue: value.toString(),
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onChanged: (v) { final parsed = double.tryParse(v); if (parsed != null) onChanged(parsed); },
      ),
    );
  }

  void _addShiftType() => _showShiftTypeDialog(null);
  void _editShiftType(ShiftType type) => _showShiftTypeDialog(type);
  void _editCustomTemplate(ShiftTemplate template) {
    final nameController = TextEditingController(text: template.name);
    final steps = List<String>.from(template.cycle);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Редактировать шаблон'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Название')),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8, runSpacing: 8,
                  children: [
                    ...steps.asMap().entries.map((e) {
                      final step = e.value;
                      final isRest = step == 'rest';
                      final type = isRest ? null : _shiftTypes.firstWhere(
                        (t) => t.id == step,
                        orElse: () => _shiftTypes.first,
                      );
                      return GestureDetector(
                        onLongPress: () => setDialogState(() => steps.removeAt(e.key)),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 48, height: 48,
                              decoration: BoxDecoration(
                                color: isRest ? Colors.grey.shade400 : (type?.color ?? Colors.grey),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  isRest ? '—' : (type?.letter ?? '?'),
                                  style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isRest ? 'Отдых' : (type?.name ?? '?'),
                              style: const TextStyle(fontSize: 10),
                            ),
                          ],
                        ),
                      );
                    }),
                    GestureDetector(
                      onTap: () async {
                        final picked = await showDialog<String>(
                          context: context,
                          builder: (context) => SimpleDialog(
                            title: const Text('Выбери шаг'),
                            children: [
                              SimpleDialogOption(
                                onPressed: () => Navigator.pop(context, 'rest'),
                                child: const Text('Отдых'),
                              ),
                              ..._shiftTypes.map((t) => SimpleDialogOption(
                                onPressed: () => Navigator.pop(context, t.id),
                                child: Text(t.name),
                              )),
                            ],
                          ),
                        );
                        if (picked != null) setDialogState(() => steps.add(picked));
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 48, height: 48,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.add, color: Colors.black54),
                          ),
                          const SizedBox(height: 4),
                          const Text('Шаг', style: TextStyle(fontSize: 10)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty || steps.isEmpty) return;
                final updated = ShiftTemplate(
                  id: template.id,
                  name: name,
                  cycle: steps,
                  description: template.description,
                  priority: template.priority,
                  isCustom: true,
                );
                setState(() {
                  final i = _templates.indexWhere((t) => t.id == template.id);
                  if (i >= 0) _templates[i] = updated;
                });
                widget.onTemplatesChanged(_templates);
                Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  void _createCustomTemplate() {
    final nameController = TextEditingController();
    final steps = <String>[];

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Свой шаблон'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Название')),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8, runSpacing: 8,
                  children: [
                    ...steps.asMap().entries.map((e) {
                      final step = e.value;
                      final isRest = step == 'rest';
                      final type = isRest ? null : _shiftTypes.firstWhere(
                        (t) => t.id == step,
                        orElse: () => _shiftTypes.first,
                      );
                      return GestureDetector(
                        onLongPress: () => setDialogState(() => steps.removeAt(e.key)),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 48, height: 48,
                              decoration: BoxDecoration(
                                color: isRest ? Colors.grey.shade400 : (type?.color ?? Colors.grey),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  isRest ? '—' : (type?.letter ?? '?'),
                                  style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isRest ? 'Отдых' : (type?.name ?? '?'),
                              style: const TextStyle(fontSize: 10),
                            ),
                          ],
                        ),
                      );
                    }),
                    GestureDetector(
                      onTap: () async {
                        final picked = await showDialog<String>(
                          context: context,
                          builder: (context) => SimpleDialog(
                            title: const Text('Выбери шаг'),
                            children: [
                              SimpleDialogOption(
                                onPressed: () => Navigator.pop(context, 'rest'),
                                child: const Text('Отдых'),
                              ),
                              ..._shiftTypes.map((t) => SimpleDialogOption(
                                onPressed: () => Navigator.pop(context, t.id),
                                child: Text(t.name),
                              )),
                            ],
                          ),
                        );
                        if (picked != null) setDialogState(() => steps.add(picked));
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 48, height: 48,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade300,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.add, color: Colors.black54),
                          ),
                          const SizedBox(height: 4),
                          const Text('Шаг', style: TextStyle(fontSize: 10)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty || steps.isEmpty) return;
                final maxPriority = _templates.fold<int>(0, (p, t) => t.priority > p ? t.priority : p);
                final newTemplate = ShiftTemplate(
                  id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                  name: name,
                  cycle: steps,
                  description: 'Свой шаблон',
                  priority: maxPriority + 1,
                  isCustom: true,
                );
                setState(() => _templates.add(newTemplate));
                widget.onTemplatesChanged(_templates);
                Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  void _showShiftTypeDialog(ShiftType? existing) {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final letterController = TextEditingController(text: existing?.letter ?? '');
    final hoursController = TextEditingController(text: (existing?.plannedHours ?? 8).toStringAsFixed(0));
    final rateController = TextEditingController(text: (existing?.rateValue ?? 0).toStringAsFixed(0));
    final coefOverController = TextEditingController(text: (existing?.coefOvertime ?? 1.0).toString());
    final coefUnderController = TextEditingController(text: (existing?.coefUndertime ?? 1.0).toString());
    RateType selectedRateType = existing?.rateType ?? RateType.perHour;
    bool countInSalary = existing?.countInSalary ?? true;
    Color selectedColor = existing?.color ?? const Color(0xFF90CAF9);
    int startHour = existing?.startHour ?? 8;
    int startMinute = existing?.startMinute ?? 0;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Новый тип смены' : 'Редактировать тип'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Название')),
                const SizedBox(height: 8),
                TextField(controller: letterController, maxLength: 1, decoration: const InputDecoration(labelText: 'Буква')),
                TextField(controller: hoursController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Плановые часы')),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Время начала'),
                  subtitle: Text('${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}'),
                  trailing: const Icon(Icons.access_time),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(hour: startHour, minute: startMinute),
                    );
                    if (picked != null) {
                      setDialogState(() {
                        startHour = picked.hour;
                        startMinute = picked.minute;
                      });
                    }
                  },
                ),
                TextField(controller: rateController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Ставка')),
                const SizedBox(height: 8),
                DropdownButtonFormField<RateType>(
                  value: selectedRateType,
                  decoration: const InputDecoration(labelText: 'Тип расчёта'),
                  items: RateType.values.map((t) => DropdownMenuItem(value: t, child: Text(t == RateType.perHour ? 'за час' : 'за смену'))).toList(),
                  onChanged: (value) { if (value != null) setDialogState(() => selectedRateType = value); },
                ),
                const SizedBox(height: 8),
                TextField(controller: coefOverController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Коэфф. переработки')),
                const SizedBox(height: 8),
                TextField(controller: coefUnderController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Коэфф. недоработки')),
                const SizedBox(height: 8),
                SwitchListTile(title: const Text('Считать в зарплате'), value: countInSalary, onChanged: (v) => setDialogState(() => countInSalary = v)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    const Color(0xFF90CAF9), const Color(0xFFCE93D8), const Color(0xFFFFCC80),
                    const Color(0xFFEF9A9A), const Color(0xFFA5D6A7), const Color(0xFF80CBC4),
                    const Color(0xFFFFF59D), const Color(0xFFBCAAA4),
                  ].map((c) => GestureDetector(
                    onTap: () => setDialogState(() => selectedColor = c),
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: c, shape: BoxShape.circle,
                        border: selectedColor == c ? Border.all(color: Colors.black, width: 2) : null,
                      ),
                    ),
                  )).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final newType = ShiftType(
                  id: existing?.id ?? 'type_${DateTime.now().millisecondsSinceEpoch}',
                  name: name,
                  letter: letterController.text.trim().isNotEmpty ? letterController.text.trim()[0] : name[0],
                  color: selectedColor,
                  plannedHours: double.tryParse(hoursController.text) ?? 0,
                  countInSalary: countInSalary,
                  rateValue: double.tryParse(rateController.text) ?? 0,
                  rateType: selectedRateType,
                  coefOvertime: double.tryParse(coefOverController.text) ?? 1.0,
                  coefUndertime: double.tryParse(coefUnderController.text) ?? 1.0,
                  startHour: startHour,
                  startMinute: startMinute,
                );
                setState(() {
                  if (existing == null) { _shiftTypes.add(newType); }
                  else { final i = _shiftTypes.indexWhere((t) => t.id == existing.id); if (i >= 0) _shiftTypes[i] = newType; }
                });
                widget.onShiftTypesChanged(_shiftTypes);
                Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }
}