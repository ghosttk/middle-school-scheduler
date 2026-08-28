## 配置加载: 从 config/classes.json + config/rules.json 构建 School
## classes.json 为人可读的中间格式 (用名称而非 id); rules.json 为排课规则
import std/json
import std/os
import std/tables
import domain

proc configDir*(): string =
  ## 查找 config 目录优先级:
  ##   1) 环境变量 SCHEDULER_CONFIG
  ##   2) 当前工作目录下的 config
  ##   3) 可执行文件所在目录下的 config
  if existsEnv("SCHEDULER_CONFIG"):
    let p = getEnv("SCHEDULER_CONFIG")
    if dirExists(p): return p
  if dirExists("config"): return "config"
  let beside = getAppDir() / "config"
  if dirExists(beside): return beside
  result = "config"   # 兜底 (即便不存在, 上层会报文件缺失)

proc classesPath*(): string = configDir() / "classes.json"
proc rulesPath*(): string = configDir() / "rules.json"

proc loadClasses*(n: JsonNode): School =
  ## 由 classes.json 构建 School (名称 -> id 映射)
  result = School()
  result.params = Params(
    daysPerWeek: n["params"]["daysPerWeek"].getInt(5),
    periodsPerDay: n["params"]["periodsPerDay"].getInt(8),
    morningCount: n["params"]["morningCount"].getInt(4))
  # 科目 -> id 映射
  var subjId = initTable[string, string]()
  var si = 0
  for s in n["subjects"]:
    inc si
    let nm = s["name"].getStr()
    let isMain = if s.hasKey("isMain"): s["isMain"].getBool() else: false
    let sid = "S" & $si
    result.subjects.add(Subject(id: sid, name: nm,
      weeklyHours: s["weeklyHours"].getInt(0), isMain: isMain))
    subjId[nm] = sid
  # 班级 -> id 映射
  var classId = initTable[string, string]()
  var ci = 0
  for c in n["classes"]:
    inc ci
    let cid = "C" & $ci
    result.classes.add(GradeClass(id: cid, name: c["name"].getStr(),
      grade: c["grade"].getStr()))
    classId[c["name"].getStr()] = cid
  # 教师 -> id 映射 (教师可教科目由名称转 id)
  var tmap = initTable[string, string]()
  var ti = 0
  for t in n["teachers"]:
    inc ti
    let nm = t["name"].getStr()
    let tid = "T" & $ti
    tmap[nm] = tid
    var subs: seq[string] = @[]
    for s in t["subjects"]:
      let sn = s.getStr()
      if sn in subjId: subs.add(subjId[sn])
    result.teachers.add(Teacher(id: tid, name: nm, subjects: subs))
  # 教学任务
  var ki = 0
  for k in n["tasks"]:
    inc ki
    let cn = k["class"].getStr()
    let sn = k["subject"].getStr()
    let tn = k["teacher"].getStr()
    let h = k["hoursPerWeek"].getInt(0)
    if cn notin classId: continue
    if sn notin subjId: continue
    if tn notin tmap: continue
    result.tasks.add(Task(id: "K" & $ki, teacherId: tmap[tn],
      classId: classId[cn], subjectId: subjId[sn], hoursPerWeek: h))

proc loadRules*(sc: var School; n: JsonNode) =
  ## 装载规则; 对"必排"且科目不存在的全校事件(如升旗),
  ## 自动补建科目 + 每班一个无教师占位任务 (teacherId="")
  if n.isNil or not n.hasKey("rules"): return
  for r in n["rules"]:
    var rule = Rule(
      subject: r["subject"].getStr(),
      teacher: r["teacher"].getStr(),
      kind: r["kind"].getStr(),
      comment: if r.hasKey("comment"): r["comment"].getStr() else: "")
    if r.hasKey("days"):
      for d in r["days"]: rule.days.add(d.getStr())
    if r.hasKey("periods"):
      for p in r["periods"]: rule.periods.add(p.getInt())
    sc.rules.add(rule)
  # 必排全校事件 -> 补建科目与每班占位任务
  for rule in sc.rules:
    if rule.kind != "必排": continue
    var exists = false
    for s in sc.subjects:
      if s.name == rule.subject: exists = true; break
    if exists: continue
    let sid = "S" & $(sc.subjects.len + 1)
    sc.subjects.add(Subject(id: sid, name: rule.subject,
      weeklyHours: 1, isMain: false))
    for c in sc.classes:
      sc.tasks.add(Task(id: "K_" & rule.subject & "_" & c.id,
        teacherId: "", classId: c.id, subjectId: sid, hoursPerWeek: 1))

proc loadConfig*(): tuple[sc: School, ok: bool, msg: string] =
  let cf = classesPath()
  let rf = rulesPath()
  if not fileExists(cf):
    return (School(), false, "配置文件不存在: " & cf)
  try:
    let cn = parseFile(cf)
    result.sc = loadClasses(cn)
    if fileExists(rf):
      result.sc.loadRules(parseFile(rf))
    result.ok = true
    result.msg = "已加载配置 (classes=" & $result.sc.tasks.len & " 任务, " &
                 $result.sc.rules.len & " 条规则): " & cf
  except CatchableError as e:
    return (School(), false, "配置加载失败: " & e.msg)
