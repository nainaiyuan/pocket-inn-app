/// 桌宠模块 — 持久化存储（sqflite）
///
/// 三类数据：
/// - pet_profiles：宠物档案（好感度、名字、大小）
/// - pet_actions：动作定义（用户自建动作的元数据 + 帧数）
/// - pet_activities：组合动作（步骤 JSON）
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../storage/butler_store.dart';
import 'pet_feed.dart';
import 'pet_models.dart';
import 'scene_models.dart';

class PetStore extends ButlerStore implements PetAffectionStore {
  /// 头像目录（应用文档目录 pet/avatars/）
  static Future<String> avatarsDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'pet', 'avatars'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  @override
  String get id => 'pet';

  @override
  String get name => '桌宠';

  @override
  Future<void> createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_profiles (
        pet_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        affection INTEGER DEFAULT 0,
        scale REAL DEFAULT 1.0,
        visible INTEGER DEFAULT 1,
        area TEXT DEFAULT 'full',
        fixed_x REAL,
        fixed_y REAL,
        break_action_id TEXT DEFAULT 'idle',
        avatar_path TEXT,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_actions (
        action_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        fps REAL DEFAULT 10,
        loop TEXT DEFAULT 'loop',
        frame_dir TEXT,
        frame_count INTEGER DEFAULT 0,
        move_anim_id TEXT DEFAULT 'walk',
        target_spot TEXT,
        target_x REAL,
        target_y REAL,
        trajectory TEXT DEFAULT 'walk',
        move_mode TEXT DEFAULT 'distance',
        move_duration REAL DEFAULT 3,
        speed_tier TEXT DEFAULT 'normal',
        move_group_id TEXT,
        duration_seconds REAL DEFAULT 1
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_duo_configs (
        pair_id TEXT PRIMARY KEY,
        pet_a TEXT NOT NULL,
        pet_b TEXT NOT NULL,
        action_id TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_activities (
        activity_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        steps_json TEXT NOT NULL
      )
    ''');
    // 8-14 23:2x（GPT 19 条设计 v1.2）：状态系统两张新表——
    // 状态绑定（角色×状态×来源→响应，多行顺序播）+ 跨角色联动
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_state_bindings (
        profile_id TEXT NOT NULL,
        state_id TEXT NOT NULL,
        source TEXT DEFAULT 'auto',
        seq INTEGER DEFAULT 0,
        enabled INTEGER DEFAULT 1,
        auto_detect INTEGER DEFAULT 1,
        priority INTEGER DEFAULT 0,
        response_type TEXT DEFAULT 'action',
        response_id TEXT,
        resume_after INTEGER DEFAULT 1,
        PRIMARY KEY (profile_id, state_id, source, seq)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_state_links (
        observer_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        target_state TEXT NOT NULL,
        seq INTEGER DEFAULT 0,
        enabled INTEGER DEFAULT 1,
        response_type TEXT DEFAULT 'action',
        response_id TEXT,
        PRIMARY KEY (observer_id, target_id, target_state, seq)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_groups (
        group_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        trigger_dist REAL,
        exit_mode TEXT DEFAULT 'idle',
        slots_json TEXT NOT NULL,
        steps_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_move_groups (
        group_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        walk_action_id TEXT NOT NULL,
        run_action_id TEXT
      )
    ''');
    // 8-15 02:2x 全屏场景模式 P0（16 号冲刺安排）：场景/节点/选项/热点
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_scenes (
        scene_id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        bg_path TEXT,
        sort_order INTEGER DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_nodes (
        node_id TEXT PRIMARY KEY,
        scene_id TEXT NOT NULL,
        seq INTEGER DEFAULT 0,
        type TEXT DEFAULT 'fixed',
        continue_type TEXT DEFAULT 'auto',
        wait_user INTEGER DEFAULT 0,
        content TEXT,
        target_node TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_choices (
        choice_id TEXT PRIMARY KEY,
        node_id TEXT NOT NULL,
        seq INTEGER DEFAULT 0,
        label TEXT NOT NULL,
        target_node TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pet_hotspots (
        hotspot_id TEXT PRIMARY KEY,
        scene_id TEXT NOT NULL,
        type TEXT DEFAULT 'point',
        trigger TEXT DEFAULT 'click',
        pet_id TEXT,
        x REAL DEFAULT 0.5,
        y REAL DEFAULT 0.5,
        w REAL DEFAULT 0.1,
        h REAL DEFAULT 0.1,
        binding_type TEXT DEFAULT 'action',
        binding_id TEXT NOT NULL
      )
    ''');
    // 旧库迁移：补 visible 列（已存在会报错，忽略）
    try {
      await db.execute(
          'ALTER TABLE pet_profiles ADD COLUMN visible INTEGER DEFAULT 1');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_profiles ADD COLUMN area TEXT DEFAULT \'full\'');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_profiles ADD COLUMN fixed_x REAL');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_profiles ADD COLUMN fixed_y REAL');
    } catch (_) {}
    // 8-14 23:2x：扔出距离（用户配置：扔屏幕百分之多少）
    try {
      await db.execute(
          'ALTER TABLE pet_profiles ADD COLUMN throw_distance REAL DEFAULT 0.5');
    } catch (_) {}
    try {
      await db.execute('''
          CREATE TABLE IF NOT EXISTS pet_state_bindings (
            profile_id TEXT NOT NULL,
            state_id TEXT NOT NULL,
            source TEXT DEFAULT 'auto',
            seq INTEGER DEFAULT 0,
            enabled INTEGER DEFAULT 1,
            auto_detect INTEGER DEFAULT 1,
            priority INTEGER DEFAULT 0,
            response_type TEXT DEFAULT 'action',
            response_id TEXT,
            resume_after INTEGER DEFAULT 1,
            PRIMARY KEY (profile_id, state_id, source, seq)
          )''');
    } catch (_) {}
    try {
      await db.execute('''
          CREATE TABLE IF NOT EXISTS pet_state_links (
            observer_id TEXT NOT NULL,
            target_id TEXT NOT NULL,
            target_state TEXT NOT NULL,
            seq INTEGER DEFAULT 0,
            enabled INTEGER DEFAULT 1,
            response_type TEXT DEFAULT 'action',
            response_id TEXT,
            PRIMARY KEY (observer_id, target_id, target_state, seq)
          )''');
    } catch (_) {}
    try {
      await db.execute('''
          CREATE TABLE IF NOT EXISTS pet_scenes (
            scene_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            bg_path TEXT,
            sort_order INTEGER DEFAULT 0
          )''');
    } catch (_) {}
    try {
      await db.execute('''
          CREATE TABLE IF NOT EXISTS pet_nodes (
            node_id TEXT PRIMARY KEY,
            scene_id TEXT NOT NULL,
            seq INTEGER DEFAULT 0,
            type TEXT DEFAULT 'fixed',
            continue_type TEXT DEFAULT 'auto',
            wait_user INTEGER DEFAULT 0,
            content TEXT,
            target_node TEXT
          )''');
    } catch (_) {}
    try {
      await db.execute('''
          CREATE TABLE IF NOT EXISTS pet_choices (
            choice_id TEXT PRIMARY KEY,
            node_id TEXT NOT NULL,
            seq INTEGER DEFAULT 0,
            label TEXT NOT NULL,
            target_node TEXT NOT NULL
          )''');
    } catch (_) {}
    try {
      await db.execute('''
          CREATE TABLE IF NOT EXISTS pet_hotspots (
            hotspot_id TEXT PRIMARY KEY,
            scene_id TEXT NOT NULL,
            type TEXT DEFAULT 'point',
            trigger TEXT DEFAULT 'click',
            pet_id TEXT,
            x REAL DEFAULT 0.5,
            y REAL DEFAULT 0.5,
            w REAL DEFAULT 0.1,
            h REAL DEFAULT 0.1,
            binding_type TEXT DEFAULT 'action',
            binding_id TEXT NOT NULL
          )''');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN speed_tier TEXT DEFAULT \'normal\'');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN move_group_id TEXT');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_profiles ADD COLUMN break_action_id TEXT DEFAULT \'idle\'');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN duration_seconds REAL DEFAULT 1');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN trajectory TEXT DEFAULT \'walk\'');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN move_dir TEXT');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN move_dist REAL');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN move_sec REAL');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN move_mode TEXT DEFAULT \'distance\'');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN move_ref TEXT DEFAULT \'self\'');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_profiles ADD COLUMN avatar_path TEXT');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_activities ADD COLUMN start_ref TEXT');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN start_x REAL');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN start_y REAL');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_activities ADD COLUMN start_x REAL');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_activities ADD COLUMN start_y REAL');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN slot_id TEXT');
    } catch (_) {}
    try {
      await db.execute(
          'ALTER TABLE pet_actions ADD COLUMN profile_id TEXT');
    } catch (_) {}
  }

  // ========== 宠物档案 ==========

  Future<PetProfile?> getProfile(String petId) async {
    final rows = await query(
      'pet_profiles',
      where: 'pet_id = ?',
      whereArgs: [petId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PetProfile(
      petId: rows.first['pet_id'] as String,
      name: rows.first['name'] as String? ?? petId,
      affection: rows.first['affection'] as int? ?? 0,
      scale: (rows.first['scale'] as num?)?.toDouble() ?? 1.0,
      visible: (rows.first['visible'] as int? ?? 1) == 1,
      area: PetArea.fromName(rows.first['area'] as String?),
      fixedX: (rows.first['fixed_x'] as num?)?.toDouble(),
      fixedY: (rows.first['fixed_y'] as num?)?.toDouble(),
      throwDistance: (rows.first['throw_distance'] as num?)?.toDouble() ?? 0.5,
      breakActionId: rows.first['break_action_id'] as String? ?? 'idle',
      avatarPath: rows.first['avatar_path'] as String?,
    );
  }

  Future<List<PetProfile>> allProfiles() async {
    final rows = await query('pet_profiles', orderBy: 'updated_at DESC');
    return rows
        .map((r) => PetProfile(
              petId: r['pet_id'] as String,
              name: r['name'] as String? ?? '',
              affection: r['affection'] as int? ?? 0,
              scale: (r['scale'] as num?)?.toDouble() ?? 1.0,
              visible: (r['visible'] as int? ?? 1) == 1,
              area: PetArea.fromName(r['area'] as String?),
              fixedX: (r['fixed_x'] as num?)?.toDouble(),
              fixedY: (r['fixed_y'] as num?)?.toDouble(),
              throwDistance: (r['throw_distance'] as num?)?.toDouble() ?? 0.5,
              breakActionId: r['break_action_id'] as String? ?? 'idle',
              avatarPath: r['avatar_path'] as String?,
            ))
        .toList();
  }

  Future<void> saveProfile(PetProfile profile) async {
    await insert('pet_profiles', {
      'pet_id': profile.petId,
      'name': profile.name,
      'affection': profile.affection,
      'scale': profile.scale,
      'visible': profile.visible ? 1 : 0,
      'area': profile.area.name,
      'fixed_x': profile.fixedX,
      'fixed_y': profile.fixedY,
      'break_action_id': profile.breakActionId,
      'avatar_path': profile.avatarPath,
      'throw_distance': profile.throwDistance,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// 开关小人显示（右页多选）
  Future<void> setProfileVisible(String petId, bool visible) async {
    final existing = await getProfile(petId);
    if (existing == null) return;
    await saveProfile(existing.copyWith(visible: visible));
  }

  /// 更新小人活动区域（满屏/输入框上方/固定位置）
  Future<void> updateProfileArea(
    String petId, {
    PetArea? area,
    double? fixedX,
    double? fixedY,
  }) async {
    final existing = await getProfile(petId);
    if (existing == null) return;
    await saveProfile(existing.copyWith(
      area: area ?? existing.area,
      fixedX: fixedX,
      fixedY: fixedY,
    ));
  }

  /// 更新小人"双人互动被打断后动作"
  Future<void> updateProfileBreakAction(String petId, String actionId) async {
    final existing = await getProfile(petId);
    if (existing == null) return;
    await saveProfile(existing.copyWith(breakActionId: actionId));
  }

  @override
  Future<int> getAffection(String petId) async {
    final profile = await getProfile(petId);
    return profile?.affection ?? 0;
  }

  @override
  Future<int> addAffection(String petId, int delta) async {
    final before = await getAffection(petId);
    final after = before + delta;
    final existing = await getProfile(petId);
    await saveProfile((existing ?? PetProfile(petId: petId, name: petId))
        .copyWith(affection: after));
    return after;
  }

  // ========== 动作定义 ==========

  /// 某个角色的单人动作（归属收口统一入口——8-14 19:5x GPT 定案）。
  ///
  /// 所有"这个角色有哪些动作"的判断（配置页/测试列表/自主行动/idle）
  /// 都走这里，不再各自手写 profileId 过滤。
  /// 只返回普通动作（slot_id IS NULL），互动组坑动作走 slotActions(slotId)。
  Future<List<PetActionDef>> actionsForProfile(String profileId) async {
    final rows = await query('pet_actions',
        where: 'profile_id = ? AND slot_id IS NULL', whereArgs: [profileId]);
    return [for (final r in rows) _actionFromRow(r)];
  }

  Future<void> saveAction(PetActionDef def) async {
    final row = {
      'action_id': def.id,
      'name': def.name,
      'kind': def.kind.name,
      'fps': def.fps,
      'loop': def.loop.name,
      'frame_dir': def.frameDir,
      'frame_count': def.frameCount,
      'move_anim_id': def.moveAnimId,
      'target_spot': def.targetSpot?.name,
      'target_x': def.targetX,
      'target_y': def.targetY,
      'trajectory': def.trajectory.name,
      'move_duration': def.moveDurationSec,
      'move_dir': def.moveDir?.name,
      'move_dist': def.moveDist,
      'move_mode': def.moveMode.name,
      'move_sec': def.moveSec,
      'move_ref': def.moveRef.name,
      'start_x': def.startX,
      'start_y': def.startY,
      'speed_tier': def.speedTier.name,
      'move_group_id': def.moveGroupId,
      'duration_seconds': def.durationSeconds,
      // 8-14 18:4x（根因修复）：单人动作也写归属——profile_id=属于哪个角色、
      // slot_id=属于哪个互动组坑（普通动作 null，合法）。
      // 之前漏写 → 库里全 NULL → 测试列表/自主行动/idle 帧全被过滤掉
      'slot_id': def.slotId,
      'profile_id': def.profileId,
    };
    try {
      // ButlerStore.insert 内置 replace：新建插入，编辑同 id 覆盖
      await insert('pet_actions', row);
    } on DatabaseException {
      // 自愈兜底：老库可能缺新列（升级路径没补上），补一次表结构再重试
      // （createTables 幂等：IF NOT EXISTS + try/catch ALTER）
      await createTables(db);
      await insert('pet_actions', row);
    }
  }

  Future<List<PetActionDef>> allActions() async {
    final rows = await query('pet_actions');
    return rows.map(_actionFromRow).toList();
  }

  Future<void> removeAction(String actionId) async {
    await delete('pet_actions', where: 'action_id = ?', whereArgs: [actionId]);
  }

  PetActionDef _actionFromRow(Map<String, dynamic> r) => PetActionDef(
        id: r['action_id'] as String,
        name: r['name'] as String? ?? '',
        kind: PetActionKind.values.byName(r['kind'] as String? ?? 'inPlace'),
        fps: (r['fps'] as num?)?.toDouble() ?? 10,
        loop: PetAnimLoop.values.byName(r['loop'] as String? ?? 'loop'),
        frameDir: r['frame_dir'] as String?,
        profileId: r['profile_id'] as String?,
        slotId: r['slot_id'] as String?,
        frameCount: r['frame_count'] as int? ?? 0,
        moveAnimId: r['move_anim_id'] as String? ?? 'walk',
        targetSpot: r['target_spot'] != null
            ? PetSpot.values.byName(r['target_spot'] as String)
            : null,
        targetX: (r['target_x'] as num?)?.toDouble(),
        targetY: (r['target_y'] as num?)?.toDouble(),
        trajectory: PetMoveTrajectory.fromName(r['trajectory'] as String?) ??
            PetMoveTrajectory.walk,
        moveDurationSec: (r['move_duration'] as num?)?.toDouble() ?? 3,
        moveDir: PetMoveDir.fromName(r['move_dir'] as String?),
        moveDist: (r['move_dist'] as num?)?.toDouble(),
        // 8-14 22:2x（GPT 方案）：moveMode=distance/toEdge 分开语义。
        // 旧数据迁移：move_dist>=0.98（用户当时配"走到底"=满屏）→ toEdge
        moveMode: PetMoveMode.fromName(r['move_mode'] as String?) ==
                    PetMoveMode.toEdge
                ? PetMoveMode.toEdge
                : ((r['move_dist'] as num?)?.toDouble() ?? 0) >= 0.98
                    ? PetMoveMode.toEdge
                    : PetMoveMode.distance,
        moveSec: (r['move_sec'] as num?)?.toDouble(),
        moveRef: PetMoveRef.fromName(r['move_ref'] as String?),
        startX: (r['start_x'] as num?)?.toDouble(),
        startY: (r['start_y'] as num?)?.toDouble(),
        speedTier: PetSpeedTier.fromName(r['speed_tier'] as String?),
        moveGroupId: r['move_group_id'] as String?,
        durationSeconds: (r['duration_seconds'] as num?)?.toDouble() ?? 1,
      );

  // ========== 移动动画组 ==========

  Future<void> saveMoveGroup(PetMoveGroupDef def) async {
    await insert('pet_move_groups', {
      'group_id': def.id,
      'name': def.name,
      'walk_action_id': def.walkActionId,
      'run_action_id': def.runActionId,
    });
  }

  Future<List<PetMoveGroupDef>> allMoveGroups() async {
    final rows = await query('pet_move_groups');
    return rows
        .map((r) => PetMoveGroupDef(
              id: r['group_id'] as String,
              name: r['name'] as String? ?? '',
              walkActionId: r['walk_action_id'] as String? ?? 'walk',
              runActionId: r['run_action_id'] as String?,
            ))
        .toList();
  }

  Future<void> removeMoveGroup(String groupId) async {
    await delete('pet_move_groups',
        where: 'group_id = ?', whereArgs: [groupId]);
  }

  // ========== 组合动作 ==========

  Future<void> saveActivity(PetActivityDef def) async {
    await insert('pet_activities', {
      'activity_id': def.id,
      'name': def.name,
      'steps_json': jsonEncode(def.steps.map((s) => s.toJson()).toList()),
      if (def.startRef != null) 'start_ref': def.startRef!.name,
      if (def.startX != null) 'start_x': def.startX,
      if (def.startY != null) 'start_y': def.startY,
    });
  }

  Future<List<PetActivityDef>> allActivities() async {
    final rows = await query('pet_activities');
    return rows.map((r) {
      final steps = jsonDecode(r['steps_json'] as String? ?? '[]');
      return PetActivityDef(
        id: r['activity_id'] as String,
        name: r['name'] as String? ?? '',
        startRef: r['start_ref'] != null
            ? PetMoveRef.fromName(r['start_ref'] as String?)
            : null,
        startX: (r['start_x'] as num?)?.toDouble(),
        startY: (r['start_y'] as num?)?.toDouble(),
        steps: (steps as List<dynamic>)
            .map((e) => PetActivityStep.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    }).toList();
  }

  Future<void> removeActivity(String activityId) async {
    await delete(
      'pet_activities',
      where: 'activity_id = ?',
      whereArgs: [activityId],
    );
  }

  // ========== 双人互动配置 ==========

  Future<void> saveDuoConfig(PetDuoConfig config) async {
    await insert('pet_duo_configs', {
      'pair_id': config.pairId,
      'pet_a': config.petA,
      'pet_b': config.petB,
      'action_id': config.actionId,
    });
  }

  Future<List<PetDuoConfig>> duoConfigs() async {
    final rows = await query('pet_duo_configs');
    return rows
        .map((r) => PetDuoConfig(
              pairId: r['pair_id'] as String,
              petA: r['pet_a'] as String,
              petB: r['pet_b'] as String,
              actionId: r['action_id'] as String,
            ))
        .toList();
  }

  Future<void> removeDuoConfig(String pairId) async {
    await db.delete('pet_duo_configs',
        where: 'pair_id = ?', whereArgs: [pairId]);
  }

  // ========== 互动组（多角色剧本） ==========

  Future<void> saveGroup(PetGroupDef def) async {
    await insert('pet_groups', def.toJson());
  }

  Future<List<PetGroupDef>> allGroups() async {
    final rows = await query('pet_groups', orderBy: 'updated_at DESC');
    return rows.map((r) => PetGroupDef.fromJson(r)).toList();
  }

  /// 删除互动组：组 + 所有坑的动作（含帧图目录）
  Future<void> removeGroup(String groupId) async {
    final groups = await allGroups();
    final group = groups.where((g) => g.id == groupId).firstOrNull;
    if (group != null) {
      for (final slot in group.slots) {
        final actions = await slotActions(slot.slotId);
        for (final a in actions) {
          await removeSlotAction(a.id);
        }
      }
    }
    await db.delete('pet_groups', where: 'group_id = ?', whereArgs: [groupId]);
  }

  // ---- 坑的动作库（存在 pet_actions 里，slot_id 标记归属） ----

  Future<void> saveSlotAction(PetActionDef def) async {
    final row = {
      'action_id': def.id,
      'name': def.name,
      'kind': def.kind.name,
      'fps': def.fps,
      'loop': def.loop.name,
      'frame_dir': def.frameDir,
      'frame_count': def.frameCount,
      'move_anim_id': def.moveAnimId,
      'target_spot': def.targetSpot?.name,
      'target_x': def.targetX,
      'target_y': def.targetY,
      'trajectory': def.trajectory.name,
      'move_duration': def.moveDurationSec,
      'move_dir': def.moveDir?.name,
      'move_dist': def.moveDist,
      'move_sec': def.moveSec,
      'move_ref': def.moveRef.name,
      'start_x': def.startX,
      'start_y': def.startY,
      'speed_tier': def.speedTier.name,
      'move_group_id': def.moveGroupId,
      'duration_seconds': def.durationSeconds,
      'slot_id': def.slotId,
      'profile_id': def.profileId,
    };
    try {
      await insert('pet_actions', row);
    } on DatabaseException {
      // 自愈兜底：老库缺列时先补表结构再重试
      await createTables(db);
      await insert('pet_actions', row);
    }
  }

  /// 某个坑的动作库
  Future<List<PetActionDef>> slotActions(String slotId) async {
    final rows = await query('pet_actions',
        where: 'slot_id = ?', whereArgs: [slotId]);
    return rows.map((r) => _actionFromRow(r)).toList();
  }

  Future<void> removeSlotAction(String actionId) async {
    await removeAction(actionId);
    // 顺带清掉帧图目录，不留垃圾
    try {
      final support = await getApplicationSupportDirectory();
      final dir =
          Directory(p.join(support.path, 'pet', 'animations', actionId));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  // ========== 8-14 23:2x 状态绑定 / 跨角色联动 CRUD ==========

  Future<void> saveStateBinding(PetStateBinding b) async {
    await insert('pet_state_bindings', {
      'profile_id': b.profileId,
      'state_id': b.stateId,
      'source': b.source,
      'seq': b.seq,
      'enabled': b.enabled ? 1 : 0,
      'auto_detect': b.autoDetect ? 1 : 0,
      'priority': b.priority,
      'response_type': b.responseType,
      'response_id': b.responseId,
      'resume_after': b.resumeAfter ? 1 : 0,
    });
  }

  /// 某角色全部状态绑定（按 状态/来源/顺序 排序）
  Future<List<PetStateBinding>> stateBindingsFor(String profileId) async {
    final rows = await db.query('pet_state_bindings',
        where: 'profile_id = ?', whereArgs: [profileId],
        orderBy: 'state_id, source, seq');
    return rows.map((r) => PetStateBinding(
          profileId: r['profile_id'] as String,
          stateId: r['state_id'] as String,
          source: r['source'] as String? ?? 'auto',
          seq: r['seq'] as int? ?? 0,
          enabled: (r['enabled'] as int? ?? 1) == 1,
          autoDetect: (r['auto_detect'] as int? ?? 1) == 1,
          priority: r['priority'] as int? ?? 0,
          responseType: r['response_type'] as String? ?? PetResponseType.action,
          responseId: r['response_id'] as String?,
          resumeAfter: (r['resume_after'] as int? ?? 1) == 1,
        )).toList();
  }

  Future<void> deleteStateBinding(String profileId, String stateId,
      String source, int seq) async {
    await db.delete('pet_state_bindings', where: 'profile_id = ? AND state_id = ? AND source = ? AND seq = ?',
        whereArgs: [profileId, stateId, source, seq]);
  }

  Future<void> saveStateLink(PetStateLink l) async {
    await insert('pet_state_links', {
      'observer_id': l.observerId,
      'target_id': l.targetId,
      'target_state': l.targetState,
      'seq': l.seq,
      'enabled': l.enabled ? 1 : 0,
      'response_type': l.responseType,
      'response_id': l.responseId,
    });
  }

  /// B 观察到 A 的某状态 → 响应列表（按 seq）
  Future<List<PetStateLink>> stateLinksFor(
      String observerId, String targetId, String targetState) async {
    final rows = await db.query('pet_state_links',
        where: 'observer_id = ? AND target_id = ? AND target_state = ?',
        whereArgs: [observerId, targetId, targetState],
        orderBy: 'seq');
    return rows.map((r) => PetStateLink(
          observerId: r['observer_id'] as String,
          targetId: r['target_id'] as String,
          targetState: r['target_state'] as String,
          seq: r['seq'] as int? ?? 0,
          enabled: (r['enabled'] as int? ?? 1) == 1,
          responseType: r['response_type'] as String? ?? PetResponseType.action,
          responseId: r['response_id'] as String?,
        )).toList();
  }

  /// A 进入某状态时，所有观察者（全部联动，按 observer 分组）
  Future<List<PetStateLink>> stateLinksTargeting(
      String targetId, String targetState) async {
    final rows = await db.query('pet_state_links',
        where: 'target_id = ? AND target_state = ?',
        whereArgs: [targetId, targetState],
        orderBy: 'observer_id, seq');
    return rows.map((r) => PetStateLink(
          observerId: r['observer_id'] as String,
          targetId: r['target_id'] as String,
          targetState: r['target_state'] as String,
          seq: r['seq'] as int? ?? 0,
          enabled: (r['enabled'] as int? ?? 1) == 1,
          responseType: r['response_type'] as String? ?? PetResponseType.action,
          responseId: r['response_id'] as String?,
        )).toList();
  }

  Future<void> deleteStateLink(String observerId, String targetId,
      String targetState, int seq) async {
    await db.delete('pet_state_links',
        where: 'observer_id = ? AND target_id = ? AND target_state = ? AND seq = ?',
        whereArgs: [observerId, targetId, targetState, seq]);
  }


  // ========== 8-15 02:2x 全屏场景模式 P0 CRUD（16 号冲刺安排） ==========

  // ---- 场景 ----
  Future<void> saveScene(PetScene s) async {
    await insert('pet_scenes', {
      'scene_id': s.sceneId,
      'name': s.name,
      'bg_path': s.bgPath,
      'sort_order': s.sortOrder,
    });
  }

  Future<List<PetScene>> allScenes() async {
    final rows = await query('pet_scenes', orderBy: 'sort_order ASC');
    return rows
        .map((r) => PetScene(
              sceneId: r['scene_id'] as String,
              name: r['name'] as String,
              bgPath: r['bg_path'] as String?,
              sortOrder: (r['sort_order'] as int?) ?? 0,
            ))
        .toList();
  }

  Future<void> deleteScene(String sceneId) async {
    await delete('pet_scenes',
        where: 'scene_id = ?', whereArgs: [sceneId]);
    await delete('pet_nodes',
        where: 'scene_id = ?', whereArgs: [sceneId]);
    await delete('pet_hotspots',
        where: 'scene_id = ?', whereArgs: [sceneId]);
  }

  // ---- 节点 ----
  Future<void> saveNode(PetNode n) async {
    await insert('pet_nodes', {
      'node_id': n.nodeId,
      'scene_id': n.sceneId,
      'seq': n.seq,
      'type': n.type.name,
      'continue_type': n.continueType.name,
      'wait_user': n.waitUser ? 1 : 0,
      'content': n.content,
      'target_node': n.targetNode,
    });
  }

  Future<List<PetNode>> nodesForScene(String sceneId) async {
    final rows = await query('pet_nodes',
        where: 'scene_id = ?',
        whereArgs: [sceneId],
        orderBy: 'seq ASC');
    return rows
        .map((r) => PetNode(
              nodeId: r['node_id'] as String,
              sceneId: r['scene_id'] as String,
              seq: (r['seq'] as int?) ?? 0,
              type: PetNodeType.fromName(r['type'] as String?),
              continueType:
                  PetContinueType.fromName(r['continue_type'] as String?),
              waitUser: (r['wait_user'] as int?) == 1,
              content: r['content'] as String?,
              targetNode: r['target_node'] as String?,
            ))
        .toList();
  }

  Future<void> deleteNode(String nodeId) async {
    await delete('pet_nodes',
        where: 'node_id = ?', whereArgs: [nodeId]);
    await delete('pet_choices',
        where: 'node_id = ?', whereArgs: [nodeId]);
  }

  // ---- 选项 ----
  Future<void> saveChoice(PetChoice c) async {
    await insert('pet_choices', {
      'choice_id': c.choiceId,
      'node_id': c.nodeId,
      'seq': c.seq,
      'label': c.label,
      'target_node': c.targetNode,
    });
  }

  Future<List<PetChoice>> choicesForNode(String nodeId) async {
    final rows = await query('pet_choices',
        where: 'node_id = ?',
        whereArgs: [nodeId],
        orderBy: 'seq ASC');
    return rows
        .map((r) => PetChoice(
              choiceId: r['choice_id'] as String,
              nodeId: r['node_id'] as String,
              seq: (r['seq'] as int?) ?? 0,
              label: r['label'] as String,
              targetNode: r['target_node'] as String,
            ))
        .toList();
  }

  Future<void> deleteChoice(String choiceId) async {
    await delete('pet_choices',
        where: 'choice_id = ?', whereArgs: [choiceId]);
  }

  // ---- 热点 ----
  Future<void> saveHotspot(PetHotspot h) async {
    await insert('pet_hotspots', {
      'hotspot_id': h.hotspotId,
      'scene_id': h.sceneId,
      'type': h.type.name,
      'trigger': h.trigger.name,
      'pet_id': h.petId,
      'x': h.x,
      'y': h.y,
      'w': h.w,
      'h': h.h,
      'binding_type': h.bindingType,
      'binding_id': h.bindingId,
    });
  }

  Future<List<PetHotspot>> hotspotsForScene(String sceneId) async {
    final rows = await query('pet_hotspots',
        where: 'scene_id = ?',
        whereArgs: [sceneId],
        orderBy: 'type ASC');
    return rows
        .map((r) => PetHotspot(
              hotspotId: r['hotspot_id'] as String,
              sceneId: r['scene_id'] as String,
              type: PetHotspotType.fromName(r['type'] as String?),
              trigger: PetHotspotTrigger.fromName(r['trigger'] as String?),
              petId: r['pet_id'] as String?,
              x: (r['x'] as num?)?.toDouble() ?? 0.5,
              y: (r['y'] as num?)?.toDouble() ?? 0.5,
              w: (r['w'] as num?)?.toDouble() ?? 0.1,
              h: (r['h'] as num?)?.toDouble() ?? 0.1,
              bindingType: (r['binding_type'] as String?) ?? 'action',
              bindingId: r['binding_id'] as String,
            ))
        .toList();
  }

  Future<void> deleteHotspot(String hotspotId) async {
    await delete('pet_hotspots',
        where: 'hotspot_id = ?', whereArgs: [hotspotId]);
  }
}
