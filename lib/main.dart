import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:path_provider/path_provider.dart';

enum SubjectType {
  face('Volto'),
  flower('Fiore'),
  animal('Animale'),
  plant('Pianta'),
  food('Cibo'),
  vehicle('Veicolo'),
  any('Soggetto principale');

  final String label;
  const SubjectType(this.label);
}

void main() => runApp(const MaterialApp(home: TerziApp()));

class TerziApp extends StatefulWidget {
  const TerziApp({super.key});

  @override
  State<TerziApp> createState() => _TerziAppState();
}

class _TerziAppState extends State<TerziApp> {
  List<AssetEntity> _matchingPhotos = [];
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _selectedAlbum;
  String? _selectedAlbumId;

  bool _loading = false;
  bool _stopRequested = false;
  bool _exporting = false;
  bool _syncing = false;
  bool _testing = false;

  double _tolerance = 0.12;
  SubjectType _subjectType = SubjectType.face;
  int _maxPhotos = 500;
  int _minMegapixels = 0;
  DateTime? _fromDate;

  int _totalToScan = 0;
  int _scannedCount = 0;
  int _startTime = 0;
  int _toAdd = 0;
  int _toRemove = 0;
  bool _checkingDiff = false;

  List<FlSpot> _performanceSpots = [];
  List<Map<String, dynamic>> _performanceLog = [];
  int _lastSampleTime = 0;
  int _lastSampleCount = 0;
  double _totalMlkitMs = 0;
  int _mlkitCount = 0;
  Timer? _performanceTimer;
  bool _logPerformanceEnabled = true;

  final Battery _battery = Battery();
  int _batteryLevel = 100;
  int _batteryThreshold = 20;
  bool _batteryCheckEnabled = true;
  StreamSubscription<BatteryState>? _batteryStateSub;
  bool _stoppedForBattery = false;
  String _estimateResult = '';

  static const String _albumName = 'Regola dei Terzi';
  static const String _prefsKey = 'terzi_app_state';

  @override
  void initState() {
    super.initState();
    _loadStateAndAlbums();
    _initBattery();
  }

  @override
  void dispose() {
    _batteryStateSub?.cancel();
    _performanceTimer?.cancel();
    super.dispose();
  }

  Future<void> _initBattery() async {
    _batteryLevel = await _battery.batteryLevel;
    _batteryStateSub = _battery.onBatteryStateChanged.listen((_) async {
      final level = await _battery.batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    });
  }

