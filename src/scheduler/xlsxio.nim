## xlsx 配置载入 + 排课结果导出
## - 载入: config/classes.xlsx + config/rules.xlsx -> School
## - 导出: ScheduleResult -> 多 sheet xlsx 文件 (班级视图 + 教师视图)
import std/os
import std/strutils
import std/tables
import std/sequtils
import xl
import domain

# ============================================================
# 工具: 定位 config 目录 / 路径
# ============================================================
proc xlsxConfigDir*(): string =
  ## 查找 config 目录: 同 configloader 的策略
  if existsEnv("SCHEDULER_CONFIG"):
    let p = getEnv("SCHEDULER_CONFIG")
    if dirExists(p): return p
  if dirExists("config"): return "config"
  let beside = getAppDir() / "config"
  if dirExists(beside): return beside
  result = "config"

proc classesXlsxPath*(): string = xlsxConfigDir() / "classes.xlsx"
proc rulesXlsxPath*(): string   = xlsxConfigDir() / "rules.xlsx"

# 单元格值 -> 去首尾空白字符串
proc sv(cell: xl.XlCell): string =
  cell.value().strip()

# ============================================================
# classes.xlsx 格式
# ------------------------------------------------------------
# Sheet1 规则 (尽量贴近用户原模板):
#   A1: "参数" (可选; 以下键值写在 A2:B..)
#     A2=daysPerWeek      B2=5
#     A3=periodsPerDay    B3=8
#     A4=morningCount     B4=4
#   之后空一行或直接:
#   数据行 (前几行可能是填写说明, 会自动跳过, 以列A/B含 "年级"/"班级" 的行作表头)
#     Col1=年级 Col2=班级  Col3=科目 Col4=教师姓名 Col5=科目 Col6=教师姓名 ...
#     (科目、教师姓名交替, 成对出现)
# ============================================================

proc extractHoursRaw(raw: string): tuple[hours: int, rawForm: string] =
  ## 解析 "5" / "4+1" / "美工+劳技" 等
  ## 规则: 以 '+' 拆分, 左侧视为数字或连堂描述
  ##   若整串不含数字且含 '+', 视为"单双周科目拼接", 记课时 2 (默认各 1 节)
  result.rawForm = raw.strip()
  if result.rawForm.len == 0:
    result.hours = 0
    return
  var total = 0
  var hasDigit = false
  let parts = result.rawForm.split('+')
  for p in parts:
    let s = p.strip()
    if s.len == 0: continue
    if s.anyIt(it.isDigit):
      hasDigit = true
      # 数字串
      try: total += parseInt(s)
      except: discard
  if not hasDigit:
    # 纯文字科目拼接: 每部分算 1 节
    total = parts.filterIt(it.strip().len > 0).len
  result.hours = total

proc findHeaderRow(sh: xl.XlSheet): int =
  ## 找到表头行: A列或B列 精确等于 "年级" 且 右侧列精确等于 "班级" (兼容几种位置)
  for r in 1..50:
    let a = sh.cell(r, 1).sv
    let b = sh.cell(r, 2).sv
    let c = sh.cell(r, 3).sv
    # 形式一: A=年级 B=班级
    if a in ["年级", "级"] and (b in ["班级", "班"] or b.contains("班") and b.len <= 3):
      # 避免整行是说明文字 (过长): 要求两个单元格都短
      if a.len <= 6 and b.len <= 8:
        return r
    # 形式二: B=年级 C=班级
    if (b in ["年级", "级"]) and (c in ["班级", "班"] or c.contains("班") and c.len <= 3):
      if b.len <= 6 and c.len <= 8:
        return r
  result = 0

