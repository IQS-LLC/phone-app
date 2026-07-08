import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme.dart';
import '../auth/auth_state.dart';
import '../models/auth_models.dart';
import '../widgets/common_widgets.dart';

/// Tech Team only — never reachable by residents. The Flutter side hides
/// the entry point (gated on authState.user.isStaff); the Django side
/// independently enforces IsAdminUser on every endpoint this screen calls,
/// so a resident poking at the API directly still gets 403.
class UserManagementScreen extends StatefulWidget {
  final AuthState authState;
  const UserManagementScreen({super.key, required this.authState});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

enum _StatusFilter { all, active, disabled, staff }
enum _SortBy { name, recentLogin }

class _UserManagementScreenState extends State<UserManagementScreen> {
  bool _loading = true;
  String? _error;
  List<ManagedUser> _users = [];
  List<ManagedApartmentLink> _apartments = [];

  final _searchCtrl = TextEditingController();
  String _query = '';
  _StatusFilter _filter = _StatusFilter.all;
  _SortBy _sortBy = _SortBy.name;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<ManagedUser> get _visibleUsers {
    var list = _users;
    switch (_filter) {
      case _StatusFilter.active:   list = list.where((u) => u.isActive).toList();
      case _StatusFilter.disabled: list = list.where((u) => !u.isActive).toList();
      case _StatusFilter.staff:    list = list.where((u) => u.isStaff).toList();
      case _StatusFilter.all:      break;
    }
    if (_query.isNotEmpty) {
      list = list.where((u) =>
          u.displayName.toLowerCase().contains(_query) ||
          u.username.toLowerCase().contains(_query) ||
          u.email.toLowerCase().contains(_query)).toList();
    }
    list = List.of(list);
    switch (_sortBy) {
      case _SortBy.name:
        list.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      case _SortBy.recentLogin:
        list.sort((a, b) => (b.lastLogin ?? '').compareTo(a.lastLogin ?? ''));
    }
    return list;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final users = await widget.authState.fetchManagedUsers();
    final apartments = await widget.authState.fetchAllApartments();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (users == null) {
        _error = 'Could not load users.';
      } else {
        _users = users;
        _apartments = apartments ?? [];
      }
    });
  }

  Future<void> _runAction(Future<bool> Function() action, {String? successMsg}) async {
    final ok = await action();
    if (!mounted) return;
    if (ok) {
      if (successMsg != null) _toast(successMsg);
      await _load();
    } else {
      _toast('That didn\'t work — try again.', error: true);
    }
  }

  void _toast(String msg, {bool error = false}) =>
      AppToast.show(context, msg, error: error);

  void _openActions(ManagedUser u) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _UserActionSheet(
        user: u,
        apartments: _apartments,
        isSelf: u.id == widget.authState.user?.id,
        onDisable: () => _runAction(() => widget.authState.disableUser(u.id), successMsg: 'Account disabled'),
        onEnable: () => _runAction(() => widget.authState.enableUser(u.id), successMsg: 'Account enabled'),
        onForceLogout: () => _runAction(() => widget.authState.forceLogoutUser(u.id), successMsg: 'Sessions revoked'),
        onDelete: () => _runAction(() => widget.authState.deleteUser(u.id), successMsg: 'Account deleted'),
        onResetPassword: (pw) => _runAction(() => widget.authState.resetUserPassword(u.id, pw), successMsg: 'Password reset'),
        onAssignApartment: (apartmentId, role) => _runAction(
          () => widget.authState.assignApartment(u.id, apartmentId, role),
          successMsg: 'Apartment assigned',
        ),
        onViewSessions: () => _openSessions(u),
        onEditPermissions: () => _openPermissionEditor(u),
      ),
    );
  }

  void _openCreateUser() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _CreateUserSheet(
        apartments: _apartments,
        onSubmit: (username, password, email, firstName, apartmentId, role) async {
          final error = await widget.authState.createUser(
            username: username, password: password, email: email, firstName: firstName,
          );
          if (error != null) {
            _toast(error, error: true);
            return false;
          }
          await _load();
          if (apartmentId != null) {
            final created = _users.where((u) => u.username == username).firstOrNull;
            if (created != null) {
              await widget.authState.assignApartment(created.id, apartmentId, role);
              await _load();
            }
          }
          _toast('Account created');
          return true;
        },
      ),
    );
  }

  void _openSessions(ManagedUser u) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _SessionsSheet(user: u, authState: widget.authState),
    );
  }

  void _openPermissionEditor(ManagedUser u) {
    if (u.apartments.isEmpty) {
      _toast('${u.displayName} has no apartment assigned yet.', error: true);
      return;
    }
    if (u.apartments.length == 1) {
      _showPermissionEditorFor(u, u.apartments.first.id, u.apartments.first.name);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _ApartmentPickerSheet(
        user: u,
        onPicked: (apartmentId, name) => _showPermissionEditorFor(u, apartmentId, name),
      ),
    );
  }

  void _showPermissionEditorFor(ManagedUser u, int apartmentId, String apartmentName) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PermissionEditorSheet(
        user: u, apartmentId: apartmentId, apartmentName: apartmentName,
        authState: widget.authState,
        onToast: _toast,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.bg,
    appBar: AppBar(
      backgroundColor: C.surface,
      title: const Text('User Management'),
      iconTheme: const IconThemeData(color: C.textSec),
      actions: [
        IconButton(
          icon: const Icon(Icons.person_add_alt_1_rounded, color: C.accent),
          tooltip: 'Create User',
          onPressed: _openCreateUser,
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator(color: C.accent))
        : _error != null
            ? EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Couldn\'t load users',
                subtitle: _error,
                action: PrimaryButton(label: 'Retry', onTap: _load),
              )
            : Column(children: [
                _searchAndFilterBar(),
                Expanded(
                  child: RefreshIndicator(
                    color: C.accent,
                    backgroundColor: C.card,
                    onRefresh: _load,
                    child: _visibleUsers.isEmpty
                        ? EmptyState(
                            icon: Icons.people_outline_rounded,
                            title: _users.isEmpty ? 'No accounts yet' : 'No matching accounts',
                          )
                        : ListView.builder(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                            itemCount: _visibleUsers.length,
                            itemBuilder: (_, i) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _UserRow(
                                user: _visibleUsers[i],
                                onTap: () => _openActions(_visibleUsers[i]),
                              ),
                            ),
                          ),
                  ),
                ),
              ]),
  );

  Widget _searchAndFilterBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Column(children: [
      TextField(
        controller: _searchCtrl,
        style: AppText.body.copyWith(color: C.textPri, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search by name, username, or email',
          hintStyle: AppText.bodySm.copyWith(color: C.textTri),
          prefixIcon: const Icon(Icons.search_rounded, color: C.textTri, size: 18),
          suffixIcon: _query.isEmpty ? null : IconButton(
            icon: const Icon(Icons.close_rounded, color: C.textTri, size: 16),
            onPressed: () => _searchCtrl.clear(),
          ),
          filled: true,
          fillColor: C.elevated,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.accent, width: 1.5),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: Row(children: [
            for (final f in _StatusFilter.values) ...[
              _FilterChip(
                label: switch (f) {
                  _StatusFilter.all      => 'All',
                  _StatusFilter.active   => 'Active',
                  _StatusFilter.disabled => 'Disabled',
                  _StatusFilter.staff    => 'Tech Team',
                },
                selected: _filter == f,
                onTap: () => setState(() => _filter = f),
              ),
              if (f != _StatusFilter.values.last) const SizedBox(width: 8),
            ],
          ]),
        ),
        TapScale(
          onTap: () => setState(() => _sortBy =
              _sortBy == _SortBy.name ? _SortBy.recentLogin : _SortBy.name),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: C.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: C.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.sort_rounded, color: C.textSec, size: 13),
              const SizedBox(width: 4),
              Text(_sortBy == _SortBy.name ? 'Name' : 'Recent',
                  style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: C.textSec)),
            ]),
          ),
        ),
      ]),
    ]),
  );
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool   selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? C.accent.withAlpha(22) : C.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? C.accent.withAlpha(80) : C.border),
      ),
      child: Text(label,
          style: GoogleFonts.inter(
            fontSize: 11, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? C.accent : C.textSec,
          )),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// User row