  void _startPerformanceTracking() {
    if (!_logPerformanceEnabled) return;
    _performanceSpots.clear();
    _performanceLog.clear();
    _totalMlkitMs = 0;
    _mlkitCount = 0;
    _lastSampleTime = DateTime.now().millisecondsSinceEpoch;
    _lastSampleCount = 0;
    _performanceTimer?.cancel();
    _performanceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_loading) {
        _performanceTimer?.cancel();
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final elapsed = (now - _lastSampleTime) / 1000;
      if (elapsed > 0) {
        final deltaCount = _scannedCount - _lastSampleCount;
        final fps = deltaCount / elapsed;
        final totalElapsed = (now - _startTime) / 1000;
        final avgMlkitMs = _mlkitCount > 0? _totalMlkitMs / _mlkitCount : 0;

        setState(() {
          _performanceSpots.add(FlSpot(_performanceSpots.length.toDouble(), fps));
          if (_performanceSpots.length > 60) _performanceSpots.removeAt(0);
        });

        _performanceLog.add({
          'timestamp': DateTime.now().toIso8601String(),
          'seconds_elapsed': totalElapsed.toStringAsFixed(1),
          'scanned_count': _scannedCount,
          'fps': fps.toStringAsFixed(2),
          'avg_mlkit_ms': avgMlkitMs.toStringAsFixed(1),
          'battery_level': _batteryLevel,
          'subject_type': _subjectType.label,
          'tolerance_percent': (_tolerance * 100).round(),
          'max_photos': _maxPhotos,
          'min_megapixels': _minMegapixels,
          'from_date': _fromDate?.toIso8601String()?? '',
          'album_name': _selectedAlbum?.name?? '',
        });

        _lastSampleTime = now;
        _lastSampleCount = _scannedCount;
      }
    });
  }

  Future<void> _exportPerformanceLog() async {
    if (_performanceLog.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nessun dato da esportare. Fai prima una scansione')),
        );
      }
      return;
    }

    try {
      final dir = await getExternalStorageDirectory();
      final downloadsDir = Directory('${dir!.path.split('Android')[0]}Download');
      if (!await downloadsDir.exists()) await downloadsDir.create();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${downloadsDir.path}/terzi_performance_$timestamp.csv');

      final buffer = StringBuffer();
      buffer.writeln('timestamp,seconds_elapsed,scanned_count,fps,avg_mlkit_ms,battery_level,subject_type,tolerance_percent,max_photos,min_megapixels,from_date,album_name');
      for (final row in _performanceLog) {
        buffer.writeln('${row['timestamp']},${row['seconds_elapsed']},${row['scanned_count']},${row['fps']},${row['avg_mlkit_ms']},${row['battery_level']},${row['subject_type']},${row['tolerance_percent']},${row['max_photos']},${row['min_megapixels']},"${row['from_date']}","${row['album_name']}"');
      }

      await file.writeAsString(buffer.toString());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('CSV salvato in Download: ${file.path.split('/').last}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore esportazione: $e')),
        );
      }
    }
  }

  Future<void> _loadStateAndAlbums() async {
    await _loadAlbums();
    await _restoreState();
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    final state = {
      'tolerance': _tolerance,
      'subjectType': _subjectType.index,
      'maxPhotos': _maxPhotos,
      'minMegapixels': _minMegapixels,
      'fromDate': _fromDate?.millisecondsSinceEpoch,
      'selectedAlbumId': _selectedAlbumId,
      'matchingPhotoIds': _matchingPhotos.map((e) => e.id).toList(),
      'batteryThreshold': _batteryThreshold,
      'batteryCheckEnabled': _batteryCheckEnabled,
      'logPerformanceEnabled': _logPerformanceEnabled,
    };
    await prefs.setString(_prefsKey, jsonEncode(state));
  }

  Future<void> _restoreState() async {
    final prefs = await SharedPreferences.getInstance();
    final stateStr = prefs.getString(_prefsKey);
    if (stateStr == null) return;

    final state = jsonDecode(stateStr);
    setState(() {
      _tolerance = state['tolerance']?? 0.12;
      _subjectType = SubjectType.values[state['subjectType']?? 0];
      _maxPhotos = state['maxPhotos']?? 500;
      _minMegapixels = state['minMegapixels']?? 0;
      _fromDate = state['fromDate']!= null? DateTime.fromMillisecondsSinceEpoch(state['fromDate']) : null;
      _selectedAlbumId = state['selectedAlbumId'];
      _batteryThreshold = state['batteryThreshold']?? 20;
      _batteryCheckEnabled = state['batteryCheckEnabled']?? true;
      _logPerformanceEnabled = state['logPerformanceEnabled']?? true;
    });

    if (_selectedAlbumId!= null && _albums.isNotEmpty) {
      _selectedAlbum = _albums.firstWhere(
        (a) => a.id == _selectedAlbumId,
        orElse: () => _albums.first,
      );
    }

    final ids = List<String>.from(state['matchingPhotoIds']?? []);
    if (ids.isNotEmpty) {
      final assets = await AssetEntity.getByIds(ids);
      setState(() => _matchingPhotos = assets);
      _calculateSyncDiff();
    }
    _updateTotalToScan();
  }

  Future<void> _clearSavedResults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    setState(() {
      _matchingPhotos.clear();
      _toAdd = 0;
      _toRemove = 0;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Risultati cancellati')),
      );
    }
  }

  Future<void> _loadAlbums() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) return;
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    setState(() {
      _albums = albums;
      _selectedAlbum??= albums.isNotEmpty? albums.first : null;
      _selectedAlbumId = _selectedAlbum?.id;
    });
    _updateTotalToScan();
  }

  Future<void> _updateTotalToScan() async {
    if (_selectedAlbum == null) return;
    int count = await _selectedAlbum!.assetCountAsync;
    if (_fromDate!= null) {
      final assets = await _selectedAlbum!.getAssetListRange(start: 0, end: count);
      count = assets.where((a) => a.createDateTime.isAfter(_fromDate!)).length;
    }
    setState(() => _totalToScan = min(count, _maxPhotos));
  }

  Future<void> _runTestScan() async {
    if (_selectedAlbum == null || _totalToScan == 0) return;

    setState(() {
      _testing = true;
      _estimateResult = '';
    });

    final testCount = min(10, _totalToScan);
    final allAssets = await _selectedAlbum!.getAssetListRange(start: 0, end: _maxPhotos);
    final assetsToScan = _fromDate == null
       ? allAssets
        : allAssets.where((a) => a.createDateTime.isAfter(_fromDate!)).toList();

    final testAssets = assetsToScan.take(testCount).toList();
    if (testAssets.isEmpty) {
      setState(() {
        _testing = false;
        _estimateResult = 'Nessuna foto da testare con i filtri attuali';
      });
      return;
    }

    FaceDetector? faceDetector;
    ObjectDetector? objectDetector;
    ImageLabeler? imageLabeler;

    if (_subjectType == SubjectType.face) {
      faceDetector = FaceDetector(options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast));
    } else {
      objectDetector = ObjectDetector(
        options: ObjectDetectorOptions(
          mode: DetectionMode.single,
          classifyObjects: true,
          multipleObjects: false,
        ),
      );
      imageLabeler = ImageLabeler(options: ImageLabelerOptions());
    }

    final testStart = DateTime.now().millisecondsSinceEpoch;
    int found = 0;

    for (final asset in testAssets) {
      if (_batteryCheckEnabled && _batteryLevel <= _batteryThreshold) break;

      final file = await asset.file;
      if (file == null) continue;

      if (_minMegapixels > 0) {
        final mp = (asset.width * asset.height) / 1000000;
        if (mp < _minMegapixels) continue;
      }

      final passesRule = await _checkRuleOfThirds(file, faceDetector, objectDetector, imageLabeler);
      if (passesRule) found++;
    }

    await faceDetector?.close();
    await objectDetector?.close();
    await imageLabeler?.close();

    final testElapsed = (DateTime.now().millisecondsSinceEpoch - testStart) / 1000;
    final avgSecPerPhoto = testElapsed / testAssets.length;
    final estimatedTotalSec = avgSecPerPhoto * _totalToScan;
    final estimatedFps = 1 / avgSecPerPhoto;
    final estimatedBatteryDrain = _totalToScan * 0.01;
    final batteryWarning = _batteryCheckEnabled && (_batteryLevel - estimatedBatteryDrain < _batteryThreshold);

    String timeStr;
    if (estimatedTotalSec < 60) {
      timeStr = '${estimatedTotalSec.toStringAsFixed(0)}s';
    } else if (estimatedTotalSec < 3600) {
      timeStr = '${(estimatedTotalSec / 60).toStringAsFixed(1)} min';
    } else {
      timeStr = '${(estimatedTotalSec / 3600).toStringAsFixed(1)} ore';
    }

    final result = 'Test su ${testAssets.length} foto: ${testElapsed.toStringAsFixed(1)}s\n'
        'Trovate: $found\n'
        'Stima totale: $timeStr\n'
        'Velocità: ${estimatedFps.toStringAsFixed(1)} foto/s\n'
        '${batteryWarning? '⚠️ Batteria potrebbe non bastare' : 'Batteria OK'}';

    setState(() {
      _testing = false;
      _estimateResult = result;
    });
  }

  Future<void> _scanGallery() async {
    if (_selectedAlbum == null) return;
    setState(() {
      _loading = true;
      _stopRequested = false;
      _stoppedForBattery = false;
      _matchingPhotos.clear();
      _scannedCount = 0;
      _startTime = DateTime.now().millisecondsSinceEpoch;
    });
    _startPerformanceTracking();
    await _saveState();

    final allAssets = await _selectedAlbum!.getAssetListRange(start: 0, end: _maxPhotos);
    final assetsToScan = _fromDate == null
       ? allAssets
        : allAssets.where((a) => a.createDateTime.isAfter(_fromDate!)).toList();

    FaceDetector? faceDetector;
    ObjectDetector? objectDetector;
    ImageLabeler? imageLabeler;

    if (_subjectType == SubjectType.face) {
      faceDetector = FaceDetector(options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast));
    } else {
      objectDetector = ObjectDetector(
        options: ObjectDetectorOptions(
          mode: DetectionMode.single,
          classifyObjects: true,
          multipleObjects: false,
        ),
      );
      imageLabeler = ImageLabeler(options: ImageLabelerOptions());
    }

    for (final asset in assetsToScan) {
      if (_stopRequested) break;

      if (_batteryCheckEnabled && _batteryLevel <= _batteryThreshold) {
        setState(() {
          _stopRequested = true;
          _stoppedForBattery = true;
        });
        break;
      }

      final file = await asset.file;
      if (file == null) {
        _incrementScanned();
        continue;
      }

      if (_minMegapixels > 0) {
        final mp = (asset.width * asset.height) / 1000000;
        if (mp < _minMegapixels) {
          _incrementScanned();
          continue;
        }
      }

      final passesRule = await _checkRuleOfThirds(file, faceDetector, objectDetector, imageLabeler);
      if (passesRule) {
        _matchingPhotos.add(asset);
        await _saveState();
      }
      _incrementScanned();
    }

    await faceDetector?.close();
    await objectDetector?.close();
    await imageLabeler?.close();
    _performanceTimer?.cancel();

    if (mounted) {
      setState(() => _loading = false);
      await _saveState();
      _calculateSyncDiff();
      if (_stoppedForBattery) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Scansione fermata: batteria al $_batteryLevel%')),
        );
      }
    }
  }

  Future<bool> _checkRuleOfThirds(
    File file,
    FaceDetector? faceDetector,
    ObjectDetector? objectDetector,
    ImageLabeler? imageLabeler,
  ) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return false;

    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final inputImage = InputImage.fromFile(file);

    Point? subjectCenter;
    final mlkitStart = DateTime.now().millisecondsSinceEpoch;

    if (_subjectType == SubjectType.face && faceDetector!= null) {
      final faces = await faceDetector.processImage(inputImage);
      if (faces.isNotEmpty) {
        subjectCenter = Point(faces.first.boundingBox.center.dx, faces.first.boundingBox.center.dy);
      }
    } else if (objectDetector!= null && imageLabeler!= null) {
      final objects = await objectDetector.processImage(inputImage);
      final labels = await imageLabeler.processImage(inputImage);

      for (final obj in objects) {
        final objLabels = obj.labels;
        bool match = false;

        if (_subjectType == SubjectType.any && objLabels.isNotEmpty) {
          match = true;
        } else {
          for (final label in objLabels) {
            final text = label.text.toLowerCase();
            if (_subjectType == SubjectType.flower && (text.contains('flower') || text.contains('plant'))) match = true;
            if (_subjectType == SubjectType.animal && (text.contains('animal') || text.contains('cat') || text.contains('dog') || text.contains('bird'))) match = true;
            if (_subjectType == SubjectType.plant && text.contains('plant')) match = true;
            if (_subjectType == SubjectType.food && text.contains('food')) match = true;
            if (_subjectType == SubjectType.vehicle && (text.contains('car') || text.contains('vehicle'))) match = true;
          }
        }

        if (match) {
          subjectCenter = Point(obj.boundingBox.center.dx, obj.boundingBox.center.dy);
          break;
        }
      }

      if (subjectCenter == null && _subjectType == SubjectType.any && labels.isNotEmpty) {
        subjectCenter = Point(w / 2, h / 2);
      }
    }

    if (_logPerformanceEnabled) {
      final mlkitElapsed = DateTime.now().millisecondsSinceEpoch - mlkitStart;
      _totalMlkitMs += mlkitElapsed;
      _mlkitCount++;
    }

    if (subjectCenter == null) return false;

    final thirdX = [w / 3, 2 * w / 3];
    final thirdY = [h / 3, 2 * h / 3];
    final powerPoints = [for (final x in thirdX) for (final y in thirdY) Point(x, y)];

    return _nearPowerPoint(subjectCenter, powerPoints, w, h);
  }

  bool _nearPowerPoint(Point p, List<Point> powerPoints, double w, double h) {
    final threshold = max(w, h) * _tolerance;
    for (final pp in powerPoints) {
      final dist = sqrt(pow(p.x - pp.x, 2) + pow(p.y - pp.y, 2));
      if (dist < threshold) return true;
    }
    final nearVertical = (p.x - w / 3).abs() < threshold || (p.x - 2 * w / 3).abs() < threshold;
    final nearHorizontal = (p.y - h / 3).abs() < threshold || (p.y - 2 * h / 3).abs() < threshold;
    return nearVertical || nearHorizontal;
  }

  void _incrementScanned() {
    if (mounted) setState(() => _scannedCount++);
  }

  void _stopScan() {
    setState(() => _stopRequested = true);
    _performanceTimer?.cancel();
  }

  double get _photosPerSecond {
    if (_scannedCount == 0) return 0;
    final elapsed = (DateTime.now().millisecondsSinceEpoch - _startTime) / 1000;
    return elapsed > 0? _scannedCount / elapsed : 0;
  }

  String get _estimatedTime {
    if (_photosPerSecond == 0 || _scannedCount >= _totalToScan) return '--';
    final remaining = (_totalToScan - _scannedCount) / _photosPerSecond;
    if (remaining < 60) return '${remaining.toStringAsFixed(0)}s';
    return '${(remaining / 60).toStringAsFixed(1)}min';
  }

  Future<void> _calculateSyncDiff() async {
    if (_matchingPhotos.isEmpty) {
      setState(() {
        _toAdd = 0;
        _toRemove = 0;
      });
      return;
    }
    setState(() => _checkingDiff = true);

    try {
      final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
      AssetPathEntity? targetAlbum;
      for (final album in albums) {
        if (album.name == _albumName) {
          targetAlbum = album;
          break;
        }
      }

      if (targetAlbum == null) {
        setState(() {
          _toAdd = _matchingPhotos.length;
          _toRemove = 0;
          _checkingDiff = false;
        });
        return;
      }

      final existingInAlbum = await targetAlbum.getAssetListRange(start: 0, end: 10000);
      final existingIds = existingInAlbum.map((e) => e.id).toSet();
      final newIds = _matchingPhotos.map((e) => e.id).toSet();

      setState(() {
        _toAdd = newIds.difference(existingIds).length;
        _toRemove = existingIds.difference(newIds).length;
        _checkingDiff = false;
      });
    } catch (_) {
      setState(() => _checkingDiff = false);
    }
  }

  Future<AssetPathEntity?> _getOrCreateAlbum() async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    for (final album in albums) {
      if (album.name == _albumName) return album;
    }
    return await PhotoManager.editor.createAlbum(_albumName);
  }

  Future<void> _exportToAlbum() async {
    if (_matchingPhotos.isEmpty) return;
    setState(() => _exporting = true);

    try {
      final targetAlbum = await _getOrCreateAlbum();
      if (targetAlbum == null) throw 'Impossibile creare album';

      final ids = _matchingPhotos.map((e) => e.id).toList();
      for (int i = 0; i < ids.length; i += 50) {
        final batch = ids.sublist(i, min(i + 50, ids.length));
        await PhotoManager.editor.copyAssetToPath(assetIds: batch, pathEntity: targetAlbum);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Esportate ${_matchingPhotos.length} foto in "$_albumName"')),
        );
      }
      _calculateSyncDiff();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore esportazione: $e')),
        );
      }
    }

    if (mounted) setState(() => _exporting = false);
  }

  Future<void> _syncAlbum() async {
    if (_matchingPhotos.isEmpty) return;
    setState(() => _syncing = true);

    try {
      final targetAlbum = await _getOrCreateAlbum();
      if (targetAlbum == null) throw 'Album non trovato';

      final existingInAlbum = await targetAlbum.getAssetListRange(start: 0, end: 10000);
      final existingIds = existingInAlbum.map((e) => e.id).toSet();
      final newIds = _matchingPhotos.map((e) => e.id).toSet();

      final toRemove = existingIds.difference(newIds).toList();
      final toAdd = newIds.difference(existingIds).toList();

      for (int i = 0; i < toRemove.length; i += 50) {
        final batch = toRemove.sublist(i, min(i + 50, toRemove.length));
        await PhotoManager.editor.removeAssetsFromPath(assetIds: batch, pathEntity: targetAlbum);
      }
      for (int i = 0; i < toAdd.length; i += 50) {
        final batch = toAdd.sublist(i, min(i + 50, toAdd.length));
        await PhotoManager.editor.copyAssetToPath(assetIds: batch, pathEntity: targetAlbum);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sincronizzato: +${toAdd.length} aggiunte, -${toRemove.length} rimosse')),
        );
      }
      _calculateSyncDiff();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore sincronizzazione: $e')),
        );
      }
    }

    if (mounted) setState(() => _syncing = false);
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _fromDate?? DateTime.now().subtract(const Duration(days: 30)),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (date!= null) {
      setState(() => _fromDate = date);
      _updateTotalToScan();
      _saveState();
    }
  }

  bool get _busy => _loading || _exporting || _syncing || _checkingDiff || _testing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Foto con Regola dei Terzi'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Icon(
                    _batteryLevel > _batteryThreshold? Icons.battery_full : Icons.battery_alert,
                    color: _batteryLevel > _batteryThreshold? Colors.green : Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  Text('$_batteryLevel%', style: const TextStyle(fontSize: 14)),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: _busy || _performanceLog.isEmpty ||!_logPerformanceEnabled? null : _exportPerformanceLog,
            icon: const Icon(Icons.download),
            tooltip: 'Esporta log performance CSV',
          ),
          IconButton(
            onPressed: _busy? null : _clearSavedResults,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Cancella risultati salvati',
          ),
        ],
      ),
      body: Column(
        children: [
          ExpansionTile(
            title: const Text('Filtri e Impostazioni'),
            initiallyExpanded: false,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    DropdownButtonFormField<SubjectType>(
                      decoration: const InputDecoration(labelText: 'Cerca soggetto'),
                      value: _subjectType,
                      items: SubjectType.values.map((s) => DropdownMenuItem(value: s, child: Text(s.label))).toList(),
                      onChanged: _busy? null : (val) {
                        setState(() => _subjectType = val!);
                        _saveState();
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Ferma se batteria bassa'),
                      subtitle: Text('Soglia: $_batteryThreshold%'),
                      value: _batteryCheckEnabled,
                      onChanged: _busy? null : (val) {
                        setState(() => _batteryCheckEnabled = val);
                        _saveState();
                      },
                    ),
                    if (_batteryCheckEnabled)
                      Column(
                        children: [
                          Text('Soglia batteria: $_batteryThreshold%'),
                          Slider(
                            value: _batteryThreshold.toDouble(),
                            min: 10,
                            max: 50,
                            divisions: 8,
                            label: '$_batteryThreshold%',
                            onChanged: _busy? null : (val) {
                              setState(() => _batteryThreshold = val.round());
                              _saveState();
                            },
                          ),
                        ],
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Registra log performance'),
                      subtitle: Text(_logPerformanceEnabled? 'CSV attivo' : 'Disattivato per risparmiare risorse'),
                      value: _logPerformanceEnabled,
                      onChanged: _busy? null : (val) {
                        setState(() => _logPerformanceEnabled = val);
                        _saveState();
                      },
                    ),
                    DropdownButtonFormField<AssetPathEntity>(
                      decoration: const InputDecoration(labelText: 'Album'),
                      value: _selectedAlbum,
                      items: _albums.map((a) => DropdownMenuItem(value: a, child: Text(a.name))).toList(),
                      onChanged: _busy? null : (val) {
                        setState(() {
                          _selectedAlbum = val;
                          _selectedAlbumId = val?.id;
                        });
                        _updateTotalToScan();
                        _saveState();
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            decoration: const InputDecoration(labelText: 'Max foto'),
                            initialValue: '$_maxPhotos',
                            keyboardType: TextInputType.number,
                            onChanged: _busy? null : (v) {
                              _maxPhotos = int.tryParse(v)?? 500;
                              _updateTotalToScan();
                              _saveState();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            decoration: const InputDecoration(labelText: 'Min Megapixel'),
                            initialValue: '$_minMegapixels',
                            keyboardType: TextInputType.number,
                            onChanged: _busy? null : (v) {
                              _minMegapixels = int.tryParse(v)?? 0;
                              _saveState();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy? null : _pickDate,
                            icon: const Icon(Icons.calendar_today, size: 18),
                            label: Text(_fromDate == null
                               ? 'Da: Tutte le date'
                                : 'Da: ${_fromDate!.day}/${_fromDate!.month}/${_fromDate!.year}'),
                          ),
                        ),
                        if (_fromDate!= null)
                          IconButton(
                            onPressed: _busy? null : () {
                              setState(() => _fromDate = null);
                              _updateTotalToScan();
                              _saveState();
                            },
                            icon: const Icon(Icons.clear),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Tolleranza: ${(_tolerance * 100).toStringAsFixed(0)}%'),
                    Slider(
                      value: _tolerance,
                      min: 0.05,
                      max: 0.25,
                      divisions: 20,
                      label: '${(_tolerance * 100).round()}%',
                      onChanged: _busy? null : (value) {
                        setState(() => _tolerance = value);
                        _saveState();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                if (_totalToScan > 0)
                  Text('Da analizzare: $_totalToScan foto', style: Theme.of(context).textTheme.bodySmall),
                if (_loading)...[
                  LinearProgressIndicator(value: _totalToScan > 0? _scannedCount / _totalToScan : null),
                  const SizedBox(height: 4),
                  Text(
                    'Scansionate: $_scannedCount / $_totalToScan • ${_photosPerSecond.toStringAsFixed(1)} foto/s • ETA: $_estimatedTime',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  if (_performanceSpots.length > 1 && _logPerformanceEnabled)
                    SizedBox(
                      height: 100,
                      child: LineChart(
                        LineChartData(
                          gridData: FlGridData(show: true, drawVerticalLine: false),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 35)),
                            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          ),
                          borderData: FlBorderData(show: true),
                          lineBarsData: [
                            LineChartBarData(
                              spots: _performanceSpots,
                              isCurved: true,
                              color: Colors.blue,
                              barWidth: 2,
                              dotData: FlDotData(show: false),
                              belowBarData: BarAreaData(show: true, color: Colors.blue.withOpacity(0.1)),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: _loading
                     ? ElevatedButton.icon(
                          onPressed: _stopScan,
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700], foregroundColor: Colors.white),
                          icon: const Icon(Icons.stop),
                          label: const Text('Ferma scansione'),
                        )
                      : ElevatedButton.icon(
                          onPressed: _busy? null : _scanGallery,
                          icon: const Icon(Icons.photo_library),
                          label: Text('Scansiona ${_subjectType.label}'),
                        ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy || _testing || _totalToScan == 0? null : _runTestScan,
                    icon: _testing
                       ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.timer),
                    label: Text(_testing? 'Test in corso...' : 'Testa 10 foto'),
                  ),
                ),
                if (_estimateResult.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue[200]!),
                    ),
                    child: Text(
                      _estimateResult,
                      style: TextStyle(fontSize: 13, color: Colors.blue[900]),
                    ),
                  ),
                const SizedBox(height
