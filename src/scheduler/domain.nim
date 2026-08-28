## 中学排课领域模型
import std/json
import std/strutils
import std/monotimes
import std/random

randomize()

proc genId*(prefix: string): string =
  ## 生成简单唯一 id (单调时钟 + 随机数)
  prefix & "_" & $getMonoTime().ticks & "_" & $(rand(9999))

type
  Teacher* = object
    id*: string
    name*: string
    subjects*: seq[string]     ## 该教师可教授的科目 id 列表

  GradeClass* = object         ## 班级 (避免与 nim 关键字/类型冲突)
    id*: string
    name*: string
    grade*: string

  Subject* = object
    id*: string
    name*: string
    weeklyHours*: int          ## 默认周课时
    isMain*: bool              ## 是否主科(语数英等), 优先排上午

  Task* = object               ## 教学任务: 教师-班级-科目-周课时
    id*: string
    teacherId*: string
    classId*: string
    subjectId*: string
    hoursPerWeek*: int

  Params* = object
    daysPerWeek*: int          ## 每周上课天数 (5 或 6)
    periodsPerDay*: int        ## 每天总节数
    morningCount*: int         ## 上午节数

  Rule* = object               ## 排课规则 (来自 config/rules.json)
    subject*: string           ## 科目名
    teacher*: string           ## 教师名; 空串 = 该科目全体教师
    days*: seq[string]         ## 星期 ["一"] ; 空 = 所有天
    periods*: seq[int]         ## 节次 [2] (1-based) ; 空 = 全部节次
    kind*: string              ## "必排" | "不排" | "优先"
    comment*: string

  School* = object             ## 学校排课完整数据
    teachers*: seq[Teacher]
    classes*: seq[GradeClass]
    subjects*: seq[Subject]
    tasks*: seq[Task]
    params*: Params
    rules*: seq[Rule]

  Cell* = object
    taskId*: string            ## 为空字符串表示空闲
    locked*: bool              ## 是否锁定(禁调)

  Timetable* = object
    classId*: string
    grid*: seq[Cell]           ## 长度 = days*periods, 行主序: idx = day*periods + period

  ScheduleResult* = object
    ok*: bool
    message*: string
    score*: int
    timetables*: seq[Timetable]
    conflicts*: seq[string]    ## 未排上的课时描述

proc defaultParams*(): Params =
  Params(daysPerWeek: 5, periodsPerDay: 8, morningCount: 4)

# ---- 查找辅助 ----
proc findTeacher*(s: School; id: string): Teacher =
  for t in s.teachers:
    if t.id == id: return t
  result = Teacher(id: "", name: "(未知教师)")

proc findClass*(s: School; id: string): GradeClass =
  for c in s.classes:
    if c.id == id: return c
  result = GradeClass(id: "", name: "(未知班级)")

proc findSubject*(s: School; id: string): Subject =
  for x in s.subjects:
    if x.id == id: return x
  result = Subject(id: "", name: "(未知科目)")

proc teacherName*(s: School; tid: string): string = s.findTeacher(tid).name
proc className*(s: School; cid: string): string = s.findClass(cid).name
proc subjectName*(s: School; sid: string): string = s.findSubject(sid).name

proc taskById*(s: School; id: string): Task =
  for t in s.tasks:
    if t.id == id: return t
  result = Task(id: "", teacherId: "", classId: "", subjectId: "", hoursPerWeek: 0)

# ---- JSON 序列化 (使用 std/json 的 % 与 to) ----
proc toJson*(s: School): JsonNode =
  %s

proc schoolFromJson*(n: JsonNode): School =
  result = n.to(School)

# ---- 校验 ----
proc validate*(s: School): tuple[ok: bool, msg: string] =
  if s.classes.len == 0: return (false, "没有班级, 无法排课")
  if s.teachers.len == 0: return (false, "没有教师")
  if s.subjects.len == 0: return (false, "没有科目")
  if s.tasks.len == 0: return (false, "没有教学任务")
  if s.params.daysPerWeek < 1 or s.params.daysPerWeek > 7: return (false, "每周天数应在 1..7")
  if s.params.periodsPerDay < 1: return (false, "每天节数应 >= 1")
  if s.params.morningCount < 0 or s.params.morningCount > s.params.periodsPerDay:
    return (false, "上午节数设置不合理")
  let cap = s.params.daysPerWeek * s.params.periodsPerDay
  for c in s.classes:
    var h = 0
    for t in s.tasks:
      if t.classId == c.id: h += t.hoursPerWeek
    if h > cap:
      return (false, "班级 " & c.name & " 总课时 " & $h & " 超过可用时段 " & $cap)
  for t in s.tasks:
    if t.teacherId.len > 0 and s.findTeacher(t.teacherId).id == "":
      return (false, "任务引用了不存在的教师")
    if s.findClass(t.classId).id == "": return (false, "任务引用了不存在的班级")
    if s.findSubject(t.subjectId).id == "": return (false, "任务引用了不存在的科目")
  return (true, "ok")
