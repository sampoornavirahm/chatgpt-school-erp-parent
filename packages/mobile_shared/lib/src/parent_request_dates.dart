String? validateOptionalIsoDate(String? input, {required String label}) {
  final value = input?.trim() ?? '';
  if (value.isEmpty) return null;

  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return 'Enter $label as YYYY-MM-DD.';

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) {
    return 'Enter a valid $label.';
  }

  final parsed = DateTime.utc(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    return 'Enter a valid $label.';
  }
  return null;
}

String? validateOptionalRequestDateRange({
  required String? startsOn,
  required String? endsOn,
}) {
  final start = startsOn?.trim() ?? '';
  final end = endsOn?.trim() ?? '';
  if (start.isEmpty || end.isEmpty) return null;
  if (validateOptionalIsoDate(start, label: 'start date') != null ||
      validateOptionalIsoDate(end, label: 'end date') != null) {
    return null;
  }
  if (end.compareTo(start) < 0) {
    return 'End date must be on or after the start date.';
  }
  return null;
}

String? validateAttendanceCorrectionDate(String? input) {
  final value = input?.trim() ?? '';
  if (value.isEmpty) return 'Choose the date of the attendance record.';
  final formatError = validateOptionalIsoDate(value, label: 'attendance date');
  if (formatError != null) return formatError;
  final now = DateTime.now();
  final today =
      '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  if (value.compareTo(today) > 0) {
    return 'Choose today or an earlier date.';
  }
  return null;
}