// ─────────────────────────────────────────────────────────────────────────────

class _UserRow extends StatelessWidget {
  final ManagedUser user;
  final VoidCallback onTap;
  const _UserRow({required this.user, required this.onTap});

  @override
  Widget build(BuildContext context) => TapScale(
    onTap: onTap,
    child: AppCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: (user.isActive ? C.accent : C.textTri).withAlpha(22),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                user.isStaff ? Icons.shield_rounded : Icons.person_rounded,
                color: user.isActive ? C.accent : C.textTri,
                size: 17,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(user.displayName,
                          style: AppText.bodyMed, overflow: TextOverflow.ellipsis),
                    ),
                    if (!user.isActive) const _Tag(text: 'DISABLED', color: C.red),
                    if (user.isStaff)   const _Tag(text: 'TECH TEAM', color: C.purple),
                  ]),
                  const SizedBox(height: 3),
                  Text('@${user.username} · ${user.email.isEmpty ? "no email" : user.email}',
                      style: AppText.bodySm.copyWith(fontSize: 11),
                      overflow: TextOverflow.ellipsis),
                  if (user.apartments.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final a in user.apartments)
                        _Tag(text: '${a.name} · ${a.role}', color: C.blue),
                    ]),
                  ],
                  const SizedBox(height: 6),
                  Row(children: [
                    Icon(Icons.devices_rounded, size: 12, color: C.textTri),
                    const SizedBox(width: 4),
                    Text('${user.activeSessions} active session${user.activeSessions == 1 ? "" : "s"}',
                        style: AppText.bodySm.copyWith(fontSize: 10)),
                    const SizedBox(width: 10),
                    Icon(Icons.login_rounded, size: 12, color: C.textTri),
                    const SizedBox(width: 4),
                    Text(user.lastLogin == null ? 'Never logged in' : 'Active recently',
                        style: AppText.bodySm.copyWith(fontSize: 10)),
                  ]),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: C.textTri, size: 18),
          ],
        ),
      ),
    ),
  );
}

