// Digital Twin Map Editor — data models (mirror of Django MapLayout / MapLayer / CanvasObject)

// ─────────────────────────────────────────────────────────────────────────────
// EditorLayer
// ─────────────────────────────────────────────────────────────────────────────

class EditorLayer {
  final int    id;
  String name;
  String layerType;
  bool   visible;
  bool   locked;
  int    sortOrder;

  EditorLayer({
    required this.id,
    required this.name,
    required this.layerType,
    this.visible   = true,
    this.locked    = false,
    this.sortOrder = 0,
  });

  factory EditorLayer.fromJson(Map<String, dynamic> j) => EditorLayer(
    id:        j['id']         as int,
    name:      j['name']       as String,
    layerType: j['layer_type'] as String? ?? 'labels',
    visible:   j['visible']    as bool?   ?? true,
    locked:    j['locked']     as bool?   ?? false,
    sortOrder: j['sort_order'] as int?    ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id':         id,
    'name':       name,
    'layer_type': layerType,
    'visible':    visible,
    'locked':     locked,
    'sort_order': sortOrder,
  };

  EditorLayer copyWith({String? name, String? layerType, bool? visible, bool? locked, int? sortOrder}) =>
      EditorLayer(
        id:        id,
        name:      name      ?? this.name,
        layerType: layerType ?? this.layerType,
        visible:   visible   ?? this.visible,
        locked:    locked    ?? this.locked,
        sortOrder: sortOrder ?? this.sortOrder,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// EditorObject
// ─────────────────────────────────────────────────────────────────────────────

class EditorObject {
  /// Null for newly-created objects not yet saved to the server
  int?   id;
  int?   layerId;
  String objectType;   // room | device | label | wall
  String deviceType;   // ceiling_light, curtain, etc.
  String name;

  double x, y, width, height;
  double rotation;

  String plcVariable;
  int?   apartmentDeviceId;
  int?   roomId;
  String color;
  bool   labelVisible;
  String groupId;
  Map<String, dynamic> properties;
  int    sortOrder;

  EditorObject({
    this.id,
    this.layerId,
    required this.objectType,
    this.deviceType   = '',
    required this.name,
    required this.x,
    required this.y,
    this.width        = 48,
    this.height       = 48,
    this.rotation     = 0,
    this.plcVariable  = '',
    this.apartmentDeviceId,
    this.roomId,
    this.color        = '',
    this.labelVisible = true,
    this.groupId      = '',
    Map<String, dynamic>? properties,
    this.sortOrder    = 0,
  }) : properties = properties ?? {};

  factory EditorObject.fromJson(Map<String, dynamic> j) => EditorObject(
    id:                 j['id']                   as int?,
    layerId:            j['layer_id']              as int?,
    objectType:         j['object_type']           as String? ?? 'device',
    deviceType:         j['device_type']           as String? ?? '',
    name:               j['name']                  as String? ?? '',
    x:                  (j['x'] as num?)?.toDouble()      ?? 100,
    y:                  (j['y'] as num?)?.toDouble()      ?? 100,
    width:              (j['width'] as num?)?.toDouble()  ?? 48,
    height:             (j['height'] as num?)?.toDouble() ?? 48,
    rotation:           (j['rotation'] as num?)?.toDouble() ?? 0,
    plcVariable:        j['plc_variable']          as String? ?? '',
    apartmentDeviceId:  j['apartment_device_id']   as int?,
    roomId:             j['room_id']               as int?,
    color:              j['color']                 as String? ?? '',
    labelVisible:       j['label_visible']         as bool?   ?? true,
    groupId:            j['group_id']              as String? ?? '',
    properties:        (j['properties'] as Map<String, dynamic>?) ?? {},
    sortOrder:          j['sort_order']            as int?    ?? 0,
  );

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'layer_id':             layerId,
    'object_type':          objectType,
    'device_type':          deviceType,
    'name':                 name,
    'x':                    x,
    'y':                    y,
    'width':                width,
    'height':               height,
    'rotation':             rotation,
    'plc_variable':         plcVariable,
    'apartment_device_id':  apartmentDeviceId,
    'room_id':              roomId,
    'color':                color,
    'label_visible':        labelVisible,
    'group_id':             groupId,
    'properties':           properties,
    'sort_order':           sortOrder,
  };

  EditorObject clone() => EditorObject.fromJson(toJson());
}

// ─────────────────────────────────────────────────────────────────────────────
// EditorLayout
// ─────────────────────────────────────────────────────────────────────────────

class EditorLayout {
  final int    id;
  final int    apartmentId;
  final String apartmentName;

  double canvasWidth, canvasHeight;
  String backgroundUrl;
  double backgroundX, backgroundY, backgroundWidth, backgroundHeight;
  double backgroundRotation, backgroundOpacity;
  bool   backgroundLocked, backgroundVisible;

  bool    isPublished;
  String? publishedAt;
  String  updatedAt;

  List<EditorLayer>  layers;
  List<EditorObject> objects;

  EditorLayout({
    required this.id,
    required this.apartmentId,
    required this.apartmentName,
    this.canvasWidth         = 2000,
    this.canvasHeight        = 1500,
    this.backgroundUrl       = '',
    this.backgroundX         = 0,
    this.backgroundY         = 0,
    this.backgroundWidth     = 2000,
    this.backgroundHeight    = 1500,
    this.backgroundRotation  = 0,
    this.backgroundOpacity   = 0.25,
    this.backgroundLocked    = true,
    this.backgroundVisible   = true,
    this.isPublished         = false,
    this.publishedAt,
    this.updatedAt           = '',
    List<EditorLayer>?  layers,
    List<EditorObject>? objects,
  })  : layers  = layers  ?? [],
        objects = objects ?? [];

