## HTTP API + 内嵌前端单页应用
import std/asynchttpserver
import std/asyncdispatch
import std/json
import domain
import store
import timetable

# 编译期内嵌 www/index.html
const IndexHtml {.strdefine.} = staticRead("../../www/index.html")

type
  Api* = ref object
    store*: Store
    port*: int

proc newApi*(port: int): Api =
  result = Api(store: newStore(), port: port)

# ---- 响应工具 ----
proc sendText(req: Request; code: HttpCode; body: string;
              ct = "application/json; charset=utf-8") {.async.} =
  await req.respond(code, body,
    newHttpHeaders([("Content-Type", ct),
                    ("Access-Control-Allow-Origin", "*"),
                    ("Access-Control-Allow-Methods", "GET,POST,OPTIONS"),
                    ("Access-Control-Allow-Headers", "Content-Type")]))

proc sendOk(req: Request; node: JsonNode) {.async.} =
  await req.sendText(Http200, $node)

proc sendErr(req: Request; msg: string; code = Http400) {.async.} =
  await req.sendText(code, $(%*{"ok": false, "msg": msg}))

# ---- 路由分发 ----
proc handle(req: Request, api: Api): Future[void] {.async.} =
  let path = req.url.path
  if req.reqMethod == HttpGet:
    if path == "/" or path == "/index.html":
      await req.sendText(Http200, IndexHtml, "text/html; charset=utf-8")
      return
    if path == "/api/state":
      await req.sendOk(api.store.fullStateJson())
      return
    await req.sendErr("not found: " & path, Http404)
    return
  if req.reqMethod == HttpPost:
    try:
      if path == "/api/save-school":
        let n = parseJson(req.body)
        api.store.school = schoolFromJson(n)
        api.store.dirty = true
        await req.sendOk(%*{"ok": true, "msg": "数据已更新"})
        return
      if path == "/api/schedule":
        api.store.result = runSchedule(api.store.school)
        await req.sendOk(%*{"ok": true,
            "msg": api.store.result.message,
            "placed": api.store.result.ok})
        return
      if path == "/api/swap":
        let n = parseJson(req.body)
        let cid = n["classId"].getStr()
        let a = n["slotA"].getInt()
        let b = n["slotB"].getInt()
        let r = swapCells(api.store.school, api.store.result.timetables, cid, a, b)
        let cf = validateTimetables(api.store.school, api.store.result.timetables)
        await req.sendOk(%*{"ok": r.ok, "msg": r.msg, "conflicts": cf})
        return
      if path == "/api/set-cell":
        let n = parseJson(req.body)
        let cid = n["classId"].getStr()
        let slot = n["slot"].getInt()
        let tid = n["taskId"].getStr()
        let r = setCell(api.store.school, api.store.result.timetables,
                        cid, slot, tid)
        let cf = validateTimetables(api.store.school, api.store.result.timetables)
        await req.sendOk(%*{"ok": r.ok, "msg": r.msg, "conflicts": cf})
        return
      if path == "/api/persist":
        let r = api.store.saveToDisk()
        await req.sendOk(%*{"ok": r.ok, "msg": r.msg})
        return
      if path == "/api/load":
        let r = api.store.loadFromDisk()
        await req.sendOk(%*{"ok": r.ok, "msg": r.msg})
        return
      if path == "/api/sample":
        api.store.loadSample()
        await req.sendOk(%*{"ok": true, "msg": "已载入示例数据"})
        return
      if path == "/api/clear":
        api.store.result = ScheduleResult(ok: false, message: "已清空排课", score: 0)
        await req.sendOk(%*{"ok": true, "msg": "已清空排课结果"})
        return
      await req.sendErr("unknown route: " & path, Http404)
      return
    except CatchableError as e:
      await req.sendErr("服务器处理出错: " & e.msg)
      return
  await req.sendErr("method not allowed", Http405)

proc handleSafe(req: Request, api: Api) {.async.} =
  try:
    await handle(req, api)
  except CatchableError as e:
    try: await req.sendErr("内部错误: " & e.msg) except: discard

proc serve*(api: Api) {.async.} =
  let server = newAsyncHttpServer()
  let port = Port(api.port)
  echo "排课服务启动: http://127.0.0.1:" & $api.port & "/"
  proc cb(req: Request): Future[void] {.async.} =
    await handleSafe(req, api)
  await server.serve(port, cb, "127.0.0.1")