class _Tag extends StatelessWidget {
  final String text;
  final Color  color;
  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    margin: const EdgeInsets.only(left: 6),
    decoration: BoxDecoration(
      color: color.withAlpha(18),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withAlpha(55)),
    ),
    child: Text(text,
        style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Action sheet — Disable / Enable / Reset Password / Force Logout /
// Assign Apartment / Delete
// ─────────────────────────────────────────────────────────────────────────────

class _UserActionSheet extends StatefulWidget {
  final ManagedUser user;
  final List<ManagedApartmentLink> apartments;
  final bool isSelf;
  final VoidCallback onDisable;
  final VoidCallback onEnable;
  final VoidCallback onForceLogout;
  final VoidCallback onDelete;
  final Future<void> Function(String newPassword) onResetPassword;
  final Future<void> Function(int apartmentId, String role) onAssignApartment;
  final VoidCallback onViewSessions;
  final VoidCallback onEditPermissions;

  const _UserActionSheet({
    required this.user,
    required this.apartments,
    required this.isSelf,
    required this.onDisable,
    required this.onEnable,
    required this.onForceLogout,
    required this.onDelete,
    required this.onResetPassword,
    required this.onAssignApartment,
    required this.onViewSessions,
    required this.onEditPermissions,
  });

  @override
  State<_UserActionSheet> createState() => _UserActionSheetState();
}

class _UserActionSheetState extends State<_UserActionSheet> {
  void _close() => Navigator.pop(context);

  Future<void> _confirmDelete() async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Delete ${widget.user.displayName}?', style: AppText.h3, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            'This permanently removes the account and every apartment membership. This can\'t be undone.',
            style: AppText.bodySm,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(
              child: PrimaryButton(
                label: 'Cancel', color: C.textSec,
                onTap: () => Navigator.pop(sheetContext, false),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PrimaryButton(
                label: 'Delete', color: C.red,
                onTap: () => Navigator.pop(sheetContext, true),
              ),
            ),
          ]),
        ]),
      ),
    );
    if (confirmed == true) {
      _close();
      widget.onDelete();
    }
  }

  void _openResetPassword() {
    Navigator.pop(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _ResetPasswordSheet(
        user: widget.user,
        onSubmit: widget.onResetPassword,
      ),
    );
  }

  void _openAssignApartment() {
    Navigator.pop(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _AssignApartmentSheet(
        apartments: widget.apartments,
        onSubmit: widget.onAssignApartment,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BottomSheetHandle(),
        const SizedBox(height: 16),
        Text(widget.user.displayName, style: AppText.h2),
        Text('@${widget.user.username}', style: AppText.bodySm),
        const SizedBox(height: 16),
        _ActionTile(
          icon: Icons.apartment_rounded, color: C.blue,
          label: 'Assign Apartment',
          onTap: _openAssignApartment,
        ),
        _ActionTile(
          icon: Icons.shield_outlined, color: C.teal,
          label: 'Permission Editor',
          onTap: () { _close(); widget.onEditPermissions(); },
        ),
        _ActionTile(
          icon: Icons.devices_other_rounded, color: C.blue,
          label: 'View Sessions',
          onTap: () { _close(); widget.onViewSessions(); },
        ),
        _ActionTile(
          icon: Icons.key_rounded, color: C.orange,
          label: 'Reset Password',
          onTap: _openResetPassword,
        ),
        _ActionTile(
          icon: Icons.logout_rounded, color: C.purple,
          label: 'Force Logout (revoke all sessions)',
          onTap: () { _close(); widget.onForceLogout(); },
        ),
        if (widget.user.isActive)
          _ActionTile(
            icon: Icons.block_rounded, color: C.red,
            label: 'Disable Account',
            disabled: widget.isSelf,
            onTap: () { _close(); widget.onDisable(); },
          )
        else
          _ActionTile(
            icon: Icons.check_circle_outline_rounded, color: C.green,
            label: 'Enable Account',
            onTap: () { _close(); widget.onEnable(); },
          ),
        _ActionTile(
          icon: Icons.delete_outline_rounded, color: C.red,
          label: 'Delete Account',
          disabled: widget.isSelf,
          onTap: _confirmDelete,
        ),
        if (widget.isSelf) ...[
          const SizedBox(height: 6),
          Text('You can\'t disable or delete your own account.',
              style: AppText.bodySm.copyWith(fontSize: 10, color: C.textTri)),
        ],
      ],
    ),
  );
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  final bool disabled;

  const _ActionTile({
    required this.icon, required this.color, required this.label, required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: disabled ? 0.4 : 1,
    child: InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(color: color.withAlpha(18), borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 12),
          Text(label, style: AppText.bodyMed),
        ]),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Reset password sheet