proc loadClassesXlsx*(path: string): tuple[sc: School, ok: bool, msg: string] =
  result.sc = School()
  if not fileExists(path):
    return (School(), false, "classes.xlsx 不存在: " & path)
  try:
    let wb = xl.load(path)
    if wb.len < 1:
      return (School(), false, "classes.xlsx 无 sheet")
    let sh = wb.sheet(0)
    # --- 参数区 ---
    var dpw = 5; var ppd = 8; var mc = 4
    for r in 1..20:
      let k = sh.cell(r, 1).sv
      let v = sh.cell(r, 2).sv
      if k.len == 0: continue
      if v.len == 0: continue
      case k.normalize()
      of "daysperweek", "每周天数", "days_per_week", "days":
        try: dpw = parseInt(v) except: dpw = 5
      of "periodsperday", "每天节数", "periods_per_day", "periods":
        try: ppd = parseInt(v) except: ppd = 8
      of "morningcount", "上午节数", "morning_count":
        try: mc = parseInt(v) except: mc = 4
      else: discard
    result.sc.params = Params(daysPerWeek: dpw, periodsPerDay: ppd, morningCount: mc)
    # --- 表头 ---
    let hdr = sh.findHeaderRow()
    if hdr == 0:
      return (School(), false, "classes.xlsx 未找到表头行(缺少" & "\"年级\"/\"班级\"列)")
    # 读取表头: 从第1列开始, 找出科目列与教师列的对应关系
    # 找到"班级"所在列 (colClass), 其右侧两列一组: (科目, 教师)
    var colClass = 2
    for c in 1..3:
      let v = sh.cell(hdr, c).sv
      if v.contains("班级") or v.contains("班"):
        colClass = c
        break
    let colGrade = colClass - 1   # 班级的左边是年级
    # 科目列表 (表头中的科目名, 唯一化后加入 subjects)
    type SubjCol = tuple[subjectCol: int, teacherCol: int, subjectName: string]
    var subjCols: seq[SubjCol] = @[]
    var maxCol = 2
    for c in (colClass + 1)..500:
      let subjName = sh.cell(hdr, c).sv
      if subjName.len == 0: break
      maxCol = c + 1
      if subjName.contains("教师"):
        # 跳过单独的教师列名
        continue
      # 正常: 科目在下一列就是教师姓名; 但用户模板是 科目、教师姓名、科目、教师姓名
      # 所以 subjName 是科目, 跳过 (c+1 列就是教师列)
      subjCols.add((c, c + 1, subjName))
    # 构建科目 (按表头出现顺序, 去重保留首次)
    var subjId = initTable[string, string]()
    var si = 0
    # 主科判定 (语数英物化)
    let mains = ["语文", "数学", "英语", "物理", "化学"]
    for sc2 in subjCols:
      if sc2.subjectName in subjId: continue
      inc si
      let sid = "S" & $si
      subjId[sc2.subjectName] = sid
      result.sc.subjects.add(Subject(id: sid, name: sc2.subjectName,
        weeklyHours: 0, isMain: (sc2.subjectName in mains)))
    # --- 数据行 ---
    var classId = initTable[string, string]()
    var ci = 0
    var tmap = initTable[string, string]()
    var ti = 0
    var ki = 0
    # 记录教师->科目集合, 最后回填 subjects
    var teacherSubjects = initTable[string, seq[string]]()
    for r in (hdr + 1)..1000:
      let gradeV = sh.cell(r, colGrade).sv
      let classNameV = sh.cell(r, colClass).sv
      if classNameV.len == 0 and gradeV.len == 0: break
      if classNameV.len == 0: continue
      # 班级
      let cid: string =
        if classNameV in classId: classId[classNameV]
        else:
          inc ci
          let id = "C" & $ci
          classId[classNameV] = id
          result.sc.classes.add(GradeClass(id: id, name: classNameV, grade: gradeV))
          id
      # 科目 + 教师 + 课时
      for sc2 in subjCols:
        let hoursRaw = sh.cell(r, sc2.subjectCol).sv
        let teacherV = sh.cell(r, sc2.teacherCol).sv
        let parsed = extractHoursRaw(hoursRaw)
        if parsed.hours <= 0: continue
        # 教师姓名: 支持 "A+B" 双师共享? 这里直接按单人姓名用; 含+号时按并集加入 teacherSubjects
        var tnames: seq[string] = @[]
        if teacherV.len == 0:
          tnames = @[""]
        else:
          tnames = teacherV.split('+').mapIt(it.strip()).filterIt(it.len > 0)
        if tnames.len == 0: tnames = @[""]
        let primaryT = tnames[0]
        # 注册教师
        var tid = ""
        if primaryT.len > 0:
          if primaryT notin tmap:
            inc ti
            tid = "T" & $ti
            tmap[primaryT] = tid
            result.sc.teachers.add(Teacher(id: tid, name: primaryT, subjects: @[]))
          else:
            tid = tmap[primaryT]
          # 关联科目
          let sid = subjId[sc2.subjectName]
          if not teacherSubjects.hasKey(primaryT): teacherSubjects[primaryT] = @[]
          if sid notin teacherSubjects[primaryT]:
            teacherSubjects[primaryT].add(sid)
        inc ki
        result.sc.tasks.add(Task(id: "K" & $ki,
          teacherId: tid,
          classId: cid,
          subjectId: subjId[sc2.subjectName],
          hoursPerWeek: parsed.hours))
    # 回填教师的 subjects
    for i in 0..<result.sc.teachers.len:
      let nm = result.sc.teachers[i].name
      if teacherSubjects.hasKey(nm):
        result.sc.teachers[i].subjects = teacherSubjects[nm]
    result.ok = true
    result.msg = "classes.xlsx 载入: " & $result.sc.classes.len & " 班, " &
                 $result.sc.teachers.len & " 教师, " &
                 $result.sc.subjects.len & " 科目, " &
                 $result.sc.tasks.len & " 任务"
  except CatchableError as e:
    return (School(), false, "classes.xlsx 解析失败: " & e.msg)

