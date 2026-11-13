import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// One private vehicle photo rendered through a short-lived signed URL.
///
/// The seeded build has no storage bucket, so a failed/unsupported URL falls
/// back to the same vehicle placeholder the cards used before photos existed.
class VehiclePhoto extends StatefulWidget {
  final String storagePath;
  final double width;
  final double height;
  final BoxFit fit;
  final BorderRadius borderRadius;

  const VehiclePhoto({
    super.key,
    required this.storagePath,
    this.width = 46,
    this.height = 46,
    this.fit = BoxFit.cover,
    this.borderRadius = const BorderRadius.all(Radius.circular(SbRadius.sm)),
  });

  @override
  State<VehiclePhoto> createState() => _VehiclePhotoState();
}

class _VehiclePhotoState extends State<VehiclePhoto> {
  Future<String>? _url;

  @override
  void initState() {
    super.initState();
    _url = _load();
  }

  @override
  void didUpdateWidget(covariant VehiclePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storagePath != widget.storagePath) {
      _url = _load();
    }
  }

  Future<String> _load() async {
    try {
      return await AppState.instance.repositories.vehicles.signedPhotoUrl(
        widget.storagePath,
      );
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: FutureBuilder<String>(
          future: _url,
          builder: (context, snapshot) {
            final url = snapshot.data;
            if (url == null || url.isEmpty) return _placeholder();
            return Image.network(
              url,
              fit: widget.fit,
              errorBuilder: (_, __, ___) => _placeholder(),
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : _placeholder(),
            );
          },
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
    color: AppColors.panel2,
    alignment: Alignment.center,
    child: const Icon(
      Icons.directions_car_outlined,
      size: 20,
      color: AppColors.muted2,
    ),
  );
}