// ─────────────────────────────────────────────────────────────────────────────

class _ResetPasswordSheet extends StatefulWidget {
  final ManagedUser user;
  final Future<void> Function(String newPassword) onSubmit;
  const _ResetPasswordSheet({required this.user, required this.onSubmit});

  @override
  State<_ResetPasswordSheet> createState() => _ResetPasswordSheetState();
}

class _ResetPasswordSheetState extends State<_ResetPasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  final _ctrl = TextEditingController();
  bool _saving = false;
  bool _obscure = true;

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    await widget.onSubmit(_ctrl.text);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BottomSheetHandle(),
          const SizedBox(height: 16),
          Text('Reset Password', style: AppText.h2),
          const SizedBox(height: 4),
          Text('Sets a new password for @${widget.user.username} and signs them out everywhere.',
              style: AppText.bodySm),
          const SizedBox(height: 20),
          Text('NEW PASSWORD', style: AppText.label),
          const SizedBox(height: 6),
          TextFormField(
            controller: _ctrl,
            obscureText: _obscure,
            style: AppText.body.copyWith(color: C.textPri),
            decoration: InputDecoration(
              hintText: 'At least 8 characters',
              hintStyle: AppText.bodySm.copyWith(color: C.textTri),
              filled: true,
              fillColor: C.elevated,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                    color: C.textTri, size: 18),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: C.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: C.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: C.accent, width: 1.5),
              ),
              errorStyle: AppText.bodySm.copyWith(color: C.red),
            ),
            validator: (v) => (v == null || v.trim().length < 8) ? 'At least 8 characters' : null,
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: 'Reset Password', loading: _saving, onTap: _submit),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Assign apartment sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AssignApartmentSheet extends StatefulWidget {
  final List<ManagedApartmentLink> apartments;
  final Future<void> Function(int apartmentId, String role) onSubmit;
  const _AssignApartmentSheet({required this.apartments, required this.onSubmit});

  @override
  State<_AssignApartmentSheet> createState() => _AssignApartmentSheetState();
}