# ============================================================
# rules.xlsx 格式
# ------------------------------------------------------------
# Sheet1:
#   第1行可以是表头或填写说明, 自动定位含 "科目" 的行
#   列: 科目 | 教师 | 星期 | 节次 | 规则 | 备注(可选)
#   规则取值: 必排 / 不排 / 优先
#   空白单元格按默认 (教师=空=科目全体; 星期=全部天; 节次=全部节次)
# ============================================================

proc findRuleHeader(sh: xl.XlSheet): int =
  for r in 1..20:
    for c in 1..10:
      let v = sh.cell(r, c).sv
      # 严格匹配表头单元格(单元格值主要是 "科目"), 避免被说明行包含"科目"的文字命中
      if v == "科目" or v.strip() == "科目":
        return r
  result = 0

proc parseDays(s: string): seq[string] =
  result = @[]
  let t = s.strip()
  if t.len == 0: return
  # 支持 "一" / "一二" / "一,二" / "一 二 三" / "1,2,3"
  var src = t
  src = src.replace("，", ",")
  src = src.replace("、", ",")
  src = src.replace(" ", "")
  src = src.replace("周", "")
  src = src.replace("星期", "")
  let weekNames = ["一", "二", "三", "四", "五", "六", "日"]
  for ch in src:
    if ch == ',': continue
    if ch in {'1'..'7'}:
      let idx = parseInt($ch)
      if idx >= 1 and idx <= 7:
        result.add(weekNames[idx - 1])
    else:
      let cs = $ch
      if cs in weekNames and cs notin result:
        result.add(cs)

proc parsePeriods(s: string): seq[int] =
  result = @[]
  let t = s.strip()
  if t.len == 0: return
  var src = t
  src = src.replace("，", ",")
  src = src.replace("、", ",")
  src = src.replace(" ", ",")
  src = src.replace(";", ",")
  for part in src.split(','):
    let p = part.strip()
    if p.len == 0: continue
    # 范围 "1-5"
    if p.contains('-'):
      let ab = p.split('-')
      if ab.len == 2:
        try:
          let a = parseInt(ab[0].strip()); let b = parseInt(ab[1].strip())
          for x in min(a,b)..max(a,b):
            if x > 0 and x notin result: result.add(x)
        except: discard
      continue
    try:
      let x = parseInt(p)
      if x > 0 and x notin result: result.add(x)
    except: discard

