import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../auth/auth_state.dart';
import '../models/auth_models.dart';
import '../widgets/common_widgets.dart';

/// Tech Team layout control for one apartment: rename and drag-reorder
/// rooms, then drill into a room to rename/reorder/move its devices.
/// Renaming/reordering here is what the resident's dashboard actually
/// renders — Room.sort_order / ApartmentDevice.sort_order /name drive the
/// dynamic, backend-generated dashboard directly, no separate "layout"
/// data model needed.
class RoomDeviceLayoutScreen extends StatefulWidget {
  final AuthState authState;
  final int    apartmentId;
  final String apartmentName;
  const RoomDeviceLayoutScreen({
    super.key, required this.authState, required this.apartmentId, required this.apartmentName,
  });

  @override
  State<RoomDeviceLayoutScreen> createState() => _RoomDeviceLayoutScreenState();
}

class _RoomDeviceLayoutScreenState extends State<RoomDeviceLayoutScreen> {
  bool _loading = true;
  List<ManagedRoom> _rooms = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rooms = await widget.authState.fetchApartmentRooms(widget.apartmentId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rooms = rooms ?? [];
    });
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final reordered = List<ManagedRoom>.of(_rooms);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    setState(() => _rooms = reordered);
    await widget.authState.reorderRooms(widget.apartmentId, reordered.map((r) => r.id).toList());
  }

  Future<void> _renameRoom(ManagedRoom room) async {
    final name = await _promptText(context, title: 'Rename Room', initial: room.name);
    if (name == null || name.trim().isEmpty || name.trim() == room.name) return;
    final ok = await widget.authState.renameRoom(widget.apartmentId, room.id, name.trim());
    if (!mounted) return;
    if (ok) {
      AppToast.show(context, 'Renamed to "${name.trim()}"');
      _load();
    } else {
      AppToast.show(context, 'Could not rename room', error: true);
    }
  }

  Future<void> _deleteRoom(ManagedRoom room) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Delete "${room.name}"?', style: AppText.h3, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            room.deviceCount > 0
                ? '${room.deviceCount} device(s) in this room will become unassigned, not deleted.'
                : 'This room has no devices.',
            style: AppText.bodySm, textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: PrimaryButton(label: 'Cancel', color: C.textSec,
                onTap: () => Navigator.pop(sheetContext, false))),
            const SizedBox(width: 12),
            Expanded(child: PrimaryButton(label: 'Delete', color: C.red,
                onTap: () => Navigator.pop(sheetContext, true))),
          ]),
        ]),
      ),
    );
    if (confirmed != true) return;
    final ok = await widget.authState.deleteRoom(widget.apartmentId, room.id);
    if (!mounted) return;
    if (ok) {
      AppToast.show(context, 'Room deleted');
      _load();
    } else {
      AppToast.show(context, 'Could not delete room', error: true);
    }
  }

  Future<void> _addRoom() async {
    final name = await _promptText(context, title: 'Add Room', hint: 'Office');
    if (name == null || name.trim().isEmpty) return;
    final error = await widget.authState.createRoom(widget.apartmentId, name.trim());
    if (!mounted) return;
    if (error == null) {
      AppToast.show(context, 'Room added');
      _load();
    } else {
      AppToast.show(context, error, error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    appBar: AppBar(
      backgroundColor: C.surface,
      title: Text('Rooms — ${widget.apartmentName}'),
      iconTheme: const IconThemeData(color: C.textSec),
      actions: [
        IconButton(
          icon: const Icon(Icons.add_rounded, color: C.accent),
          tooltip: 'Add Room',
          onPressed: _addRoom,
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator(color: C.accent))
        : _rooms.isEmpty
            ? EmptyState(
                icon: Icons.meeting_room_outlined,
                title: 'No rooms yet',
                subtitle: 'Add a room to start organizing devices.',
                action: PrimaryButton(label: 'Add Room', onTap: _addRoom),
              )
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    Icon(Icons.drag_indicator_rounded, size: 14, color: C.textTri),
                    const SizedBox(width: 6),
                    Text('Drag to reorder · tap to rename · long-press to delete',
                        style: AppText.bodySm.copyWith(fontSize: 11)),
                  ]),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    itemCount: _rooms.length,
                    onReorder: _reorder,
                    itemBuilder: (_, i) {
                      final room = _rooms[i];
                      return Padding(
                        key: ValueKey(room.id),
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _RoomRow(
                          room: room,
                          onTap: () => Navigator.push(context, MaterialPageRoute(
                            builder: (_) => RoomDevicesScreen(
                              authState: widget.authState,
                              apartmentId: widget.apartmentId,
                              room: room,
                              allRooms: _rooms,
                            ),
                          )).then((_) => _load()),
                          onRename: () => _renameRoom(room),
                          onDelete: () => _deleteRoom(room),
                        ),
                      );
                    },
                  ),
                ),
              ]),
  );
}