class _AssignApartmentSheetState extends State<_AssignApartmentSheet> {
  static const _roles = [
    ('owner', 'Owner'),
    ('resident', 'Resident'),
    ('installer', 'Installer'),
  ];

  int? _apartmentId;
  String _role = 'resident';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.apartments.isNotEmpty) _apartmentId = widget.apartments.first.id;
  }

  Future<void> _submit() async {
    if (_apartmentId == null) return;
    setState(() => _saving = true);
    await widget.onSubmit(_apartmentId!, _role);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BottomSheetHandle(),
        const SizedBox(height: 16),
        Text('Assign Apartment', style: AppText.h2),
        const SizedBox(height: 4),
        Text('Grants this user a role on an apartment. Re-assigning updates the existing role.',
            style: AppText.bodySm),
        const SizedBox(height: 20),
        if (widget.apartments.isEmpty)
          Text('No apartments exist yet.', style: AppText.bodySm.copyWith(color: C.red))
        else ...[
          Text('APARTMENT', style: AppText.label),
          const SizedBox(height: 6),
          _Dropdown<int>(
            value: _apartmentId,
            items: widget.apartments.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name))).toList(),
            onChanged: (v) => setState(() => _apartmentId = v),
          ),
          const SizedBox(height: 12),
          Text('ROLE', style: AppText.label),
          const SizedBox(height: 6),
          _Dropdown<String>(
            value: _role,
            items: _roles.map((r) => DropdownMenuItem(value: r.$1, child: Text(r.$2))).toList(),
            onChanged: (v) => setState(() => _role = v ?? 'resident'),
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: 'Assign', loading: _saving, onTap: _submit),
        ],
        const SizedBox(height: 8),
      ],
    ),
  );
}

