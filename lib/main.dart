import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'package:flutter/material.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:uuid/uuid.dart';

void main() {
  runApp(const SurveyApp());
}

class SurveyApp extends StatelessWidget {
  const SurveyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xff0f766e);

    return MaterialApp(
      title: 'VKU Field Survey',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
          surface: const Color(0xfff5f7fb),
        ),
        scaffoldBackgroundColor: const Color(0xfff5f7fb),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xfff5f7fb),
          foregroundColor: Color(0xff10201d),
          elevation: 0,
          centerTitle: false,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          filled: true,
          fillColor: Color(0xfffbfcfe),
        ),
      ),
      home: const SurveyHomePage(),
    );
  }
}

class SurveyHomePage extends StatefulWidget {
  const SurveyHomePage({super.key});

  @override
  State<SurveyHomePage> createState() => _SurveyHomePageState();
}

class _SurveyHomePageState extends State<SurveyHomePage> {
  final _store = OfflineSurveyStore();
  final _uuid = const Uuid();
  final _formKey = GlobalKey<FormState>();
  final _facilityController = TextEditingController();
  final _areaController = TextEditingController();
  final _notesController = TextEditingController();

  StreamSubscription<html.Event>? _onlineSub;
  StreamSubscription<html.Event>? _offlineSub;

  String _condition = 'Good';
  String? _photoDataUrl;
  GpsPoint? _gpsPoint;
  bool _online = html.window.navigator.onLine ?? true;
  bool _busy = false;
  int _draftCount = 0;
  int _queueCount = 0;
  List<SurveyRecord> _drafts = [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _onlineSub = html.window.onOnline.listen((_) {
      setState(() => _online = true);
      _syncQueue();
    });
    _offlineSub = html.window.onOffline.listen((_) {
      setState(() => _online = false);
    });
  }

  Future<void> _bootstrap() async {
    await _store.open();
    await _refreshCounts();
    if (_online) {
      unawaited(_syncQueue());
    }
  }

