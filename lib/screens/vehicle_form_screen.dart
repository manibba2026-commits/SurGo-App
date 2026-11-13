import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/db_models.dart';
import '../repositories/backend_rows.dart';
import '../repositories/repository_failure.dart';
import '../repositories/vehicle_repository.dart';
import '../services/money.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/common.dart';
import '../widgets/vehicle_photo.dart';

/// One form for both "Add vehicle" and "Edit vehicle".
///
/// The owner screen pushes this screen with [vehicle] null to create and with a
/// [VehicleRecord] to edit. It never writes directly: the save goes through
/// [AppState.saveOwnedVehicle], which chooses the seeded repository or the
/// hosted RPC and refreshes the fleet and rental catalogue.
class VehicleFormScreen extends StatefulWidget {
  final VehicleRecord? vehicle;
  const VehicleFormScreen({super.key, this.vehicle});

  @override
  State<VehicleFormScreen> createState() => _VehicleFormScreenState();
}

class _VehicleFormScreenState extends State<VehicleFormScreen> {
  static const int _maxPhotos = 6;
  static const int _maxPhotoBytes = 10 * 1024 * 1024;

  late final TextEditingController _name;
  late final TextEditingController _plate;
  late final TextEditingController _price;
  late final TextEditingController _make;
  late final TextEditingController _model;
  late final TextEditingController _year;
  late final TextEditingController _color;

  late String _category;
  late String _type;
  late bool _listed;

  final List<VehiclePhotoUpload> _newPhotos = [];
  final Set<String> _removedPaths = {};

  SbButtonFeedback _feedback = SbButtonFeedback.idle;
  String? _error;

  bool get _editing => widget.vehicle != null;

  List<String> get _existingPhotos => [
    for (final path in widget.vehicle?.photoPaths ?? const <String>[])
      if (!_removedPaths.contains(path)) path,
  ];

  int get _photoCount => _existingPhotos.length + _newPhotos.length;

  @override
  void initState() {
    super.initState();
    final vehicle = widget.vehicle;
    _name = TextEditingController(text: vehicle?.name ?? '');
    _plate = TextEditingController(text: vehicle?.plateNumber ?? '');
    _price = TextEditingController(
      text: vehicle == null ? '' : _pesoText(vehicle.pricePerDayCentavos),
    );
    _make = TextEditingController(text: vehicle?.make ?? '');
    _model = TextEditingController(text: vehicle?.model ?? '');
    _year = TextEditingController(text: vehicle?.modelYear?.toString() ?? '');
    _color = TextEditingController(text: vehicle?.color ?? '');

    final categories = OwnedVehicle.categories;
    _category = vehicle != null && categories.contains(vehicle.category)
        ? vehicle.category
        : categories.first;
    final types = OwnedVehicle.typesByCategory[_category]!;
    _type = vehicle != null && types.contains(vehicle.vehicleType)
        ? vehicle.vehicleType
        : types.first;
    _listed = vehicle == null || vehicle.isListed;
  }