class _Dropdown<T> extends StatelessWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final void Function(T?) onChanged;
  const _Dropdown({required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: C.elevated,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: C.border),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        dropdownColor: C.card,
        style: AppText.body.copyWith(color: C.textPri),
        icon: const Icon(Icons.expand_more_rounded, color: C.textTri),
        items: items,
        onChanged: onChanged,
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sessions sheet — view (not just force-revoke) a user's logged-in devices
// ─────────────────────────────────────────────────────────────────────────────

class _SessionsSheet extends StatefulWidget {
  final ManagedUser user;
  final AuthState   authState;
  const _SessionsSheet({required this.user, required this.authState});

  @override
  State<_SessionsSheet> createState() => _SessionsSheetState();
}

class _SessionsSheetState extends State<_SessionsSheet> {
  bool _loading = true;
  List<ManagedSession>? _sessions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await widget.authState.fetchUserSessions(widget.user.id);
    if (mounted) setState(() { _loading = false; _sessions = sessions; });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 28,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BottomSheetHandle(),
        const SizedBox(height: 16),
        Text('Active Sessions', style: AppText.h2),
        Text('@${widget.user.username}', style: AppText.bodySm),
        const SizedBox(height: 16),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator(color: C.accent)),
          )
        else if (_sessions == null)
          Text('Could not load sessions.', style: AppText.bodySm.copyWith(color: C.red))
        else if (_sessions!.isEmpty)
          Text('No active sessions.', style: AppText.bodySm)
        else
          for (final s in _sessions!) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    color: C.blue.withAlpha(18), borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(Icons.smartphone_rounded, color: C.blue, size: 14),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.deviceName, style: AppText.bodyMed.copyWith(fontSize: 12)),
                      Text(
                        [if (s.os.isNotEmpty) s.os, if (s.ipAddress != null) s.ipAddress!]
                            .join(' · '),
                        style: AppText.bodySm.copyWith(fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
            const AppDivider(),
          ],
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Apartment picker — used when opening the Permission Editor for a user
// with more than one apartment membership
// ─────────────────────────────────────────────────────────────────────────────

class _ApartmentPickerSheet extends StatelessWidget {
  final ManagedUser user;
  final void Function(int apartmentId, String name) onPicked;
  const _ApartmentPickerSheet({required this.user, required this.onPicked});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BottomSheetHandle(),
        const SizedBox(height: 16),
        Text('Which apartment?', style: AppText.h2),
        Text('${user.displayName} belongs to more than one.', style: AppText.bodySm),
        const SizedBox(height: 12),
        for (final a in user.apartments)
          _ActionTile(
            icon: Icons.apartment_rounded, color: C.blue,
            label: '${a.name} (${a.role})',
            onTap: () { Navigator.pop(context); onPicked(a.id, a.name); },
          ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Permission editor — toggle extra (always-additive) permissions on top of
// whatever a user's role already grants
// ─────────────────────────────────────────────────────────────────────────────

class _PermissionEditorSheet extends StatefulWidget {
  final ManagedUser user;
  final int    apartmentId;
  final String apartmentName;
  final AuthState authState;
  final void Function(String, {bool error}) onToast;

  const _PermissionEditorSheet({
    required this.user, required this.apartmentId, required this.apartmentName,
    required this.authState, required this.onToast,
  });

  @override
  State<_PermissionEditorSheet> createState() => _PermissionEditorSheetState();
}

class _PermissionEditorSheetState extends State<_PermissionEditorSheet> {
  bool _loading = true;
  bool _saving = false;
  List<PermissionInfo> _catalog = [];
  Set<String> _effective = {};
  Set<String> _extra = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      widget.authState.fetchPermissionCatalog(),
      widget.authState.fetchMembershipPermissions(widget.user.id, widget.apartmentId),
    ]);
    final catalog = results[0] as List<PermissionInfo>?;
    final membership = results[1] as (List<String>, List<String>)?;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _catalog = catalog ?? [];
      if (membership != null) {
        _effective = membership.$1.toSet();
        _extra = membership.$2.toSet();
      }
    });
  }

  bool _roleGranted(String code) => _effective.contains(code) && !_extra.contains(code);

  Future<void> _toggle(String code, bool value) async {
    final prevExtra = _extra;
    final roleOnly  = _effective.difference(prevExtra);
    final nextExtra = Set<String>.from(_extra);
    value ? nextExtra.add(code) : nextExtra.remove(code);
    setState(() { _extra = nextExtra; _saving = true; });

    final ok = await widget.authState.setMembershipPermissions(
      widget.user.id, widget.apartmentId, nextExtra.toList(),
    );
    if (!mounted) return;

    if (ok) {
      setState(() { _effective = roleOnly.union(nextExtra); _saving = false; });
    } else {
      setState(() { _extra = prevExtra; _saving = false; });
      widget.onToast('Could not update permissions', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 28,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BottomSheetHandle(),
        const SizedBox(height: 16),
        Text('Permission Editor', style: AppText.h2),
        Text('${widget.user.displayName} · ${widget.apartmentName}', style: AppText.bodySm),
        const SizedBox(height: 4),
        Text(
          'Toggles grant extra permissions on top of their role. Greyed-out '
          'switches are already included by their role.',
          style: AppText.bodySm.copyWith(fontSize: 10),
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator(color: C.accent)),
          )
        else
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: SingleChildScrollView(
              child: Column(children: [
                for (final p in _catalog) ...[
                  _PermissionRow(
                    permission: p,
                    roleGranted: _roleGranted(p.code),
                    extraGranted: _extra.contains(p.code),
                    saving: _saving,
                    onChanged: (v) => _toggle(p.code, v),
                  ),
                  const AppDivider(),
                ],
              ]),
            ),
          ),
      ],
    ),
  );
}

class _PermissionRow extends StatelessWidget {
  final PermissionInfo permission;
  final bool roleGranted;
  final bool extraGranted;
  final bool saving;
  final void Function(bool) onChanged;
  const _PermissionRow({
    required this.permission, required this.roleGranted, required this.extraGranted,
    required this.saving, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(permission.label, style: AppText.bodyMed.copyWith(fontSize: 12)),
            if (roleGranted)
              Text('Included by role', style: AppText.bodySm.copyWith(fontSize: 9, color: C.textTri)),
          ],
        ),
      ),
      Switch(
        value: roleGranted || extraGranted,
        activeThumbColor: C.accent,
        onChanged: (roleGranted || saving) ? null : onChanged,
      ),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Create User sheet — the Tech Team's account-provisioning entry point.
