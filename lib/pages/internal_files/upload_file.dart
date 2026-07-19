import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Τα target fields για το mapping
const List<String> kTargetFields = [
  '-- Unmapped --',
  'prod_id',
  'desc',
  'shipped_date',
  'qnt',
];

/// Ένα parsed row αφού γίνει mapping
class MappedRow {
  final String prodId;
  final String desc;
  final String shippedDate;
  final String qnt;

  const MappedRow({
    required this.prodId,
    required this.desc,
    required this.shippedDate,
    required this.qnt,
  });
}

class UploadFilePage extends StatefulWidget {
  const UploadFilePage({super.key});

  @override
  State<UploadFilePage> createState() => _UploadFilePageState();
}

class _UploadFilePageState extends State<UploadFilePage> {
  // Raw parsed data
  List<String> _sourceColumns = [];
  List<List<String>> _rawRows = [];

  // Column mapping: source column index → target field name
  Map<int, String> _columnMapping = {};

  // State
  bool _isLoading = false;
  String? _fileName;
  String? _errorMessage;
  bool _mappingApplied = false;
  List<MappedRow> _mappedRows = [];

  // Firebase Storage upload state
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String? _uploadedUrl;
  String? _uploadError;

  // ── File picking ──────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _mappingApplied = false;
      _mappedRows = [];
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'csv', 'tsv', 'json'],
        withData: true, // Required for web
      );

      if (result == null || result.files.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      final file = result.files.first;
      final bytes = file.bytes;
      final name = file.name;

      if (bytes == null) {
        setState(() {
          _errorMessage = 'Δεν ήταν δυνατή η ανάγνωση του αρχείου.';
          _isLoading = false;
        });
        return;
      }

      _fileName = name;
      final ext = name.split('.').last.toLowerCase();

      // Parse locally for preview
      switch (ext) {
        case 'csv':
          _parseCSV(bytes, ',');
          break;
        case 'tsv':
          _parseCSV(bytes, '\t');
          break;
        case 'xlsx':
          _parseXLSX(bytes);
          break;
        case 'json':
          _parseJSON(bytes);
          break;
        default:
          setState(() {
            _errorMessage = 'Μη υποστηριζόμενος τύπος αρχείου: .$ext';
          });
      }

      // Upload to Firebase Storage → demo_upload/
      await _uploadToStorage(bytes, name);
    } catch (e) {
      setState(() {
        _errorMessage = 'Σφάλμα κατά το upload: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Parsers ────────────────────────────────────────────────────────────

  void _parseCSV(Uint8List bytes, String delimiter) {
    final content = utf8.decode(bytes);
    final rows = const CsvToListConverter()
        .convert(content, fieldDelimiter: delimiter, eol: '\n');

    if (rows.isEmpty) {
      setState(() => _errorMessage = 'Το αρχείο είναι κενό.');
      return;
    }

    setState(() {
      _sourceColumns = rows.first.map((e) => e.toString().trim()).toList();
      _rawRows = rows
          .skip(1)
          .map((row) => row.map((e) => e.toString().trim()).toList())
          .toList();
      _columnMapping = {};
      _autoMap();
    });
  }

  void _parseXLSX(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    final sheetName = excel.tables.keys.first;
    final sheet = excel.tables[sheetName];

    if (sheet == null || sheet.rows.isEmpty) {
      setState(() => _errorMessage = 'Το αρχείο XLSX είναι κενό.');
      return;
    }

    setState(() {
      _sourceColumns = sheet.rows.first
          .map((cell) => cell?.value?.toString().trim() ?? '')
          .toList();
      _rawRows = sheet.rows
          .skip(1)
          .map((row) =>
              row.map((cell) => cell?.value?.toString().trim() ?? '').toList())
          .toList();
      _columnMapping = {};
      _autoMap();
    });
  }

  void _parseJSON(Uint8List bytes) {
    final content = utf8.decode(bytes);
    final decoded = jsonDecode(content);

    List<Map<String, dynamic>> items;
    if (decoded is List) {
      items = decoded.cast<Map<String, dynamic>>();
    } else if (decoded is Map && decoded.containsKey('data')) {
      items = (decoded['data'] as List).cast<Map<String, dynamic>>();
    } else {
      setState(() =>
          _errorMessage = 'Το JSON πρέπει να είναι array ή { "data": [...] }');
      return;
    }

    if (items.isEmpty) {
      setState(() => _errorMessage = 'Κενό JSON array.');
      return;
    }

    // Collect all unique keys across all objects
    final allKeys = <String>{};
    for (final item in items) {
      allKeys.addAll(item.keys);
    }

    setState(() {
      _sourceColumns = allKeys.toList();
      _rawRows = items
          .map((item) =>
              _sourceColumns.map((k) => item[k]?.toString() ?? '').toList())
          .toList();
      _columnMapping = {};
      _autoMap();
    });
  }

  // ── Auto-mapping (fuzzy match) ────────────────────────────────────────

  void _autoMap() {
    final aliases = <String, List<String>>{
      'prod_id': ['prod_id', 'product_id', 'productid', 'id', 'sku', 'code'],
      'desc': [
        'desc',
        'description',
        'product_desc',
        'name',
        'product_name',
        'title',
        'περιγραφή'
      ],
      'shipped_date': [
        'shipped_date',
        'ship_date',
        'shippeddate',
        'date',
        'ημερομηνία',
        'shipdate',
        'delivery_date'
      ],
      'qnt': [
        'qnt',
        'qty',
        'quantity',
        'ποσότητα',
        'amount',
        'count',
        'units'
      ],
    };

    for (var i = 0; i < _sourceColumns.length; i++) {
      final colLower = _sourceColumns[i].toLowerCase().replaceAll(' ', '_');
      for (final entry in aliases.entries) {
        if (entry.value.contains(colLower)) {
          _columnMapping[i] = entry.key;
          break;
        }
      }
    }
  }

  // ── Apply mapping ─────────────────────────────────────────────────────

  void _applyMapping() {
    // Find column indices for each target field
    int? prodIdIdx, descIdx, shippedDateIdx, qntIdx;

    _columnMapping.forEach((srcIdx, target) {
      switch (target) {
        case 'prod_id':
          prodIdIdx = srcIdx;
          break;
        case 'desc':
          descIdx = srcIdx;
          break;
        case 'shipped_date':
          shippedDateIdx = srcIdx;
          break;
        case 'qnt':
          qntIdx = srcIdx;
          break;
      }
    });

    final mapped = <MappedRow>[];
    for (final row in _rawRows) {
      mapped.add(MappedRow(
        prodId: _safeGet(row, prodIdIdx),
        desc: _safeGet(row, descIdx),
        shippedDate: _safeGet(row, shippedDateIdx),
        qnt: _safeGet(row, qntIdx),
      ));
    }

    setState(() {
      _mappedRows = mapped;
      _mappingApplied = true;
    });
  }

  String _safeGet(List<String> row, int? idx) {
    if (idx == null || idx < 0 || idx >= row.length) return '';
    return row[idx];
  }

  // ── Clear ─────────────────────────────────────────────────────────────

  void _clearData() {
    setState(() {
      _sourceColumns = [];
      _rawRows = [];
      _columnMapping = {};
      _fileName = null;
      _errorMessage = null;
      _mappingApplied = false;
      _mappedRows = [];
      _isUploading = false;
      _uploadProgress = 0.0;
      _uploadedUrl = null;
      _uploadError = null;
    });
  }

  // ── Upload to Firebase Storage ────────────────────────────────────────

  Future<void> _uploadToStorage(Uint8List bytes, String fileName) async {
    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
      _uploadedUrl = null;
      _uploadError = null;
    });

    try {
      // Αποθήκευση στο demo_upload/<timestamp>_<filename>
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final storagePath = 'demo_upload/${timestamp}_$fileName';
      final ref = FirebaseStorage.instance.ref(storagePath);

      // Metadata βάσει extension
      final ext = fileName.split('.').last.toLowerCase();
      String contentType;
      switch (ext) {
        case 'xlsx':
          contentType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
          break;
        case 'csv':
          contentType = 'text/csv';
          break;
        case 'tsv':
          contentType = 'text/tab-separated-values';
          break;
        case 'json':
          contentType = 'application/json';
          break;
        default:
          contentType = 'application/octet-stream';
      }

      final uploadTask = ref.putData(
        bytes,
        SettableMetadata(contentType: contentType),
      );

      // Track progress
      uploadTask.snapshotEvents.listen((event) {
        if (mounted) {
          setState(() {
            _uploadProgress =
                event.bytesTransferred / event.totalBytes;
          });
        }
      });

      await uploadTask;
      final downloadUrl = await ref.getDownloadURL();

      if (mounted) {
        setState(() {
          _uploadedUrl = downloadUrl;
          _isUploading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploadError = 'Upload σε Storage απέτυχε: $e';
          _isUploading = false;
        });
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload & Preview'),
        centerTitle: true,
        actions: [
          if (_sourceColumns.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Καθαρισμός',
              onPressed: _clearData,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Upload area ──
            _buildUploadCard(colorScheme),
            const SizedBox(height: 16),

            // ── Error message ──
            if (_errorMessage != null) ...[
              Card(
                color: colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ── Upload progress / status ──
            if (_isUploading || _uploadedUrl != null || _uploadError != null) ...[
              _buildStorageStatusCard(colorScheme),
              const SizedBox(height: 16),
            ],

            // ── Column mapping ──
            if (_sourceColumns.isNotEmpty && !_mappingApplied) ...[
              _buildMappingCard(colorScheme),
              const SizedBox(height: 16),
            ],

            // ── Preview DataTable ──
            if (_mappingApplied && _mappedRows.isNotEmpty)
              Expanded(child: _buildPreviewTable(colorScheme)),

            // ── Raw preview (before mapping) ──
            if (_sourceColumns.isNotEmpty && !_mappingApplied)
              Expanded(child: _buildRawPreviewTable(colorScheme)),
          ],
        ),
      ),
    );
  }

  // ── Upload card ───────────────────────────────────────────────────────

  Widget _buildUploadCard(ColorScheme colorScheme) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.outline.withAlpha(60),
        ),
      ),
      child: InkWell(
        onTap: _isLoading ? null : _pickFile,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
          child: Column(
            children: [
              Icon(
                _fileName != null
                    ? Icons.check_circle_outline
                    : Icons.cloud_upload_outlined,
                size: 48,
                color: _fileName != null
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              if (_isLoading)
                const CircularProgressIndicator()
              else
                Text(
                  _fileName ?? 'Πατήστε για να ανεβάσετε αρχείο',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight:
                        _fileName != null ? FontWeight.w600 : FontWeight.normal,
                    color: _fileName != null
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Υποστηριζόμενοι τύποι: .xlsx, .csv, .tsv, .json',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (_rawRows.isNotEmpty) ...[
                const SizedBox(height: 8),
                Chip(
                  avatar: const Icon(Icons.table_rows_outlined, size: 16),
                  label: Text('${_rawRows.length} εγγραφές'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Mapping card ──────────────────────────────────────────────────────

  Widget _buildMappingCard(ColorScheme colorScheme) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.swap_horiz, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Column Mapping',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Αντιστοιχίστε τις στήλες του αρχείου στα πεδία',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            // Mapping rows
            ...List.generate(_sourceColumns.length, (i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    // Source column name
                    Expanded(
                      flex: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 10, horizontal: 12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _sourceColumns[i],
                          style: const TextStyle(fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.arrow_forward,
                          size: 20, color: colorScheme.primary),
                    ),
                    // Target dropdown
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _columnMapping[i] ?? kTargetFields.first,
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          isDense: true,
                        ),
                        items: kTargetFields
                            .map((f) => DropdownMenuItem(
                                  value: f,
                                  child: Text(f, overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (value) {
                          setState(() {
                            if (value == null || value == kTargetFields.first) {
                              _columnMapping.remove(i);
                            } else {
                              // Remove previous assignment of this target
                              _columnMapping
                                  .removeWhere((_, v) => v == value);
                              _columnMapping[i] = value;
                            }
                          });
                        },
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _columnMapping.isNotEmpty ? _applyMapping : null,
                icon: const Icon(Icons.check),
                label: const Text('Εφαρμογή Mapping & Preview'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Raw preview (before mapping) ──────────────────────────────────────

  Widget _buildRawPreviewTable(ColorScheme colorScheme) {
    final previewRows = _rawRows.take(10).toList();

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Raw Preview (πρώτες ${previewRows.length} εγγραφές)',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(
                      colorScheme.primaryContainer.withAlpha(80)),
                  columns: _sourceColumns
                      .map((col) => DataColumn(
                            label: Text(
                              col,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                              ),
                            ),
                          ))
                      .toList(),
                  rows: previewRows
                      .map((row) => DataRow(
                            cells: List.generate(
                              _sourceColumns.length,
                              (i) => DataCell(Text(
                                i < row.length ? row[i] : '',
                                overflow: TextOverflow.ellipsis,
                              )),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Mapped preview ────────────────────────────────────────────────────

  Widget _buildPreviewTable(ColorScheme colorScheme) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.preview, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Mapped Preview — ${_mappedRows.length} εγγραφές',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _mappingApplied = false);
                  },
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Αλλαγή mapping'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(
                      colorScheme.primaryContainer.withAlpha(80)),
                  columns: const [
                    DataColumn(
                        label: Text('prod_id',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(
                        label: Text('desc',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(
                        label: Text('shipped_date',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    DataColumn(
                        label: Text('qnt',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                  ],
                  rows: _mappedRows
                      .map((row) => DataRow(
                            cells: [
                              DataCell(Text(row.prodId)),
                              DataCell(
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 250),
                                  child: Text(
                                    row.desc,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              DataCell(Text(row.shippedDate)),
                              DataCell(Text(row.qnt)),
                            ],
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Storage upload status card ────────────────────────────────────────

  Widget _buildStorageStatusCard(ColorScheme colorScheme) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _uploadedUrl != null
                      ? Icons.cloud_done
                      : _uploadError != null
                          ? Icons.cloud_off
                          : Icons.cloud_upload,
                  color: _uploadedUrl != null
                      ? Colors.green
                      : _uploadError != null
                          ? colorScheme.error
                          : colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Firebase Storage',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Uploading - progress bar
            if (_isUploading) ...[
              LinearProgressIndicator(
                value: _uploadProgress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 8),
              Text(
                'Ανέβασμα... ${(_uploadProgress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            // Success
            if (_uploadedUrl != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Ανέβηκε επιτυχώς στο demo_upload/',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.green,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            _uploadedUrl!,
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Error
            if (_uploadError != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withAlpha(60),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber,
                        color: colorScheme.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _uploadError!,
                        style: TextStyle(color: colorScheme.error, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
 