  @override
  void dispose() {
    _name.dispose();
    _plate.dispose();
    _price.dispose();
    _make.dispose();
    _model.dispose();
    _year.dispose();
    _color.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final types = OwnedVehicle.typesByCategory[_category]!;
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit vehicle' : 'Add vehicle')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
        children: [
          _label('Category'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final category in OwnedVehicle.categories)
                SbChip(
                  category,
                  active: _category == category,
                  onTap: () => setState(() {
                    _category = category;
                    _type = OwnedVehicle.typesByCategory[category]!.first;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _label('Type'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final type in types)
                SbChip(
                  type,
                  active: _type == type,
                  onTap: () => setState(() => _type = type),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SbEditableField(
            label: 'Vehicle name',
            controller: _name,
            hintText: 'e.g. Honda Click 125i',
          ),
          const SizedBox(height: 10),
          SbEditableField(
            label: 'Plate number',
            controller: _plate,
            hintText: 'e.g. NGD 4821',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SbEditableField(
                  label: 'Make',
                  controller: _make,
                  hintText: 'e.g. Honda',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SbEditableField(
                  label: 'Model',
                  controller: _model,
                  hintText: 'e.g. Click',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SbEditableField(
                  label: 'Model year',
                  controller: _year,
                  keyboardType: TextInputType.number,
                  hintText: 'e.g. 2023',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SbEditableField(
                  label: 'Color',
                  controller: _color,
                  hintText: 'e.g. Black',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SbEditableField(
            label: 'Price per day (₱)',
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            hintText: 'e.g. 500',
          ),
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _listed,
            onChanged: (value) => setState(() => _listed = value),
            title: const Text(
              'List in the rental catalogue',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            subtitle: const Text(
              'Unlisted vehicles stay in your fleet but renters cannot see them.',
              style: TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
            activeColor: AppColors.primary,
          ),
          const SizedBox(height: 12),
          _label('Photos'),
          const SizedBox(height: 4),
          const Text(
            'Up to 6 JPG, PNG or WebP photos. The first photo is the cover.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final path in _existingPhotos)
                _photoTile(
                  child: VehiclePhoto(storagePath: path, width: 84, height: 70),
                  onRemove: () => setState(() => _removedPaths.add(path)),
                ),
              for (final photo in _newPhotos)
                _photoTile(
                  child: Image.memory(
                    photo.bytes,
                    width: 84,
                    height: 70,
                    fit: BoxFit.cover,
                  ),
                  onRemove: () => setState(() => _newPhotos.remove(photo)),
                ),
              if (_photoCount < _maxPhotos) _addPhotoTile(),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _errorBanner(_error!),
          ],
          const SizedBox(height: 22),
          SbPrimaryButton(
            label: _editing ? 'Save changes' : 'Add Vehicle',
            icon: Icons.check,
            feedback: _feedback,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontWeight: FontWeight.w700,
      fontSize: 12,
      color: AppColors.muted2,
    ),
  );

  Widget _photoTile({required Widget child, required VoidCallback onRemove}) {
    return SizedBox(
      width: 84,
      height: 70,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(SbRadius.sm),
              child: child,
            ),
          ),
          Positioned(
            top: -7,
            right: -7,
            child: Material(
              color: AppColors.panel2,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 14, color: AppColors.danger),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addPhotoTile() {
    return InkWell(
      onTap: _pickPhotos,
      borderRadius: BorderRadius.circular(SbRadius.sm),
      child: Container(
        width: 84,
        height: 70,
        decoration: BoxDecoration(
          color: AppColors.panel2,
          borderRadius: BorderRadius.circular(SbRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined, size: 20, color: AppColors.muted),
            SizedBox(height: 4),
            Text(
              'Add',
              style: TextStyle(color: AppColors.muted, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(SbRadius.sm),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 17, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: AppColors.danger,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickPhotos() async {
    final remaining = _maxPhotos - _photoCount;
    if (remaining <= 0) {
      setState(() => _error = 'A vehicle can have at most 6 photos.');
      return;
    }

    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        dialogTitle: 'Choose vehicle photos',
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
        compressionQuality: 85,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'The photo picker could not open. Try again.');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    var added = 0;
    for (final file in picked) {
      if (added >= remaining) break;
      try {
        final length = await file.length();
        if (length == null || length < 1) continue;
        if (length > _maxPhotoBytes) {
          _error = 'Each photo must be 10 MB or smaller.';
          continue;
        }
        final bytes = await file.readAsBytes();
        final upload = VehiclePhotoUpload(fileName: file.name, bytes: bytes);
        // Throws before the form keeps a type the bucket would reject.
        upload.contentType;
        _newPhotos.add(upload);
        added++;
      } on RepositoryFailure catch (failure) {
        _error = failure.message;
      } catch (_) {
        _error = '${file.name} could not be read.';
      }
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _submit() async {
    if (_feedback == SbButtonFeedback.loading) return;

    final name = _name.text.trim();
    final plate = _plate.text.trim();
    final price = Money.tryParsePesos(_price.text);
    final yearText = _year.text.trim();
    final year = yearText.isEmpty ? null : int.tryParse(yearText);

    String? error;
    if (name.isEmpty) {
      error = 'Enter the vehicle name.';
    } else if (plate.isEmpty) {
      error = 'Enter the plate number.';
    } else if (price == null || price <= 0) {
      error = 'Enter a daily price greater than zero.';
    } else if (yearText.isNotEmpty &&
        (year == null || year < 1950 || year > 2100)) {
      error = 'Enter a model year between 1950 and 2100.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    setState(() {
      _feedback = SbButtonFeedback.loading;
      _error = null;
    });

    try {
      await AppState.instance.saveOwnedVehicle(
        vehicleId: widget.vehicle?.id,
        draft: VehicleDraft(
          name: name,
          vehicleType: _type,
          category: _category,
          plateNumber: plate,
          pricePerDayCentavos: price!,
          make: _clean(_make.text),
          model: _clean(_model.text),
          modelYear: year,
          color: _clean(_color.text),
          listed: _listed,
        ),
        photos: _newPhotos,
        removePhotoPaths: _removedPaths.toList(),
      );
      if (!mounted) return;
      Navigator.pop(context);
    } on RepositoryFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _feedback = SbButtonFeedback.idle;
        _error = failure.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _feedback = SbButtonFeedback.idle;
        _error = 'The vehicle could not be saved.';
      });
    }
  }

  static String _pesoText(int centavos) =>
      Money.format(centavos, symbol: false).replaceAll(',', '');

  static String? _clean(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