  factory EditorLayout.fromJson(Map<String, dynamic> j) => EditorLayout(
    id:                  j['id']                as int,
    apartmentId:         j['apartment_id']      as int,
    apartmentName:       j['apartment_name']    as String? ?? '',
    canvasWidth:         (j['canvas_width']  as num?)?.toDouble()          ?? 2000,
    canvasHeight:        (j['canvas_height'] as num?)?.toDouble()          ?? 1500,
    backgroundUrl:       j['background_url']    as String? ?? '',
    backgroundX:         (j['background_x']  as num?)?.toDouble()          ?? 0,
    backgroundY:         (j['background_y']  as num?)?.toDouble()          ?? 0,
    backgroundWidth:     (j['background_width']  as num?)?.toDouble()      ?? 2000,
    backgroundHeight:    (j['background_height'] as num?)?.toDouble()      ?? 1500,
    backgroundRotation:  (j['background_rotation'] as num?)?.toDouble()    ?? 0,
    backgroundOpacity:   (j['background_opacity']  as num?)?.toDouble()    ?? 0.25,
    backgroundLocked:    j['background_locked']    as bool? ?? true,
    backgroundVisible:   j['background_visible']   as bool? ?? true,
    isPublished:         j['is_published']          as bool? ?? false,
    publishedAt:         j['published_at']          as String?,
    updatedAt:           j['updated_at']            as String? ?? '',
    layers:  (j['layers'] as List<dynamic>?)
        ?.map((e) => EditorLayer.fromJson(e as Map<String, dynamic>))
        .toList(),
    objects: (j['objects'] as List<dynamic>?)
        ?.map((e) => EditorObject.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toSaveJson() => {
    'canvas_width':          canvasWidth,
    'canvas_height':         canvasHeight,
    'background_url':        backgroundUrl,
    'background_x':          backgroundX,
    'background_y':          backgroundY,
    'background_width':      backgroundWidth,
    'background_height':     backgroundHeight,
    'background_rotation':   backgroundRotation,
    'background_opacity':    backgroundOpacity,
    'background_locked':     backgroundLocked,
    'background_visible':    backgroundVisible,
    'layers':                layers.map((l) => l.toJson()).toList(),
    'objects':               objects.map((o) => o.toJson()).toList(),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// EditorVersion
// ─────────────────────────────────────────────────────────────────────────────

class EditorVersion {
  final int    id;
  final int    versionNumber;
  final String description;
  final String createdAt;
  final String? createdBy;
  final bool   isPublished;
  final int    objectCount;

  const EditorVersion({
    required this.id,
    required this.versionNumber,
    required this.description,
    required this.createdAt,
    required this.isPublished,
    required this.objectCount,
    this.createdBy,
  });

  factory EditorVersion.fromJson(Map<String, dynamic> j) => EditorVersion(
    id:            j['id']             as int,
    versionNumber: j['version_number'] as int,
    description:   j['description']    as String? ?? '',
    createdAt:     j['created_at']     as String? ?? '',
    createdBy:     j['created_by']     as String?,
    isPublished:   j['is_published']   as bool?   ?? false,
    objectCount:   j['object_count']   as int?    ?? 0,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ApartmentEditorEntry — list item for the apartment picker
// ─────────────────────────────────────────────────────────────────────────────

class ApartmentEditorEntry {
  final int    id;
  final String name;
  final String building;
  final String floor;
  final bool   hasLayout;
  final bool   isPublished;
  final int    objectCount;

  const ApartmentEditorEntry({
    required this.id,
    required this.name,
    required this.building,
    required this.floor,
    required this.hasLayout,
    required this.isPublished,
    required this.objectCount,
  });

  factory ApartmentEditorEntry.fromJson(Map<String, dynamic> j) => ApartmentEditorEntry(
    id:          j['id']           as int,
    name:        j['name']         as String,
    building:    j['building']     as String? ?? '',
    floor:       j['floor']        as String? ?? '',
    hasLayout:   j['has_layout']   as bool?   ?? false,
    isPublished: j['is_published'] as bool?   ?? false,
    objectCount: j['object_count'] as int?    ?? 0,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DevicePickerEntry — ApartmentDevice entry for PLC linking
// ─────────────────────────────────────────────────────────────────────────────

class DevicePickerEntry {
  final int    id;
  final String name;
  final String deviceType;
  final int?   channelOrIndex;
  final String gvlName;
  final int?   roomId;
  final String? roomName;

  const DevicePickerEntry({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.gvlName,
    this.channelOrIndex,
    this.roomId,
    this.roomName,
  });

  factory DevicePickerEntry.fromJson(Map<String, dynamic> j) => DevicePickerEntry(
    id:             j['id']               as int,
    name:           j['name']             as String,
    deviceType:     j['device_type']      as String,
    channelOrIndex: j['channel_or_index'] as int?,
    gvlName:        j['gvl_name']         as String? ?? '',
    roomId:         j['room_id']          as int?,
    roomName:       j['room_name']        as String?,
  );

  String get displayLabel {
    final channel = channelOrIndex != null ? ' [$channelOrIndex]' : '';
    return '$name$channel';
  }
}
