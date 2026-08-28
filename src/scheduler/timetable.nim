## 排课算法: 随机贪心构造 + 多次重启, 软约束评分择优; 硬约束(教师冲突/班级单时段单课)零容忍
import std/tables
import std/algorithm
import std/sequtils
import std/random
import domain

const MaxAttempts = 80   ## 重启次数上限

type
  Solver = object
    sc: School
    nSlots: int
    periods: int
    days: int
    morning: int
    # 教师在每个时段是否被占用
    busy: Table[string, seq[bool]]
    # 每个班级的科目当天计数: key = classId & "_" & subjectId, value = seq[days] of int
    dayCnt: Table[string, seq[int]]
    subjDaysUsed: Table[string, seq[int]]  # 每个班级-科目已用天数集合计数

proc initSolver(s: School): Solver =
  result.sc = s
  result.days = s.params.daysPerWeek
  result.periods = s.params.periodsPerDay
  result.morning = s.params.morningCount
  result.nSlots = result.days * result.periods

proc dayOfSlot(s: Solver; idx: int): int = idx div s.periods
proc periodOfSlot(s: Solver; idx: int): int = idx mod s.periods

proc teacherBusySet(s: var Solver; tid: string): var seq[bool] =
  if tid notin s.busy:
    s.busy[tid] = newSeq[bool](s.nSlots)
  result = s.busy[tid]

proc isTeacherFree(s: Solver; tid: string; slot: int): bool =
  if tid notin s.busy: return true
  result = not s.busy[tid][slot]

proc subjectKey(classId, subjectId: string): string = classId & "|" & subjectId

proc dayCounts(s: var Solver; key: string): var seq[int] =
  if key notin s.dayCnt:
    s.dayCnt[key] = newSeq[int](s.days)
  result = s.dayCnt[key]

# ---- 排课规则辅助 ----
proc dayIndexOf(d: string): int =
  ## 星期中文 -> 0 基索引 (一=0 .. 日=6)
  case d
  of "一": 0
  of "二": 1
  of "三": 2
  of "四": 3
  of "五": 4
  of "六": 5
  of "日", "天": 6
  else: -1

proc ruleMatchesSlot(rule: Rule; day, period0: int): bool =
  ## period0 为 0 基节次; rule.periods 为 1 基
  if rule.days.len > 0:
    var ok = false
    for d in rule.days:
      if dayIndexOf(d) == day: ok = true; break
    if not ok: return false
  if rule.periods.len > 0:
    var ok = false
    let p1 = period0 + 1
    for p in rule.periods:
      if p == p1: ok = true; break
    if not ok: return false
  result = true

proc ruleAppliesToTask(rule: Rule; sc: School; task: Task): bool =
  let subj = sc.findSubject(task.subjectId)
  if subj.id == "": return false
  if rule.subject != subj.name: return false
  if rule.teacher.len > 0:
    let tch = sc.findTeacher(task.teacherId)
    if tch.id == "" or tch.name != rule.teacher: return false
  result = true

proc slotForbidden(sc: School; task: Task; day, period0: int): bool =
  ## 不排: 该任务不得落在该时段
  for rule in sc.rules:
    if rule.kind != "不排": continue
    if ruleAppliesToTask(rule, sc, task) and ruleMatchesSlot(rule, day, period0):
      return true
  result = false

proc slotPreferred(sc: School; task: Task; day, period0: int): bool =
  ## 优先: 该任务落在此时段可加分
  for rule in sc.rules:
    if rule.kind != "优先": continue
    if ruleAppliesToTask(rule, sc, task) and ruleMatchesSlot(rule, day, period0):
      return true
  result = false

# ---- 评分单个候选时段 ----
proc scoreSlot(s: Solver; sc: School; task: Task; slot: int; dayCnt: int;
               usedDays: int): int =
  let subj = sc.findSubject(task.subjectId)
  let period = s.periodOfSlot(slot)
  var scr = 0
  # 主科优先上午
  if subj.isMain and period < s.morning: scr += 10
  elif (not subj.isMain) and period >= s.morning: scr += 4
  elif (not subj.isMain) and period < s.morning: scr -= 3
  # 当天该科目已有节数: 越少越好
  case dayCnt
  of 0: scr += 6
  of 1: scr += 1
  else: scr -= 25          # 同一天第3节及以上重罚
  # 已用不同天数越多越好(分散)
  scr += min(usedDays, 3)
  # 避免最后一节(下午末)排主科
  if period == s.periods - 1 and subj.isMain: scr -= 4
  # 优先规则: 落入指定时段加分
  if slotPreferred(sc, task, s.dayOfSlot(slot), period): scr += 8
  result = scr