class _RoomRow extends StatelessWidget {
  final ManagedRoom room;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  const _RoomRow({
    required this.room, required this.onTap, required this.onRename, required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => AppCard(
    key: ValueKey('card-${room.id}'),
    child: InkWell(
      onTap: onTap,
      onLongPress: onDelete,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Icon(Icons.drag_handle_rounded, color: C.textTri, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(room.name, style: AppText.bodyMed),
                Text('${room.deviceCount} device${room.deviceCount == 1 ? "" : "s"}',
                    style: AppText.bodySm.copyWith(fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: C.textTri, size: 16),
            onPressed: onRename,
          ),
          const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
        ]),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Devices within one room
// ─────────────────────────────────────────────────────────────────────────────

class RoomDevicesScreen extends StatefulWidget {
  final AuthState authState;
  final int apartmentId;
  final ManagedRoom room;
  final List<ManagedRoom> allRooms;
  const RoomDevicesScreen({
    super.key, required this.authState, required this.apartmentId,
    required this.room, required this.allRooms,
  });

  @override
  State<RoomDevicesScreen> createState() => _RoomDevicesScreenState();
}

class _RoomDevicesScreenState extends State<RoomDevicesScreen> {
  bool _loading = true;
  List<ManagedDevice> _devices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final all = await widget.authState.fetchApartmentDevices(widget.apartmentId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _devices = (all ?? []).where((d) => d.roomId == widget.room.id).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    });
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final reordered = List<ManagedDevice>.of(_devices);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    setState(() => _devices = reordered);
    await widget.authState.reorderDevices(widget.apartmentId, reordered.map((d) => d.id).toList());
  }

  Future<void> _renameDevice(ManagedDevice device) async {
    final name = await _promptText(context, title: 'Rename Device', initial: device.name);
    if (name == null || name.trim().isEmpty || name.trim() == device.name) return;
    final ok = await widget.authState.renameDevice(widget.apartmentId, device.id, name.trim());
    if (!mounted) return;
    if (ok) {
      AppToast.show(context, 'Renamed to "${name.trim()}"');
      _load();
    } else {
      AppToast.show(context, 'Could not rename device', error: true);
    }
  }

  Future<void> _moveDevice(ManagedDevice device) async {
    final otherRooms = widget.allRooms.where((r) => r.id != widget.room.id).toList();
    if (otherRooms.isEmpty) {
      AppToast.show(context, 'No other rooms to move to', error: true);
      return;
    }
    final target = await showModalBottomSheet<ManagedRoom>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Move "${device.name}" to…', style: AppText.h3),
            const SizedBox(height: 12),
            for (final r in otherRooms)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r.name, style: AppText.bodyMed),
                trailing: const Icon(Icons.chevron_right_rounded, color: C.textTri),
                onTap: () => Navigator.pop(context, r),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    final ok = await widget.authState.moveDeviceToRoom(widget.apartmentId, device.id, target.id);
    if (!mounted) return;
    if (ok) {
      AppToast.show(context, 'Moved to ${target.name}');
      _load();
    } else {
      AppToast.show(context, 'Could not move device', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    appBar: AppBar(
      backgroundColor: C.surface,
      title: Text(widget.room.name),
      iconTheme: const IconThemeData(color: C.textSec),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator(color: C.accent))
        : _devices.isEmpty
            ? const EmptyState(
                icon: Icons.cable_rounded,
                title: 'No devices in this room',
              )
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    Icon(Icons.drag_indicator_rounded, size: 14, color: C.textTri),
                    const SizedBox(width: 6),
                    Text('Drag to reorder · tap icons to rename or move',
                        style: AppText.bodySm.copyWith(fontSize: 11)),
                  ]),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    itemCount: _devices.length,
                    onReorder: _reorder,
                    itemBuilder: (_, i) {
                      final device = _devices[i];
                      return Padding(
                        key: ValueKey(device.id),
                        padding: const EdgeInsets.only(bottom: 10),
                        child: AppCard(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(children: [
                              Icon(Icons.drag_handle_rounded, color: C.textTri, size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(device.name, style: AppText.bodyMed),
                                    Text(device.deviceType,
                                        style: AppText.bodySm.copyWith(fontSize: 10)),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, color: C.textTri, size: 16),
                                onPressed: () => _renameDevice(device),
                              ),
                              IconButton(
                                icon: const Icon(Icons.drive_file_move_outline, color: C.textTri, size: 16),
                                onPressed: () => _moveDevice(device),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared rename/add prompt
// ─────────────────────────────────────────────────────────────────────────────

Future<String?> _promptText(
  BuildContext context, {required String title, String initial = '', String hint = ''}
) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: C.card,
      title: Text(title, style: AppText.h3),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: AppText.body.copyWith(color: C.textPri),
        decoration: InputDecoration(
          hintText: hint.isEmpty ? null : hint,
          hintStyle: AppText.bodySm.copyWith(color: C.textTri),
          filled: true,
          fillColor: C.elevated,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onSubmitted: (v) => Navigator.pop(dialogContext, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, null),
          child: Text('Cancel', style: GoogleFonts.inter(color: C.textSec)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, ctrl.text),
          child: Text('Save', style: GoogleFonts.inter(color: C.accent, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
}
