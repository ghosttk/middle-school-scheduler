## 数据存储: 内存状态 + 磁盘 JSON 持久化 + 示例数据
import std/json
import std/os
import std/sequtils
import domain

type
  Store* = ref object
    school*: School
    result*: ScheduleResult         ## 最近一次排课结果
    dirty*: bool

proc newStore*(): Store =
  result = Store()
  result.school.params = defaultParams()

proc dataFile*(s: Store): string =
  ## 数据文件路径: 用户主目录下
  let dir = getHomeDir() / ".paimai"
  discard existsOrCreateDir(dir)
  result = dir / "school.json"

# ---- 持久化 ----
proc saveToDisk*(s: Store): tuple[ok: bool, msg: string] =
  try:
    let f = s.dataFile()
    writeFile(f, pretty(s.school.toJson()))
    s.dirty = false
    return (true, "已保存到 " & f)
  except CatchableError as e:
    return (false, "保存失败: " & e.msg)

proc loadFromDisk*(s: Store): tuple[ok: bool, msg: string] =
  let f = s.dataFile()
  if not fileExists(f):
    return (false, "数据文件不存在: " & f)
  try:
    let n = parseFile(f)
    s.school = schoolFromJson(n)
    return (true, "已加载 " & f)
  except CatchableError as e:
    return (false, "加载失败: " & e.msg)

# ---- JSON 输出 ----
proc fullStateJson*(s: Store): JsonNode =
  ## 返回前端需要的完整状态 (含排课结果)
  var obj = newJObject()
  obj["school"] = s.school.toJson()
  var r = newJObject()
  r["ok"] = %s.result.ok
  r["message"] = %s.result.message
  r["score"] = %s.result.score
  r["conflicts"] = %s.result.conflicts
  var tarr = newJArray()
  for tt in s.result.timetables:
    var to = newJObject()
    to["classId"] = %tt.classId
    var g = newJArray()
    for c in tt.grid:
      var co = newJObject()
      co["taskId"] = %c.taskId
      co["locked"] = %c.locked
      g.add(co)
    to["grid"] = g
    tarr.add(to)
  r["timetables"] = tarr
  obj["result"] = r
  return obj

# ---- 示例数据 ----
proc loadSample*(s: Store) =
  ## 载入一份典型的中学示例数据
  var sc = School()
  sc.params = Params(daysPerWeek: 5, periodsPerDay: 8, morningCount: 4)

  # 科目
  let subjectsDef = [
    ("语文", 6, true), ("数学", 6, true), ("英语", 5, true),
    ("物理", 3, true), ("化学", 3, true), ("生物", 2, false),
    ("政治", 2, false), ("历史", 2, false), ("地理", 2, false),
    ("体育", 2, false), ("音乐", 1, false), ("美术", 1, false),
    ("信息技术", 1, false)
  ]
  for i, d in subjectsDef:
    sc.subjects.add(Subject(id: "S" & $(i+1), name: d[0], weeklyHours: d[1], isMain: d[2]))

  # 班级 (2 个年级, 每年级 3 个班)
  let grades = ["七年级", "八年级"]
  var cidx = 0
  for g in grades:
    for n in 1..3:
      inc cidx
      sc.classes.add(GradeClass(id: "C" & $cidx, name: g & $(n) & "班", grade: g))

  # 教师 (每个科目 1~2 名教师, 跨班任教)
  var tidx = 0
  # 语文2人 数学2人 英语2人 其它各1人
  let teacherPlan = [
    ("语文", 2), ("数学", 2), ("英语", 2), ("物理", 1), ("化学", 1),
    ("生物", 1), ("政治", 1), ("历史", 1), ("地理", 1), ("体育", 1),
    ("音乐", 1), ("美术", 1), ("信息技术", 1)
  ]
  let surnames = ["张", "王", "李", "赵", "刘", "陈", "杨", "黄", "周", "吴", "徐", "孙", "马", "朱", "胡"]
  for tp in teacherPlan:
    let subjId = sc.subjects.filterIt(it.name == tp[0])[0].id
    for k in 1..tp[1]:
      inc tidx
      let tn = surnames[(tidx-1) mod surnames.len] & tp[0] & ($k)
      let tid = "T" & $tidx
      sc.teachers.add(Teacher(id: tid, name: tn, subjects: @[subjId]))

  # 教学任务: 给每个班级按科目排足课时; 同科目多名教师时按班级轮流分配
  var tcounter = 0
  for ci, c in sc.classes:
    for subj in sc.subjects:
      var cands: seq[Teacher] = @[]
      for t in sc.teachers:
        if subj.id in t.subjects: cands.add(t)
      if cands.len == 0: continue
      let teacher = cands[ci mod cands.len]   # 班级序号轮流选教师, 平摊负担
      inc tcounter
      sc.tasks.add(Task(id: "K" & $tcounter, teacherId: teacher.id,
                       classId: c.id, subjectId: subj.id,
                       hoursPerWeek: subj.weeklyHours))
  s.school = sc
  s.result = ScheduleResult(ok: false, message: "尚未排课", score: 0)
  s.dirty = true