# ---- 单次构造 ----
proc construct(s: var Solver): tuple[placed: int, total: int, grids: seq[seq[Cell]]] =
  ## 返回每班级的 grid
  var grids = newSeq[seq[Cell]](s.sc.classes.len)
  for ci in 0..<s.sc.classes.len:
    grids[ci] = newSeq[Cell](s.nSlots)
  var placed = 0
  var total = 0
  # ---- 必排: 预占并锁定 (如升旗: 每周一第2节) ----
  for ci in 0..<s.sc.classes.len:
    let cl = s.sc.classes[ci]
    for rule in s.sc.rules:
      if rule.kind != "必排": continue
      var ph: Task
      var got = false
      for t in s.sc.tasks:
        if t.classId == cl.id and t.teacherId == "" and
           s.sc.findSubject(t.subjectId).name == rule.subject:
          ph = t; got = true; break
      if not got: continue
      let dIdx = if rule.days.len > 0: dayIndexOf(rule.days[0]) else: 0
      let pIdx = if rule.periods.len > 0: rule.periods[0] - 1 else: 0
      if dIdx < 0: continue
      let slot = dIdx * s.periods + pIdx
      if slot >= 0 and slot < s.nSlots and grids[ci][slot].taskId == "":
        grids[ci][slot].taskId = ph.id
        grids[ci][slot].locked = true
        inc placed
        inc total
  # 班级按总课时降序 (预计算, 避免闭包捕获 var Solver)
  let nClasses = s.sc.classes.len
  let classHours = block:
    var r = newSeq[int](nClasses)
    for i in 0..<nClasses:
      var h = 0
      for t in s.sc.tasks:
        if t.classId == s.sc.classes[i].id: inc h, t.hoursPerWeek
      r[i] = h
    r
  var order = toSeq(0..<nClasses)
  order.sort(proc(a, b: int): int = cmp(classHours[b], classHours[a]))
  # 预构建主科映射, 供排序闭包使用 (避免捕获 var Solver)
  let isMainOf = block:
    var t = initTable[string, bool]()
    for x in s.sc.subjects: t[x.id] = x.isMain
    t
  for ci in order:
    let cl = s.sc.classes[ci]
    # 收集该班级所有课时实例 (主科优先)
    var lessons: seq[Task] = @[]
    for t in s.sc.tasks:
      if t.classId != cl.id: continue
      if t.teacherId == "": continue   # 必排占位任务已预排, 不再当作普通课时
      for _ in 1..t.hoursPerWeek:
        lessons.add(t)
    inc total, lessons.len
    # 主科排前
    lessons.sort(proc(a, b: Task): int =
      cmp(isMainOf.getOrDefault(b.subjectId), isMainOf.getOrDefault(a.subjectId)))
    for tk in lessons:
      var cands: seq[int] = @[]
      for slot in 0..<s.nSlots:
        if grids[ci][slot].taskId != "": continue
        if not s.isTeacherFree(tk.teacherId, slot): continue
        if slotForbidden(s.sc, tk, s.dayOfSlot(slot), s.periodOfSlot(slot)): continue
        cands.add(slot)
      if cands.len == 0:
        continue   # 该课时无法安置, 留空 -> 计入冲突
      # 选最优时段
      var best = -1000
      var bestSlots: seq[int] = @[]
      let key = subjectKey(cl.id, tk.subjectId)
      let dc = if key in s.dayCnt: s.dayCnt[key] else: newSeq[int](s.days)
      var used = 0
      for v in dc:
        if v > 0: inc used
      for slot in cands:
        let day = s.dayOfSlot(slot)
        let scv = s.scoreSlot(s.sc, tk, slot, dc[day], used) + rand(2)
        if scv > best:
          best = scv; bestSlots = @[slot]
        elif scv == best:
          bestSlots.add(slot)
      let chosen = bestSlots[rand(bestSlots.high)]
      grids[ci][chosen].taskId = tk.id
      s.teacherBusySet(tk.teacherId)[chosen] = true
      s.dayCounts(key)[s.dayOfSlot(chosen)].inc
      inc placed
  result = (placed, total, grids)

# ---- 全局评分 ----
proc globalScore(s: Solver; grids: seq[seq[Cell]]): int =
  var score = 0
  for ci, cl in s.sc.classes:
    let grid = grids[ci]
    # 当天科目重复统计
    var daySubj = newSeq[seq[string]](s.days)
    for d in 0..<s.days: daySubj[d] = @[]
    for slot, c in grid:
      if c.taskId == "": continue
      let t = s.sc.taskById(c.taskId)
      let subj = s.sc.findSubject(t.subjectId)
      let day = s.dayOfSlot(slot)
      let per = s.periodOfSlot(slot)
      if subj.isMain and per < s.morning: inc score, 10
      if subj.isMain and per == s.periods - 1: dec score, 4
      if slotPreferred(s.sc, t, day, per): inc score, 8
      daySubj[day].add(t.subjectId)
    for d in 0..<s.days:
      var seen: CountTable[string]
      for x in daySubj[d]: seen.inc(x)
      for k, v in pairs(seen):
        if v >= 2: dec score, (v - 1) * 8     # 同日同科多节惩罚
        inc score, 1                          # 不同科加分(分散)
    # 科目跨天分散加分
    var subjDays: Table[string, int]
    for d in 0..<s.days:
      var dseen: Table[string, bool]
      for x in daySubj[d]: dseen[x] = true
      for k in keys(dseen): subjDays.mgetOrPut(k, 0).inc
    for k, v in pairs(subjDays): inc score, v * 3
  result = score

