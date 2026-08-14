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
      'move_sec': def.moveSec,
      'move_ref': def.moveRef.name,
      'start_x': def.startX,
      'start_y': def.startY,
      'speed_tier': def.speedTier.name,
      'move_group_id': def.moveGroupId,
      'duration_seconds': def.durationSeconds,
    };
    try {
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
}
