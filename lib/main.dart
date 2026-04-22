import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

void main() => runApp(const MaterialApp(home: TerziApp()));

class TerziApp extends StatefulWidget {
  const TerziApp({super.key});

  @override
  State<TerziApp> createState() => _TerziAppState();
}

class _TerziAppState extends State<TerziApp> {
  List<AssetEntity> _matchingPhotos = [];
  bool _loading = false;
  bool _exporting = false;
  bool _syncing = false;
  double _tolerance = 0.12;
  bool _useFaceDetection = true; // nuovo toggle
  static const String _albumName = 'Regola dei Terzi';

  int _toAdd = 0;
  int _toRemove = 0;
  bool _checkingDiff = false;

  Future<void> _scanGallery() async {
    setState(() {
      _loading = true;
      _matchingPhotos.clear();
      _toAdd = 0;
      _toRemove = 0;
    });

    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Serve il permesso per accedere alla galleria')),
        );
      }
      return;
    }

    final albums = await PhotoManager.getAssetPathList(type: RequestType.image);
    if (albums.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final allPhotos = await albums[0].getAssetListRange(start: 0, end: 500);

    FaceDetector? faceDetector;
    if (_useFaceDetection) {
      faceDetector = FaceDetector(
        options: FaceDetectorOptions(performanceMode: FaceDetectorMode.fast),
      );
    }

    for (final asset in allPhotos) {
      final file = await asset.file;
      if (file == null) continue;

      final passesRule = await _checkRuleOfThirds(file, faceDetector);
      if (passesRule) {
        _matchingPhotos.add(asset);
        if (mounted) setState(() {});
      }
    }

    await faceDetector?.close();
    if (mounted) {
      setState(() => _loading = false);
      _calculateSyncDiff();
    }
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
      await PhotoManager.editor.copyAssetToPath(assetIds: ids, pathEntity: targetAlbum);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Esportate ${_matchingPhotos.length} foto in "$_albumName"')),
        );
      }
      _calculateSyncDiff();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore durante l\'esportazione: $e')),
        );
      }
    }

    if (mounted) setState(() => _exporting = false);
  }

  Future<void> _syncAlbum() async {
    if (_matchingPhotos.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Prima fai una scansione')),
        );
      }
      return;
    }
    setState(() => _syncing = true);

    try {
      final targetAlbum = await _getOrCreateAlbum();
      if (targetAlbum == null) throw 'Album non trovato';

      final existingInAlbum = await targetAlbum.getAssetListRange(start: 0, end: 10000);
      final existingIds = existingInAlbum.map((e) => e.id).toSet();
      final newIds = _matchingPhotos.map((e) => e.id).toSet();

      final toRemove = existingIds.difference(newIds).toList();
      if (toRemove.isNotEmpty) {
        await PhotoManager.editor.removeAssetsFromPath(assetIds: toRemove, pathEntity: targetAlbum);
      }

      final toAdd = newIds.difference(existingIds).toList();
      if (toAdd.isNotEmpty) {
        await PhotoManager.editor.copyAssetToPath(assetIds: toAdd, pathEntity: targetAlbum);
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

  Future<bool> _checkRuleOfThirds(File file, FaceDetector? detector) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return false;

    final w = image.width.toDouble();
    final h = image.height.toDouble();

    // Se il toggle è attivo, prova prima con i volti
    if (detector!= null) {
      final inputImage = InputImage.fromFile(file);
      final faces = await detector.processImage(inputImage);

      if (faces.isNotEmpty) {
        final thirdX = [w / 3, 2 * w / 3];
        final thirdY = [h / 3, 2 * h / 3];
        final powerPoints = [
          for (final x in thirdX) for (final y in thirdY) Point(x, y)
        ];

        for (final face in faces) {
          final center = Point(
            face.boundingBox.center.dx,
            face.boundingBox.center.dy,
          );
          if (_nearPowerPoint(center, powerPoints, w, h)) return true;
        }
        return false; // Se ci sono volti ma nessuno è sui terzi, scarta
      }
    }

    // Fallback: regola anti-centro per paesaggi/oggetti
    final center = Point(w / 2, h / 2);
    return!_isTooCentered(center, w, h);
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

  bool _isTooCentered(Point p, double w, double h) {
    // Zona centrale del 20%. Se il soggetto è qui, non rispetta i terzi
    final centerZone = Rect.fromCenter(
      center: Offset(w / 2, h / 2),
      width: w * 0.2,
      height: h * 0.2,
    );
    return centerZone.contains(Offset(p.x.toDouble(), p.y.toDouble()));
  }

  Future<Widget> _assetThumb(AssetEntity asset) async {
    final thumb = await asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));
    return thumb!= null
? Image.memory(thumb, fit: BoxFit.cover)
        : const SizedBox();
  }

  void _openFullScreen(AssetEntity asset) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullScreenImage(
          asset: asset,
          tolerance: _tolerance,
          useFaceDetection: _useFaceDetection,
        ),
      ),
    );
  }

  bool get _busy => _loading || _exporting || _syncing || _checkingDiff;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Foto con Regola dei Terzi')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Toggle volti
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Usa rilevamento volti'),
                  subtitle: Text(_useFaceDetection
                 ? 'Ritratti: cerca volti sui terzi'
                      : 'Paesaggi: evita solo il centro'),
                  value: _useFaceDetection,
                  onChanged: _busy
               ? null
                      : (val) {
                          setState(() => _useFaceDetection = val);
                          _calculateSyncDiff();
                        },
                ),
                Text(
                  'Tolleranza: ${(_tolerance * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Slider(
                  value: _tolerance,
                  min: 0.05,
                  max: 0.25,
                  divisions: 20,
                  label: '${(_tolerance * 100).round()}%',
                  onChanged: _busy
               ? null
                      : (value) {
                          setState(() => _tolerance = value);
                          _calculateSyncDiff();
                        },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Severa', style: Theme.of(context).textTheme.bodySmall),
                    Text('Permissiva', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _busy? null : _scanGallery,
                    icon: _loading
                 ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_library),
                    label: Text(_loading? 'Scansione...' : 'Scansiona Galleria'),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _busy || _matchingPhotos.isEmpty? null : _exportToAlbum,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green[700],
                              foregroundColor: Colors.white,
                            ),
                            icon: _exporting
                         ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.create_new_folder),
                            label: Text(_exporting? 'Esporto...' : 'Esporta'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _busy || _matchingPhotos.isEmpty? null : _syncAlbum,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue[700],
                              foregroundColor: Colors.white,
                            ),
                            icon: _syncing
                         ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.sync),
                            label: Text(_syncing? 'Sincronizzo...' : 'Sincronizza album'),
                          ),
                          const SizedBox(height: 4),
                          if (_checkingDiff)
                            const Text('Calcolo...', style: TextStyle(fontSize: 12))
                          else if (_matchingPhotos.isNotEmpty)
                            Text(
                              '+$_toAdd -$_toRemove',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[700],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text('Trovate: ${_matchingPhotos.length} foto'),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: _matchingPhotos.length,
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => _openFullScreen(_matchingPhotos[i]),
                child: FutureBuilder<Widget>(
                  future: _assetThumb(_matchingPhotos[i]),
                  builder: (_, snap) => snap.data?? Container(color: Colors.grey[300]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FullScreenImage extends StatefulWidget {
  final AssetEntity asset;
  final double tolerance;
  final bool useFaceDetection;
  const FullScreenImage({
    super.key,
    required this.asset,
    required this.tolerance,
    required this.useFaceDetection,
  });

  @override
  State<FullScreenImage> createState() => _FullScreenImageState();
}

class _FullScreenImageState extends State<FullScreenImage> {
  File? _file;
  List<Rect> _faceRects = [];
  Size? _imageSize;

  @override
  void initState() {
    super.initState();
    _loadImageAndFaces();
  }

  Future<void> _loadImageAndFaces() async {
    final file = await widget.asset.file;
    if (file == null) return;

    List<Rect> faces = [];
    if (widget.useFaceDetection) {
      final detector = FaceDetector(options: FaceDetectorOptions());
      final detected = await detector.processImage(InputImage.fromFile(file));
      await detector.close();
      faces = detected.map((f) => f.boundingBox).toList();
    }

    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);

    if (mounted) {
      setState(() {
        _file = file;
        _faceRects = faces;
        _imageSize = image!= null? Size(image.width.toDouble(), image.height.toDouble()) : null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Tolleranza ${_tolerancePercent(widget.tolerance)}'),
      ),
      body: _file == null
   ? const Center(child: CircularProgressIndicator())
          : Center(
              child: InteractiveViewer(
                child: Stack(
                  children: [
                    Image.file(_file!),
                    if (_imageSize!= null)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: ThirdsGridPainter(
                            faceRects: _faceRects,
                            imageSize: _imageSize!,
                            tolerance: widget.tolerance,
                            showFaces: widget.useFaceDetection,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  String _tolerancePercent(double t) => '${(t * 100).round()}%';
}

class ThirdsGridPainter extends CustomPainter {
  final List<Rect> faceRects;
  final Size imageSize;
  final double tolerance;
  final bool showFaces;

  ThirdsGridPainter({
    required this.faceRects,
    required this.imageSize,
    required this.tolerance,
    required this.showFaces,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    final gridPaint = Paint()
..color = Colors.white.withOpacity(0.8)
..strokeWidth = 1.5
..style = PaintingStyle.stroke;

    for (int i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(size.width * i / 3, 0),
        Offset(size.width * i / 3, size.height),
        gridPaint,
      );
      canvas.drawLine(
        Offset(0, size.height * i / 3),
        Offset(size.width, size.height * i / 3),
        gridPaint,
      );
    }

    final pointPaint = Paint()..color = Colors.yellow.withOpacity(0.9);
    final radius = max(size.width, size.height) * tolerance * 0.5;
    for (int i = 1; i < 3; i++) {
      for (int j = 1; j < 3; j++) {
        canvas.drawCircle(
          Offset(size.width * i / 3, size.height * j / 3),
          radius,
          pointPaint,
        );
      }
    }

    if (showFaces) {
      final facePaint = Paint()
..color = Colors.cyan
..strokeWidth = 2.5
..style = PaintingStyle.stroke;

      for (final rect in faceRects) {
        final scaledRect = Rect.fromLTRB(
          rect.left * scaleX,
          rect.top * scaleY,
          rect.right * scaleX,
          rect.bottom * scaleY,
        );
        canvas.drawRect(scaledRect, facePaint);
        canvas.drawCircle(scaledRect.center, 6, Paint()..color = Colors.cyan);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