  @override
  void dispose() {
    _onlineSub?.cancel();
    _offlineSub?.cancel();
    _facilityController.dispose();
    _areaController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _refreshCounts() async {
    final drafts = await _store.getDrafts();
    final queueCount = await _store.countQueue();

    if (!mounted) return;
    setState(() {
      _drafts = drafts;
      _draftCount = drafts.length;
      _queueCount = queueCount;
    });
  }

  Future<void> _capturePhoto() async {
    await _guarded(() async {
      final result = await js_util.promiseToFuture<Object?>(
        js_util.callMethod(html.window, 'eval', [
          'window.CapacitorSurvey.takePhoto()',
        ]),
      );
      final map = Map<String, dynamic>.from(
        js_util.dartify(result) as Map<Object?, Object?>,
      );
      setState(() => _photoDataUrl = map['dataUrl'] as String?);
    });
  }

  Future<void> _captureGps() async {
    await _guarded(() async {
      final result = await js_util.promiseToFuture<Object?>(
        js_util.callMethod(html.window, 'eval', [
          'window.CapacitorSurvey.getPosition()',
        ]),
      );
      final map = Map<String, dynamic>.from(
        js_util.dartify(result) as Map<Object?, Object?>,
      );
      setState(() {
        _gpsPoint = GpsPoint(
          latitude: (map['latitude'] as num).toDouble(),
          longitude: (map['longitude'] as num).toDouble(),
          accuracy: (map['accuracy'] as num?)?.toDouble(),
          source: map['source'] as String? ?? 'unknown',
        );
      });
    });
  }

  Future<void> _saveDraft() async {
    if (!_formKey.currentState!.validate()) return;

    await _guarded(() async {
      final now = DateTime.now().toUtc();
      final record = SurveyRecord(
        id: _uuid.v4(),
        facility: _facilityController.text.trim(),
        area: _areaController.text.trim(),
        condition: _condition,
        notes: _notesController.text.trim(),
        gps: _gpsPoint,
        photoDataUrl: _photoDataUrl,
        createdAt: now,
        updatedAt: now,
      );

      await _store.saveDraft(record);
      await _store.enqueue(record);
      _clearForm();
      await _refreshCounts();
      if (_online) {
        unawaited(_syncQueue());
      }
    });
  }

  Future<void> _syncQueue() async {
    if (!_online || _busy) return;

    await _guarded(() async {
      final queued = await _store.getQueued();

      for (final record in queued) {
        final response = await html.HttpRequest.request(
          '/api/surveys',
          method: 'POST',
          requestHeaders: {'Content-Type': 'application/json'},
          sendData: jsonEncode(record.toJson()),
        );

        if (response.status != 200) {
          throw StateError('Sync failed with HTTP ${response.status}');
        }

        await _store.removeQueued(record.id);
      }

      await _refreshCounts();
    }, showError: false);
  }

  Future<void> _deleteDraft(String id) async {
    await _guarded(() async {
      await _store.deleteDraft(id);
      await _refreshCounts();
    });
  }

  Future<void> _guarded(
    Future<void> Function() action, {
    bool showError = true,
  }) async {
    if (mounted) {
      setState(() => _busy = true);
    }
    try {
      await action();
    } catch (error) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _clearForm() {
    _facilityController.clear();
    _areaController.clear();
    _notesController.clear();
    setState(() {
      _condition = 'Good';
      _photoDataUrl = null;
      _gpsPoint = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xff0f766e),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'VKU',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'VKU Field Survey',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 2),
                Text(
                  'Offline facility inspection',
                  style: TextStyle(
                    color: Color(0xff64748b),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton.filledTonal(
              tooltip: 'Sync now',
              onPressed: _online && !_busy ? _syncQueue : null,
              icon: const Icon(Icons.sync),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _OverviewHeader(
                  online: _online,
                  draftCount: _draftCount,
                  queueCount: _queueCount,
                  busy: _busy,
                  onSync: _online && !_busy ? _syncQueue : null,
                ),
                const SizedBox(height: 16),
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: form),
                      const SizedBox(width: 16),
                      Expanded(flex: 2, child: drafts),
                    ],
                  )
                else ...[
                  form,
                  const SizedBox(height: 16),
                  drafts,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget get form {
    return _SurveyForm(
      formKey: _formKey,
      facilityController: _facilityController,
      areaController: _areaController,
      notesController: _notesController,
      condition: _condition,
      photoDataUrl: _photoDataUrl,
      gpsPoint: _gpsPoint,
      busy: _busy,
      onConditionChanged: (value) {
        if (value != null) {
          setState(() => _condition = value);
        }
      },
      onCapturePhoto: _capturePhoto,
      onCaptureGps: _captureGps,
      onSave: _saveDraft,
    );
  }

  Widget get drafts {
    return _DraftList(
      drafts: _drafts,
      onDelete: _deleteDraft,
    );
  }
}

class _OverviewHeader extends StatelessWidget {
  const _OverviewHeader({
    required this.online,
    required this.draftCount,
    required this.queueCount,
    required this.busy,
    required this.onSync,
  });

  final bool online;
  final int draftCount;
  final int queueCount;
  final bool busy;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    return _SurfacePanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Campus inspection workspace',
                      style: TextStyle(
                        color: Color(0xff10201d),
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Capture facility conditions, photos, and GPS points even when the network drops.',
                      style: TextStyle(
                        color: Color(0xff64748b),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: onSync,
                icon: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_sync),
                label: const Text('Sync now'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final cards = [
                _MetricTile(
                  icon: online ? Icons.wifi : Icons.wifi_off,
                  label: 'Connection',
                  value: online ? 'Online' : 'Offline',
                  color: online
                      ? const Color(0xff0f766e)
                      : const Color(0xffdc2626),
                ),
                _MetricTile(
                  icon: Icons.assignment_outlined,
                  label: 'Local drafts',
                  value: '$draftCount',
                  color: const Color(0xff2563eb),
                ),
                _MetricTile(
                  icon: Icons.outbox_outlined,
                  label: 'Sync queue',
                  value: '$queueCount',
                  color: const Color(0xff7c3aed),
                ),
              ];

              if (compact) {
                return Column(
                  children: [
                    for (final card in cards) ...[
                      card,
                      if (card != cards.last) const SizedBox(height: 10),
                    ],
                  ],
                );
              }

              return Row(
                children: [
                  for (final card in cards) ...[
                    Expanded(child: card),
                    if (card != cards.last) const SizedBox(width: 12),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 86,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfff8fafc),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe2e8f0)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xff64748b),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xff10201d),
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfacePanel extends StatelessWidget {
  const _SurfacePanel({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xffe1e7ef)),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0f0f172a),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: const Color(0xffe7f6f2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: const Color(0xff0f766e)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xff10201d),
                    ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xff64748b),
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xfff8fafc),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe2e8f0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xff0f766e)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xff334155),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SurveyForm extends StatelessWidget {
  const _SurveyForm({
    required this.formKey,
    required this.facilityController,
    required this.areaController,
    required this.notesController,
    required this.condition,
    required this.photoDataUrl,
    required this.gpsPoint,
    required this.busy,
    required this.onConditionChanged,
    required this.onCapturePhoto,
    required this.onCaptureGps,
    required this.onSave,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController facilityController;
  final TextEditingController areaController;
  final TextEditingController notesController;
  final String condition;
  final String? photoDataUrl;
  final GpsPoint? gpsPoint;
  final bool busy;
  final ValueChanged<String?> onConditionChanged;
  final VoidCallback onCapturePhoto;
  final VoidCallback onCaptureGps;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return _SurfacePanel(
      padding: const EdgeInsets.all(18),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionTitle(
              icon: Icons.assignment_add,
              title: 'Inspection form',
              subtitle: 'Record one facility issue or routine inspection item.',
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: facilityController,
              decoration: const InputDecoration(
                labelText: 'Facility',
                prefixIcon: Icon(Icons.apartment),
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: areaController,
              decoration: const InputDecoration(
                labelText: 'Area / Room',
                prefixIcon: Icon(Icons.place),
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: condition,
              decoration: const InputDecoration(
                labelText: 'Condition',
                prefixIcon: Icon(Icons.fact_check),
              ),
              items: const [
                DropdownMenuItem(value: 'Good', child: Text('Good')),
                DropdownMenuItem(
                  value: 'Needs repair',
                  child: Text('Needs repair'),
                ),
                DropdownMenuItem(value: 'Unsafe', child: Text('Unsafe')),
              ],
              onChanged: onConditionChanged,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: notesController,
              minLines: 4,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Notes',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.notes),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onCapturePhoto,
                  icon: const Icon(Icons.photo_camera),
                  label: Text(photoDataUrl == null ? 'Add photo' : 'Replace photo'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onCaptureGps,
                  icon: const Icon(Icons.my_location),
                  label: Text(gpsPoint == null ? 'Get GPS' : 'Update GPS'),
                ),
              ],
            ),
            if (photoDataUrl != null) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  children: [
                    Image.network(
                      photoDataUrl!,
                      height: 210,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                    Positioned(
                      left: 10,
                      top: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'Photo attached',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (gpsPoint != null) ...[
              const SizedBox(height: 12),
              _InfoPill(
                icon: Icons.location_on,
                label: '${gpsPoint!.latitude.toStringAsFixed(6)}, '
                    '${gpsPoint!.longitude.toStringAsFixed(6)}'
                    '${gpsPoint!.accuracy == null ? '' : ' +/- ${gpsPoint!.accuracy!.toStringAsFixed(0)}m'}',
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: busy ? null : onSave,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text('Save offline draft'),
            ),
          ],
        ),
      ),
    );
  }

  static String? _required(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Required';
    }
    return null;
  }
}

class _DraftList extends StatelessWidget {
  const _DraftList({
    required this.drafts,
    required this.onDelete,
  });

  final List<SurveyRecord> drafts;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    return _SurfacePanel(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle(
            icon: Icons.inventory_2_outlined,
            title: 'Saved drafts',
            subtitle: 'Local records stay here until they sync successfully.',
          ),
          const SizedBox(height: 14),
          if (drafts.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xfff8fafc),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xffe2e8f0)),
              ),
              child: const Column(
                children: [
                  Icon(
                    Icons.assignment_late_outlined,
                    color: Color(0xff94a3b8),
                    size: 42,
                  ),
                  SizedBox(height: 10),
                  Text(
                    'No local drafts yet',
                    style: TextStyle(
                      color: Color(0xff334155),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Save an inspection to see it in this queue.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xff64748b)),
                  ),
                ],
              ),
            )
          else
            ...drafts.map((draft) {
              final color = _conditionColor(draft.condition);

              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: const Color(0xfffbfcfe),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xffe2e8f0)),
                ),
                child: ListTile(
                  minVerticalPadding: 14,
                  leading: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(_conditionIcon(draft.condition), color: color),
                  ),
                  title: Text(
                    draft.facility,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${draft.area} - ${draft.condition}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _MiniBadge(
                              icon: Icons.schedule,
                              label: _formatDate(draft.createdAt),
                            ),
                            if (draft.photoDataUrl != null)
                              const _MiniBadge(
                                icon: Icons.photo,
                                label: 'Photo',
                              ),
                            if (draft.gps != null)
                              const _MiniBadge(
                                icon: Icons.location_on,
                                label: 'GPS',
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete draft',
                    onPressed: () => onDelete(draft.id),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  static Color _conditionColor(String condition) {
    return switch (condition) {
      'Unsafe' => const Color(0xffdc2626),
      'Needs repair' => const Color(0xffd97706),
      _ => const Color(0xff0f766e),
    };
  }

  static IconData _conditionIcon(String condition) {
    return switch (condition) {
      'Unsafe' => Icons.warning_amber,
      'Needs repair' => Icons.build_outlined,
      _ => Icons.check_circle_outline,
    };
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.day}/${local.month} $hour:$minute';
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xfff1f5f9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xff64748b)),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xff475569),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class OfflineSurveyStore {
  static const _dbName = 'vku_field_survey';
  static const _draftStore = 'drafts';
  static const _queueStore = 'sync_queue';

  Database? _db;

  Future<void> open() async {
    _db ??= await idbFactoryBrowser.open(
      _dbName,
      version: 1,
      onUpgradeNeeded: (event) {
        final db = event.database;
        if (!db.objectStoreNames.contains(_draftStore)) {
          db.createObjectStore(_draftStore, keyPath: 'id');
        }
        if (!db.objectStoreNames.contains(_queueStore)) {
          db.createObjectStore(_queueStore, keyPath: 'id');
        }
      },
    );
  }

  Future<void> saveDraft(SurveyRecord record) async {
    await _put(_draftStore, record.toJson());
  }

  Future<void> enqueue(SurveyRecord record) async {
    await _put(_queueStore, record.toJson());
  }

  Future<List<SurveyRecord>> getDrafts() async {
    return _getAll(_draftStore);
  }

  Future<List<SurveyRecord>> getQueued() async {
    return _getAll(_queueStore);
  }

  Future<int> countQueue() async {
    final db = _requireDb();
    final txn = db.transaction(_queueStore, idbModeReadOnly);
    final store = txn.objectStore(_queueStore);
    final count = await store.count();
    await txn.completed;
    return count;
  }

  Future<void> deleteDraft(String id) async {
    await _delete(_draftStore, id);
  }

  Future<void> removeQueued(String id) async {
    await _delete(_queueStore, id);
  }

  Future<void> _put(String storeName, Map<String, dynamic> value) async {
    final db = _requireDb();
    final txn = db.transaction(storeName, idbModeReadWrite);
    txn.objectStore(storeName).put(value);
    await txn.completed;
  }

  Future<void> _delete(String storeName, String id) async {
    final db = _requireDb();
    final txn = db.transaction(storeName, idbModeReadWrite);
    txn.objectStore(storeName).delete(id);
    await txn.completed;
  }

  Future<List<SurveyRecord>> _getAll(String storeName) async {
    final db = _requireDb();
    final txn = db.transaction(storeName, idbModeReadOnly);
    final objects = await txn.objectStore(storeName).getAll();
    await txn.completed;

    return objects
        .map((item) => SurveyRecord.fromJson(Map<String, dynamic>.from(item as Map)))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('Database has not been opened.');
    }
    return db;
  }
}