# ---- 主入口 ----
proc runSchedule*(sc: School): ScheduleResult =
  let v = sc.validate()
  if not v.ok:
    return ScheduleResult(ok: false, message: "校验失败: " & v.msg, score: 0,
                          timetables: @[], conflicts: @["校验失败: " & v.msg])
  var bestGrids: seq[seq[Cell]] = @[]
  var bestScore = low(int)
  var bestPlaced = -1
  var bestTotal = 0
  for attempt in 1..MaxAttempts:
    var solver = initSolver(sc)
    let (placed, total, grids) = solver.construct()
    let g = solver.globalScore(grids)
    # 优先比较完成率, 其次软分
    let rankKey = placed * 10000 + g
    var bestKey = if bestPlaced < 0: low(int) else: bestPlaced * 10000 + bestScore
    if rankKey > bestKey:
      bestPlaced = placed
      bestTotal = total
      bestScore = g
      bestGrids = grids
    if placed == total and g > 0:
      # 已完整且分数不错, 仍有预算则继续找更好; 但若连续多次没改善可早停
      discard
  var res = ScheduleResult(ok: bestPlaced == bestTotal and bestTotal > 0,
                           score: bestScore,
                           timetables: @[], conflicts: @[],
                           message: "")
  for ci, cl in sc.classes:
    var tt = Timetable(classId: cl.id, grid: bestGrids[ci])
    res.timetables.add(tt)
  if bestPlaced < bestTotal:
    res.ok = false
    res.message = "排课完成 " & $bestPlaced & "/" & $bestTotal & " 节, 存在冲突, 请调整教学任务或参数后重试"
    res.conflicts.add("未排上 " & $(bestTotal - bestPlaced) & " 节")
  else:
    res.message = "排课完成, 共 " & $bestTotal & " 节, 软约束评分 " & $bestScore
  result = res

# ---- 校验: 教师是否有冲突 ----
proc validateTimetables*(sc: School; tts: seq[Timetable]): seq[string] =
  var conflicts: seq[string] = @[]
  # 教师 -> 已占用时段
  var occ: Table[string, Table[int, string]]   # tid -> slot -> classId
  for tt in tts:
    for slot, c in tt.grid:
      if c.taskId == "": continue
      let t = sc.taskById(c.taskId)
      if t.teacherId == "": continue
      if t.teacherId notin occ: occ[t.teacherId] = initTable[int, string]()
      if slot in occ[t.teacherId]:
        conflicts.add("教师 " & sc.findTeacher(t.teacherId).name & " 在时段 " &
                      $slot & " 被班级 " & sc.findClass(tt.classId).name &
                      " 与 " & sc.findClass(occ[t.teacherId][slot]).name & " 重复占用")
      else:
        occ[t.teacherId][slot] = tt.classId
  result = conflicts

# ---- 调课: 交换同班级两个时段 ----
proc swapCells*(sc: School; tts: var seq[Timetable]; classId: string;
                slotA, slotB: int): tuple[ok: bool, msg: string] =
  if slotA == slotB: return (true, "无需交换")
  var idx = -1
  for i, tt in tts:
    if tt.classId == classId: idx = i; break
  if idx < 0: return (false, "班级不存在")
  if slotA < 0 or slotA >= tts[idx].grid.len or slotB < 0 or slotB >= tts[idx].grid.len:
    return (false, "时段越界")
  let ca = tts[idx].grid[slotA]
  let cb = tts[idx].grid[slotB]
  if ca.locked or cb.locked: return (false, "存在锁定的时段, 禁止交换")
  let tmp = tts[idx].grid[slotA]
  tts[idx].grid[slotA] = tts[idx].grid[slotB]
  tts[idx].grid[slotB] = tmp
  let cf = validateTimetables(sc, tts)
  if cf.len > 0:
    # 回退
    tts[idx].grid[slotA] = ca
    tts[idx].grid[slotB] = cb
    return (false, "交换后产生教师冲突: " & cf[0])
  return (true, "已交换")

# ---- 切换某单元格科目 (调课: 改填) ----
proc setCell*(sc: School; tts: var seq[Timetable]; classId: string;
              slot: int; taskId: string): tuple[ok: bool, msg: string] =
  var idx = -1
  for i, tt in tts:
    if tt.classId == classId: idx = i; break
  if idx < 0: return (false, "班级不存在")
  if slot < 0 or slot >= tts[idx].grid.len: return (false, "时段越界")
  let old = tts[idx].grid[slot]
  tts[idx].grid[slot].taskId = taskId
  let cf = validateTimetables(sc, tts)
  if cf.len > 0:
    tts[idx].grid[slot] = old
    return (false, "设置后产生教师冲突: " & cf[0])
  return (true, "已设置")
