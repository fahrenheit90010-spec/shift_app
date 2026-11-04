import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'data/models.dart';
import 'data/holiday_loader.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru_RU', null);
  runApp(const ShiftApp());
}

class ShiftApp extends StatelessWidget {
  const ShiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'График смен: Календарь и Зарплата',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ru'),
        Locale('en'),
      ],
      locale: const Locale('ru'),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  final List<ShiftType> _shiftTypes = ShiftType.defaults();
  final List<Rate> _rates = Rate.defaults();
  final Map<String, ShiftEntry> _shifts = {};
  List<Holiday> _holidays = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final loadedHolidays = await loadHolidays();
    final prefs = await SharedPreferences.getInstance();
    final savedShifts = prefs.getStringList('shifts') ?? [];

    final map = <String, ShiftEntry>{};
    for (final entry in savedShifts) {
      final parts = entry.split('::');
      if (parts.length == 2) {
        map[parts[0]] = ShiftEntry.fromStorageString(parts[1]);
      }
    }

    setState(() {
      _holidays = loadedHolidays;
      _shifts.addAll(map);
    });
  }

  Future<void> _saveShifts() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _shifts.entries
        .map((e) => '${e.key}::${e.value.toStorageString()}')
        .toList();
    await prefs.setStringList('shifts', list);
  }

  String _dateKey(DateTime day) {
    return '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  }

  ShiftType? _getShiftType(String id) {
    try {
      return _shiftTypes.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  Rate? _getRate(String? id) {
    if (id == null) return null;
    try {
      return _rates.firstWhere((r) => r.id == id);
    } catch (_) {
      return null;
    }
  }

  Holiday? _getHoliday(DateTime day) {
    final key = _dateKey(day);
    try {
      return _holidays.firstWhere((h) => _dateKey(h.date) == key);
    } catch (_) {
      return null;
    }
  }

  bool _isRedDay(DateTime day) {
    final holiday = _getHoliday(day);
    if (holiday != null) {
      return !holiday.isWorkday;
    }
    return day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мой график'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            TableCalendar(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                          onHeaderTapped: (focusedDay) {
              _showCustomMonthPicker(context, focusedDay);
            },
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                });
              },
              calendarFormat: CalendarFormat.month,
              availableCalendarFormats: const {CalendarFormat.month: 'Месяц'},
              locale: 'ru_RU',
              startingDayOfWeek: StartingDayOfWeek.monday,
              daysOfWeekHeight: 24.0,
              calendarBuilders: CalendarBuilders(
                defaultBuilder: (context, day, focusedDay) => _buildDayCell(day),
                todayBuilder: (context, day, focusedDay) => _buildDayCell(day),
                selectedBuilder: (context, day, focusedDay) => _buildDayCell(day, isSelected: true),
                outsideBuilder: (context, day, focusedDay) => _buildDayCell(day, isOutside: true),
              ),
            ),
            const SizedBox(height: 8),
            if (_selectedDay != null) _buildBottomPanel(),
          ],
        ),
      ),
    );
  }
  void _showCustomMonthPicker(BuildContext context, DateTime initialDate) {
    final months = [
      'Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн',
      'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек'
    ];
    int selectedYear = initialDate.year;
    int selectedMonth = initialDate.month;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () {
                      setDialogState(() {
                        selectedYear--;
                      });
                    },
                  ),
                  Text('$selectedYear'),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () {
                      setDialogState(() {
                        selectedYear++;
                      });
                    },
                  ),
                ],
              ),
              content: SizedBox(
                width: 300,
                height: 300,
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    childAspectRatio: 1.5,
                  ),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    final monthNumber = index + 1;
                    final isSelected = monthNumber == selectedMonth;
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _focusedDay = DateTime(selectedYear, monthNumber, 1);
                          _selectedDay = null;
                        });
                        Navigator.pop(context);
                      },
                      child: Container(
                        margin: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.blue.shade100 : null,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            months[index],
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDayCell(DateTime day, {bool isSelected = false, bool isOutside = false}) {
    final key = _dateKey(day);
    final shift = _shifts[key];
    final shiftType = shift != null ? _getShiftType(shift.typeId) : null;
    final isRed = _isRedDay(day);
    final isToday = isSameDay(day, DateTime.now());

    return Opacity(
      opacity: isOutside ? 0.3 : 1.0,
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: shiftType != null ? shiftType.color : null,
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(color: Colors.black, width: 2)
              : (isToday ? Border.all(color: Colors.black, width: 1) : null),
        ),
        child: Center(
          child: Text(
            '${day.day}',
            style: TextStyle(
              color: shiftType != null
                  ? Colors.black
                  : (isRed ? Colors.red : Colors.black),
              fontWeight: isRed || shiftType != null || isToday || isSelected
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    final key = _dateKey(_selectedDay!);
    final shift = _shifts[key];

    if (shift == null) {
      return _buildShiftPicker();
    } else {
      return _buildShiftCard(key, shift);
    }
  }

  Widget _buildShiftPicker() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Выбери тип смены:',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ..._shiftTypes.map((type) => _buildShiftCircle(type)),
              _buildAddCircle(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildShiftCircle(ShiftType type) {
    return GestureDetector(
      onTap: () async {
        setState(() {
          _shifts[_dateKey(_selectedDay!)] = ShiftEntry(
            typeId: type.id,
            actualHours: type.plannedHours,
          );
        });
        await _saveShifts();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: type.color,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                type.letter,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            type.name,
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildAddCircle() {
    return GestureDetector(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Создание нового типа смены — скоро')),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Icon(Icons.add, color: Colors.black54),
            ),
          ),
          const SizedBox(height: 4),
          const Text('Добавить', style: TextStyle(fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildShiftCard(String key, ShiftEntry shift) {
    final type = _getShiftType(shift.typeId);
    final rate = _getRate(shift.rateId);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (type != null)
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: type.color, shape: BoxShape.circle),
                  child: Center(
                    child: Text(type.letter, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              const SizedBox(width: 12),
              Text(
                '${_selectedDay!.day}.${_selectedDay!.month.toString().padLeft(2, '0')}.${_selectedDay!.year}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Фактические часы', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  Text(
                    '${shift.actualHours.toStringAsFixed(1)} ч',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Row(
                children: [
                  _buildHourButton('-1', () => _changeHours(key, shift, -1)),
                  const SizedBox(width: 8),
                  _buildHourButton('+1', () => _changeHours(key, shift, 1)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Ставка: ', style: TextStyle(fontSize: 14)),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: shift.rateId,
                  hint: const Text('Выбери ставку'),
                  items: _rates.map((r) {
                    return DropdownMenuItem(
                      value: r.id,
                      child: Text('${r.name} (${r.value.toStringAsFixed(0)} ₽)'),
                    );
                  }).toList(),
                  onChanged: (value) async {
                    setState(() {
                      shift.rateId = value;
                    });
                    await _saveShifts();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Сумма: ${_calculateAmount(shift, type, rate).toStringAsFixed(2)} ₽',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () async {
              setState(() {
                _shifts.remove(key);
              });
              await _saveShifts();
            },
            icon: const Icon(Icons.delete, color: Colors.red),
            label: const Text('Удалить смену', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildHourButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.blue,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Future<void> _changeHours(String key, ShiftEntry shift, double delta) async {
    setState(() {
      shift.actualHours += delta;
      if (shift.actualHours < 0) shift.actualHours = 0;
    });
    await _saveShifts();
  }

  double _calculateAmount(ShiftEntry shift, ShiftType? type, Rate? rate) {
    if (type == null || rate == null) return 0;
    if (!type.countInSalary) return 0;

    switch (rate.type) {
      case RateType.perHour:
        return shift.actualHours * rate.value;
      case RateType.perShift:
        return rate.value;
      case RateType.perWeek:
        return rate.value / 5;
      case RateType.perMonth:
        return rate.value / 21;
    }
  }
}