proc loadRulesXlsx*(sc: var School; path: string): tuple[ok: bool, msg: string] =
  if not fileExists(path):
    return (true, "rules.xlsx 不存在, 跳过")
  try:
    let wb = xl.load(path)
    if wb.len < 1:
      return (false, "rules.xlsx 无 sheet")
    let sh = wb.sheet(0)
    let hdr = sh.findRuleHeader()
    if hdr == 0:
      return (false, "rules.xlsx 未找到表头 (缺\"科目\"列)")
    # 列定位: 科目,教师,星期,节次,规则,备注
    var col: array[0..5, int] = [0, 0, 0, 0, 0, 0]
    let keys = ["科目", "教师", "星期", "节次", "规则", "备注"]
    for c in 1..20:
      let v = sh.cell(hdr, c).sv
      for i, k in keys:
        if col[i] == 0 and v.contains(k):
          col[i] = c
    # 最低要求: 科目 + 规则
    if col[0] == 0: return (false, "rules.xlsx 未找到 科目列")
    if col[4] == 0: return (false, "rules.xlsx 未找到 规则列")
    proc getC(r: int, i: int): string =
      if col[i] == 0: return ""
      sh.cell(r, col[i]).sv
    for r in (hdr + 1)..1000:
      let subj = getC(r, 0)
      let kind = getC(r, 4)
      if subj.len == 0 and kind.len == 0: break
      if subj.len == 0: continue
      if kind.len == 0: continue
      let teacherV = getC(r, 1)
      let daysV = getC(r, 2)
      let perV = getC(r, 3)
      let cmt = getC(r, 5)
      var rule = Rule(subject: subj, teacher: teacherV,
        days: parseDays(daysV), periods: parsePeriods(perV),
        kind: kind, comment: cmt)
      sc.rules.add(rule)
    # 必排全校事件 -> 补建科目与占位任务 (等同 JSON loader 逻辑)
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
    return (true, "rules.xlsx 载入: " & $sc.rules.len & " 条规则")
  except CatchableError as e:
    return (false, "rules.xlsx 解析失败: " & e.msg)

proc loadConfigXlsx*(): tuple[sc: School, ok: bool, msg: string] =
  let cp = classesXlsxPath()
  let rp = rulesXlsxPath()
  let r1 = loadClassesXlsx(cp)
  if not r1.ok: return (School(), false, r1.msg)
  result.sc = r1.sc
  var msgTail = ""
  if fileExists(rp):
    let r2 = result.sc.loadRulesXlsx(rp)
    if not r2.ok: return (School(), false, r2.msg)
    msgTail = "; " & r2.msg
  result.ok = true
  result.msg = r1.msg & msgTail

# ============================================================
# 导出排课结果为 xlsx
# ============================================================

proc buildClassViewCells(sc: School, tt: Timetable): seq[seq[string]] =
  ## 返回 (periods+1) 行 x (days+1) 列 的二维表, 0行0列是表头
  let p = sc.params
  let days = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
  result = newSeq[seq[string]](p.periodsPerDay + 1)
  result[0] = newSeq[string](p.daysPerWeek + 1)
  result[0][0] = "节次 \\ 星期"
  for d in 0..<p.daysPerWeek: result[0][d + 1] = days[d]
  for per in 1..p.periodsPerDay:
    result[per] = newSeq[string](p.daysPerWeek + 1)
    result[per][0] = "第" & $per & "节"
    for d in 0..<p.daysPerWeek:
      let idx = d * p.periodsPerDay + (per - 1)
      if idx >= tt.grid.len:
        result[per][d + 1] = ""
        continue
      let c = tt.grid[idx]
      if c.taskId.len == 0:
        result[per][d + 1] = ""
      else:
        let tk = sc.taskById(c.taskId)
        let subj = sc.subjectName(tk.subjectId)
        let tnm = sc.teacherName(tk.teacherId)
        if tnm.len > 0:
          result[per][d + 1] = subj & "\n(" & tnm & ")"
        else:
          result[per][d + 1] = subj