// Residents can never reach /auth/register/ (IsAdminUser-gated server-side,
// see RegistrationLockdownTests) — account creation is exclusively staff work.
// ─────────────────────────────────────────────────────────────────────────────

class _CreateUserSheet extends StatefulWidget {
  final List<ManagedApartmentLink> apartments;
  final Future<bool> Function(
    String username, String password, String email, String firstName,
    int? apartmentId, String role,
  ) onSubmit;
  const _CreateUserSheet({required this.apartments, required this.onSubmit});

  @override
  State<_CreateUserSheet> createState() => _CreateUserSheetState();
}

class _CreateUserSheetState extends State<_CreateUserSheet> {
  static const _roles = [
    ('owner', 'Owner'),
    ('resident', 'Resident'),
    ('installer', 'Installer'),
  ];

  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl  = TextEditingController();
  final _passwordCtrl  = TextEditingController();
  final _emailCtrl     = TextEditingController();
  final _firstNameCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  int? _apartmentId;
  String _role = 'resident';

  @override
  void dispose() {
    for (final c in [_usernameCtrl, _passwordCtrl, _emailCtrl, _firstNameCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final ok = await widget.onSubmit(
      _usernameCtrl.text.trim(), _passwordCtrl.text, _emailCtrl.text.trim(),
      _firstNameCtrl.text.trim(), _apartmentId, _role,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: 20, right: 20, top: 20,
      bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BottomSheetHandle(),
          const SizedBox(height: 16),
          Text('Create User', style: AppText.h2),
          const SizedBox(height: 4),
          Text('Residents never self-register — this is the only way new accounts get created.',
              style: AppText.bodySm),
          const SizedBox(height: 20),
          _field('USERNAME', _usernameCtrl, hint: 'jane_doe',
            validator: (v) => (v == null || v.trim().length < 3) ? 'At least 3 characters' : null),
          const SizedBox(height: 12),
          _field('PASSWORD', _passwordCtrl, hint: 'At least 8 characters', obscure: _obscure,
            suffix: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                  color: C.textTri, size: 18),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
            validator: (v) => (v == null || v.length < 8) ? 'At least 8 characters' : null),
          const SizedBox(height: 12),
          _field('EMAIL (OPTIONAL)', _emailCtrl, hint: 'jane@example.com', required: false),
          const SizedBox(height: 12),
          _field('FIRST NAME (OPTIONAL)', _firstNameCtrl, hint: 'Jane', required: false),
          if (widget.apartments.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('ASSIGN TO APARTMENT (OPTIONAL)', style: AppText.label),
            const SizedBox(height: 6),
            _Dropdown<int?>(
              value: _apartmentId,
              items: [
                const DropdownMenuItem(value: null, child: Text('Don\'t assign yet')),
                for (final a in widget.apartments)
                  DropdownMenuItem(value: a.id, child: Text(a.name)),
              ],
              onChanged: (v) => setState(() => _apartmentId = v),
            ),
            if (_apartmentId != null) ...[
              const SizedBox(height: 12),
              Text('ROLE', style: AppText.label),
              const SizedBox(height: 6),
              _Dropdown<String>(
                value: _role,
                items: _roles.map((r) => DropdownMenuItem(value: r.$1, child: Text(r.$2))).toList(),
                onChanged: (v) => setState(() => _role = v ?? 'resident'),
              ),
            ],
          ],
          const SizedBox(height: 20),
          PrimaryButton(label: 'Create User', loading: _saving, onTap: _submit),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  Widget _field(
    String label, TextEditingController ctrl, {
    String hint = '', bool required = true, bool obscure = false,
    Widget? suffix, String? Function(String?)? validator,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppText.label),
      const SizedBox(height: 6),
      TextFormField(
        controller: ctrl,
        obscureText: obscure,
        style: AppText.body.copyWith(color: C.textPri),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppText.bodySm.copyWith(color: C.textTri),
          suffixIcon: suffix,
          filled: true,
          fillColor: C.elevated,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: C.accent, width: 1.5),
          ),
          errorStyle: AppText.bodySm.copyWith(color: C.red),
        ),
        validator: validator ?? (v) => (required && (v == null || v.trim().isEmpty)) ? 'Required' : null,
      ),
    ],
  );
}
