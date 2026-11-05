import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'dart:convert';
import 'data/models.dart';
import 'data/holiday_loader.dart';

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
      primary: Color(0xFF64B5F6),
      secondary: Color(0xFF64B5F6),
      surface: Color(0xFF1E1E1E),
      onSurface: Color(0xFFE0E0E0),
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
  final Map<String, ShiftEntry> _shifts = {};
  List<Holiday> _holidays = [];
  Map<String, MonthRecord> _closedMonths = {};

  double _globalCoefOvertime = 1.0;
  double _globalCoefUndertime = 1.0;
  int _intervalMinutes = 60;

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
        try {
          types.add(ShiftType.fromJson(jsonDecode(s) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    if (types.isEmpty) types = ShiftType.defaults();

    final savedTemplates = prefs.getStringList('custom_templates') ?? [];
    final customTemplates = <ShiftTemplate>[];
    for (final s in savedTemplates) {
      try {
        customTemplates.add(ShiftTemplate.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }

    _globalCoefOvertime = double.tryParse(prefs.getString('coef_overtime') ?? '1.0') ?? 1.0;
    _globalCoefUndertime = double.tryParse(prefs.getString('coef_undertime') ?? '1.0') ?? 1.0;
    _intervalMinutes = int.tryParse(prefs.getString('interval_minutes') ?? '60') ?? 60;

    final savedShifts = prefs.getStringList('shifts') ?? [];
    final map = <String, ShiftEntry>{};
    for (final entry in savedShifts) {
      final parts = entry.split('::');
      if (parts.length == 2) map[parts[0]] = ShiftEntry.fromStorageString(parts[1]);
    }

    final savedClosed = prefs.getStringList('closed_months') ?? [];
    final closed = <String, MonthRecord>{};
    for (final s in savedClosed) {
      final rec = MonthRecord.fromStorageString(s);
      closed['${rec.year}-${rec.month}'] = rec;
    }

    setState(() {
      _holidays = loadedHolidays;
      _shiftTypes = types;
      _templates = [...ShiftTemplate.predefined(), ...customTemplates];
      _shifts.addAll(map);
      _closedMonths = closed;
    });

    _autoClosePastMonths();
  }

  Future<void> _autoClosePastMonths() async {
    final now = DateTime.now();
    final prevMonth = DateTime(now.year, now.month - 1, 1);
    final key = '${prevMonth.year}-${prevMonth.month}';
    if (!_closedMonths.containsKey(key)) {
      final hasShifts = _shifts.keys.any((k) {
        final parts = k.split('-');
        return int.parse(parts[0]) == prevMonth.year && int.parse(parts[1]) == prevMonth.month;
      });
      if (hasShifts) await _closeMonth(prevMonth.year, prevMonth.month);
    }
  }

  Future<void> _saveShifts() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _shifts.entries.map((e) => '${e.key}::${e.value.toStorageString()}').toList();
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
    await prefs.setString('interval_minutes', _intervalMinutes.toString());
  }

  Future<void> _saveClosedMonths() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _closedMonths.values.map((r) => r.toStorageString()).toList();
    await prefs.setStringList('closed_months', list);
  }

  bool _isMonthClosed(int year, int month) => _closedMonths.containsKey('$year-$month');

  Future<void> _closeMonth(int year, int month) async {
    final entries = _shifts.entries.where((e) {
      final parts = e.key.split('-');
      return int.parse(parts[0]) == year && int.parse(parts[1]) == month;
    }).toList();

    int workShifts = 0, sickDays = 0, vacationDays = 0;
    double totalHours = 0, overtime = 0, undertime = 0, totalAmount = 0;
    final ratesUsed = <String>{};

    for (final e in entries) {
      final shift = e.value;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мой график'),
        actions: [
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
      ),
    ));
  }

  Map<String, dynamic> _computeStats(int year, int month) {
    final entries = _shifts.entries.where((e) {
      final parts = e.key.split('-');
      return int.parse(parts[0]) == year && int.parse(parts[1]) == month;
    }).toList();

    int workShifts = 0, sickDays = 0, vacationDays = 0;
    double totalHours = 0, overtime = 0, undertime = 0, totalAmount = 0;

    for (final e in entries) {
      final shift = e.value;
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

  void _openSettings() {
    Navigator.push(context, MaterialPageRoute(
      builder: (context) => SettingsScreen(
        shiftTypes: _shiftTypes,
        templates: _templates,
        themeMode: widget.themeMode,
        globalCoefOvertime: _globalCoefOvertime,
        globalCoefUndertime: _globalCoefUndertime,
        intervalMinutes: _intervalMinutes,
        onThemeChanged: widget.onThemeChanged,
        onShiftTypesChanged: (newTypes) async {
          setState(() => _shiftTypes = newTypes);
          await _saveShiftTypes();
        },
        onTemplatesChanged: (newTemplates) async {
          setState(() => _templates = newTemplates);
          await _saveTemplates();
        },
        onGlobalSettingsChanged: (coefOver, coefUnder, interval) async {
          setState(() {
            _globalCoefOvertime = coefOver;
            _globalCoefUndertime = coefUnder;
            _intervalMinutes = interval;
          });
          await _saveGlobalSettings();
        },
        onGenerateTemplate: _generateFromTemplate,
      ),
    ));
  }

    Future<void> _generateFromTemplate(ShiftTemplate template, DateTime startDate, String typeId, int months) async {
    final endDate = DateTime(startDate.year, startDate.month + months, 0);
    final newShifts = <String, ShiftEntry>{};
    int overwritten = 0;

    for (int i = 0; i <= endDate.difference(startDate).inDays; i++) {
      final date = startDate.add(Duration(days: i));
      if (date.isAfter(endDate)) break;
      if (_isMonthClosed(date.year, date.month)) continue;

      final step = template.cycle[i % template.cycle.length];
      if (step == 'rest') continue;

      // Для своих шаблонов step = id типа ('day','night','daily'). Для предустановленных step = 'work'.
      final effectiveTypeId = (step == 'work') ? typeId : step;
      final type = _getShiftType(effectiveTypeId);
      if (type == null) continue;

      final key = _dateKey(date);
      if (_shifts.containsKey(key)) {
        overwritten++;
        continue;
      }
      newShifts[key] = ShiftEntry(typeId: type.id, actualHours: type.plannedHours);
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

      for (int i = 0; i <= endDate.difference(startDate).inDays; i++) {
        final date = startDate.add(Duration(days: i));
        if (date.isAfter(endDate)) break;
        if (_isMonthClosed(date.year, date.month)) continue;
        final step = template.cycle[i % template.cycle.length];
        if (step == 'rest') continue;
        final effectiveTypeId = (step == 'work') ? typeId : step;
        final type = _getShiftType(effectiveTypeId);
        if (type == null) continue;
        final key = _dateKey(date);
        newShifts[key] = ShiftEntry(typeId: type.id, actualHours: type.plannedHours);
      }
    }

    setState(() => _shifts.addAll(newShifts));
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
    final key = _dateKey(day);
    final shift = _shifts[key];
    final shiftType = shift != null ? _getShiftType(shift.typeId) : null;
    final isRed = _isRedDay(day);
    final isToday = isSameDay(day, DateTime.now());
    final isClosed = _isMonthClosed(day.year, day.month);

    return Opacity(
      opacity: isOutside ? 0.3 : (isClosed ? 0.6 : 1.0),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: shiftType != null ? shiftType.color : null,
          shape: BoxShape.circle,
          border: isSelected ? Border.all(color: _textColor, width: 2) : (isToday ? Border.all(color: _textColor, width: 1) : null),
        ),
        child: Center(
          child: Text('${day.day}', style: TextStyle(
            color: shiftType != null ? Colors.black : (isRed ? _redColor : _textColor),
            fontWeight: isRed || shiftType != null || isToday || isSelected ? FontWeight.bold : FontWeight.normal,
          )),
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
    final shift = _shifts[key];
    if (shift == null) return _buildShiftPicker();
    return _buildShiftCard(key, shift);
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
        ],
      ),
    );
  }

  Widget _buildShiftCircle(ShiftType type) {
    return GestureDetector(
      onTap: () async {
        setState(() { _shifts[_dateKey(_selectedDay!)] = ShiftEntry(typeId: type.id, actualHours: type.plannedHours); });
        await _saveShifts();
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

  Widget _buildShiftCard(String key, ShiftEntry shift) {
    final type = _getShiftType(shift.typeId);
    final amount = _calculateAmount(shift, type);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _bgColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (type != null)
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
                  child: Center(child: Text(type.letter, style: const TextStyle(fontWeight: FontWeight.bold))),
                ),
              const SizedBox(width: 12),
              Expanded(child: Text(
                '${_selectedDay!.day}.${_selectedDay!.month.toString().padLeft(2, '0')}.${_selectedDay!.year}',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _textColor),
              )),
              IconButton(icon: Icon(Icons.more_vert, color: _textColor), onPressed: () => _showShiftMenu(key, shift)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Фактические часы', style: TextStyle(fontSize: 12, color: _subtextColor)),
                  Text('${shift.actualHours.toStringAsFixed(1)} ч', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _textColor)),
                ],
              ),
              Row(
                children: [
                  _buildIntervalButton(Icons.remove, () => _changeHours(key, shift, -1)),
                  const SizedBox(width: 8),
                  _buildIntervalButton(Icons.add, () => _changeHours(key, shift, 1)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _intervalMinutes,
                    dropdownColor: _isDark ? const Color(0xFF1E1E1E) : Colors.white,
                    style: TextStyle(color: _textColor),
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15 мин')),
                      DropdownMenuItem(value: 30, child: Text('30 мин')),
                      DropdownMenuItem(value: 60, child: Text('1 час')),
                    ],
                    onChanged: (value) async {
                      if (value != null) { setState(() => _intervalMinutes = value); await _saveGlobalSettings(); }
                    },
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Сумма: ${amount.toStringAsFixed(2)} ₽', style: TextStyle(
            fontSize: 18, fontWeight: FontWeight.bold,
            color: _isDark ? const Color(0xFF64B5F6) : Colors.blue,
          )),
        ],
      ),
    );
  }

  Widget _buildIntervalButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: _isDark ? const Color(0xFF2C3E50) : Colors.blue, borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: _isDark ? const Color(0xFF90CAF9) : Colors.white, size: 20),
      ),
    );
  }

  void _showShiftMenu(String key, ShiftEntry shift) {
    showModalBottomSheet(
      context: context,
      backgroundColor: _bgColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.tune, color: _textColor),
              title: Text('Настройки смены', style: TextStyle(color: _textColor)),
              onTap: () { Navigator.pop(context); _showShiftSettings(key, shift); },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: _redColor),
              title: Text('Удалить смену', style: TextStyle(color: _redColor)),
              onTap: () async {
                setState(() => _shifts.remove(key));
                await _saveShifts();
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showShiftSettings(String key, ShiftEntry shift) {
    final type = _getShiftType(shift.typeId);
    if (type == null) return;

    final rateController = TextEditingController(text: (shift.overrideRateValue ?? type.rateValue).toStringAsFixed(0));
    final coefOverController = TextEditingController(text: (shift.overrideCoefOvertime ?? type.coefOvertime).toString());
    final coefUnderController = TextEditingController(text: (shift.overrideCoefUndertime ?? type.coefUndertime).toString());
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

  Future<void> _changeHours(String key, ShiftEntry shift, int direction) async {
    final delta = _intervalMinutes / 60.0 * direction;
    setState(() {
      shift.actualHours += delta;
      if (shift.actualHours < 0) shift.actualHours = 0;
    });
    await _saveShifts();
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

class StatsScreen extends StatefulWidget {
  final int initialYear;
  final int initialMonth;
  final bool Function(int year, int month) isMonthClosed;
  final MonthRecord? Function(int year, int month) getClosedRecord;
  final Future<void> Function(int year, int month) onClose;
  final Future<void> Function(int year, int month) onUnfreeze;
  final Map<String, dynamic> Function(int year, int month) computeStats;

  const StatsScreen({
    super.key,
    required this.initialYear, required this.initialMonth,
    required this.isMonthClosed, required this.getClosedRecord,
    required this.onClose, required this.onUnfreeze, required this.computeStats,
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
          if (!isClosed)
            ElevatedButton.icon(
              onPressed: () async { await widget.onClose(_year, _month); setState(() {}); },
              icon: const Icon(Icons.lock),
              label: const Text('Закрыть месяц'),
            )
          else
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
  final int intervalMinutes;
  final ValueChanged<ThemeMode> onThemeChanged;
  final ValueChanged<List<ShiftType>> onShiftTypesChanged;
  final ValueChanged<List<ShiftTemplate>> onTemplatesChanged;
  final Function(double, double, int) onGlobalSettingsChanged;
  final Future<void> Function(ShiftTemplate, DateTime, String, int) onGenerateTemplate;

  const SettingsScreen({
    super.key,
    required this.shiftTypes, required this.templates, required this.themeMode,
    required this.globalCoefOvertime, required this.globalCoefUndertime, required this.intervalMinutes,
    required this.onThemeChanged, required this.onShiftTypesChanged, required this.onTemplatesChanged,
    required this.onGlobalSettingsChanged, required this.onGenerateTemplate,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late List<ShiftType> _shiftTypes;
  late List<ShiftTemplate> _templates;
  late double _coefOver;
  late double _coefUnder;
  late int _interval;

  @override
  void initState() {
    super.initState();
    _shiftTypes = List.from(widget.shiftTypes);
    _templates = List.from(widget.templates);
    _coefOver = widget.globalCoefOvertime;
    _coefUnder = widget.globalCoefUndertime;
    _interval = widget.intervalMinutes;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Тема', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _buildThemeTile('Светлая', ThemeMode.light),
          _buildThemeTile('Тёмная', ThemeMode.dark),
          _buildThemeTile('Системная', ThemeMode.system),
          const SizedBox(height: 24),
          const Text('Типы смен', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ..._shiftTypes.map((t) => _buildShiftTypeTile(t)),
          const SizedBox(height: 8),
          ElevatedButton.icon(onPressed: _addShiftType, icon: const Icon(Icons.add), label: const Text('Добавить тип смены')),
          const SizedBox(height: 24),
          const Text('Шаблоны смен', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ..._templates.map((t) => _buildTemplateTile(t)),
          const SizedBox(height: 8),
          ElevatedButton.icon(onPressed: _createCustomTemplate, icon: const Icon(Icons.add), label: const Text('Создать свой шаблон')),
          const SizedBox(height: 24),
          const Text('Коэффициенты (глобальные)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _buildNumberField('Переработка', _coefOver, (v) { setState(() => _coefOver = v); widget.onGlobalSettingsChanged(_coefOver, _coefUnder, _interval); }),
          _buildNumberField('Недоработка', _coefUnder, (v) { setState(() => _coefUnder = v); widget.onGlobalSettingsChanged(_coefOver, _coefUnder, _interval); }),
          const SizedBox(height: 24),
          const Text('Интервал ±', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            value: _interval,
            decoration: const InputDecoration(labelText: 'Шаг изменения часов'),
            items: const [
              DropdownMenuItem(value: 15, child: Text('15 минут')),
              DropdownMenuItem(value: 30, child: Text('30 минут')),
              DropdownMenuItem(value: 60, child: Text('1 час')),
            ],
            onChanged: (value) {
              if (value != null) { setState(() => _interval = value); widget.onGlobalSettingsChanged(_coefOver, _coefUnder, _interval); }
            },
          ),
        ],
      ),
    );
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
    return Card(
      child: ListTile(
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
          child: Center(child: Text(type.letter, style: const TextStyle(fontWeight: FontWeight.bold))),
        ),
        title: Text(type.name),
        subtitle: Text('${type.plannedHours} ч • ${type.rateValue.toStringAsFixed(0)} ₽ ${type.rateType == RateType.perHour ? "/ч" : "/смена"}'),
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
            IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _showGenerateDialog(template)),
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

  void _createCustomTemplate() {
    final nameController = TextEditingController();
    final steps = <String>[]; // typeId или 'rest'

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

  void _showGenerateDialog(ShiftTemplate template) {
    DateTime startDate = DateTime.now();
    String? typeId = _shiftTypes.isNotEmpty ? _shiftTypes.first.id : null;
    int months = 1;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Шаблон «${template.name}»'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('Дата начала'),
                  subtitle: Text('${startDate.day}.${startDate.month.toString().padLeft(2, '0')}.${startDate.year}'),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: startDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2030),
                    );
                    if (picked != null) setDialogState(() => startDate = picked);
                  },
                ),
                const SizedBox(height: 8),
                // Показываем выбор типа ТОЛЬКО для предустановленных шаблонов
                if (!template.isCustom)
                  DropdownButtonFormField<String>(
                    value: typeId,
                    decoration: const InputDecoration(labelText: 'Тип смены для рабочих дней'),
                    items: _shiftTypes.map((t) => DropdownMenuItem(value: t.id, child: Text(t.name))).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => typeId = value);
                      }
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
                  ],
                  onChanged: (value) { if (value != null) setDialogState(() => months = value); },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () {
                // Для предустановленных typeId обязателен, для своих — нет
                if (!template.isCustom && typeId == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Выбери тип смены')),
                  );
                  return;
                }
                Navigator.pop(context);
                widget.onGenerateTemplate(template, startDate, typeId ?? 'day', months);
              },
              child: const Text('Создать'),
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