class SurveyRecord {
  const SurveyRecord({
    required this.id,
    required this.facility,
    required this.area,
    required this.condition,
    required this.notes,
    required this.gps,
    required this.photoDataUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String facility;
  final String area;
  final String condition;
  final String notes;
  final GpsPoint? gps;
  final String? photoDataUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'facility': facility,
      'area': area,
      'condition': condition,
      'notes': notes,
      'gps': gps?.toJson(),
      'photoDataUrl': photoDataUrl,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory SurveyRecord.fromJson(Map<String, dynamic> json) {
    return SurveyRecord(
      id: json['id'] as String,
      facility: json['facility'] as String,
      area: json['area'] as String,
      condition: json['condition'] as String,
      notes: json['notes'] as String? ?? '',
      gps: json['gps'] == null
          ? null
          : GpsPoint.fromJson(Map<String, dynamic>.from(json['gps'] as Map)),
      photoDataUrl: json['photoDataUrl'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

class GpsPoint {
  const GpsPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.source,
  });

  final double latitude;
  final double longitude;
  final double? accuracy;
  final String source;

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'source': source,
    };
  }

  factory GpsPoint.fromJson(Map<String, dynamic> json) {
    return GpsPoint(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      source: json['source'] as String? ?? 'unknown',
    );
  }
}