proc buildTeacherViewCells(sc: School, tid: string,
                           tts: seq[Timetable]): seq[seq[string]] =
  let p = sc.params
  let days = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]
  result = newSeq[seq[string]](p.periodsPerDay + 1)
  result[0] = newSeq[string](p.daysPerWeek + 1)
  result[0][0] = "节次 \\ 星期"
  for d in 0..<p.daysPerWeek: result[0][d + 1] = days[d]
  for per in 1..p.periodsPerDay:
    result[per] = newSeq[string](p.daysPerWeek + 1)
    result[per][0] = "第" & $per & "节"
    for d in 0..<p.daysPerWeek:
      result[per][d + 1] = ""
  for tt in tts:
    for d in 0..<p.daysPerWeek:
      for per in 0..<p.periodsPerDay:
        let idx = d * p.periodsPerDay + per
        if idx >= tt.grid.len: continue
        let c = tt.grid[idx]
        if c.taskId.len == 0: continue
        let tk = sc.taskById(c.taskId)
        if tk.teacherId != tid: continue
        let subj = sc.subjectName(tk.subjectId)
        let cls = sc.className(tk.classId)
        let cellText = subj & "\n" & cls
        result[per + 1][d + 1] = cellText

proc writeGridToSheet(sheet: xl.XlSheet, grid: openArray[seq[string]]) =
  for r in 0..<grid.len:
    for c in 0..<grid[r].len:
      sheet.cell(r + 1, c + 1).value = grid[r][c]

proc exportResultToXlsx*(sc: School, res: ScheduleResult, path: string):
                          tuple[ok: bool, msg: string] =
  try:
    var wb = xl.newWorkbook()
    # --- 班级视图: 每班一个 sheet ---
    var sheetIdx = 0
    for tt in res.timetables:
      let cls = sc.findClass(tt.classId)
      var name = cls.name
      if name.len == 0: name = "班级" & tt.classId
      # Excel sheet 名最长 31 字符, 且不能有 :\/?*[]
      name = name.replace("/", "-").replace("\\", "-").replace(":", "-")
      name = name.replace("?", "").replace("*", "").replace("[", "(").replace("]", ")")
      if name.len > 31: name = name[0..30]
      var sh: xl.XlSheet
      if sheetIdx == 0:
        sh = wb.add("班级-" & name)
      else:
        sh = wb.add("班级-" & name)
      inc sheetIdx
      writeGridToSheet(sh, buildClassViewCells(sc, tt))
    # --- 教师视图: 每位教师一个 sheet ---
    for t in sc.teachers:
      # 仅当该教师被排课时才输出 (减少空表)
      var hasAny = false
      for tt in res.timetables:
        for c in tt.grid:
          if c.taskId.len == 0: continue
          let tk = sc.taskById(c.taskId)
          if tk.teacherId == t.id: hasAny = true; break
        if hasAny: break
      if not hasAny:
        # 还是输出, 避免教师列表不完整
        discard
      var name = t.name
      name = name.replace("/", "-").replace("\\", "-").replace(":", "-")
      name = name.replace("?", "").replace("*", "").replace("[", "(").replace("]", ")")
      if name.len > 30: name = name[0..29]
      let sh = wb.add("教师-" & name)
      writeGridToSheet(sh, buildTeacherViewCells(sc, t.id, res.timetables))
    # --- 概览 sheet (插在最前) ---
    let overview = wb.insert("概览", 0)
    overview.cell(1, 1).value = "中学排课结果"
    overview.cell(2, 1).value = "排课成功"
    overview.cell(2, 2).value = if res.ok: "是" else: "否"
    overview.cell(3, 1).value = "总分"
    overview.cell(3, 2).value = res.score
    overview.cell(4, 1).value = "消息"
    overview.cell(4, 2).value = res.message
    overview.cell(5, 1).value = "班级数"
    overview.cell(5, 2).value = sc.classes.len
    overview.cell(6, 1).value = "教师数"
    overview.cell(6, 2).value = sc.teachers.len
    overview.cell(7, 1).value = "科目数"
    overview.cell(7, 2).value = sc.subjects.len
    overview.cell(8, 1).value = "任务数"
    overview.cell(8, 2).value = sc.tasks.len
    if res.conflicts.len > 0:
      overview.cell(9, 1).value = "未排上的课时"
      for i, cc in res.conflicts:
        overview.cell(10 + i, 1).value = cc
    wb.save(path)
    return (true, "已导出 Excel: " & path)
  except CatchableError as e:
    return (false, "导出 Excel 失败: " & e.msg)
