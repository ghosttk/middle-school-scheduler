## 中学排课桌面软件 - 入口
## 启动内嵌 HTTP 服务并自动打开系统浏览器
import std/os
import std/asyncdispatch
import std/strutils
import std/browsers
import domain
import store
import httpapi

proc help() =
  echo "用法: scheduler [端口号]"
  echo "示例: scheduler 8765"
  echo "默认端口: 8765"

proc main() =
  var port = 8765
  let args = commandLineParams()
  if args.len > 0:
    if args[0] in ["-h", "--help", "help"]:
      help(); return
    try: port = parseInt(args[0])
    except: echo "端口非法, 使用默认 8765"; port = 8765

  let api = newApi(port)

  # 启动时尝试加载磁盘数据; 若无则载入示例数据方便首次使用
  let r = api.store.loadFromDisk()
  if r.ok:
    echo r.msg
  else:
    echo "未找到历史数据, 载入示例数据: " & r.msg
    api.store.loadSample()
    discard api.store.saveToDisk()

  let url = "http://127.0.0.1:" & $port & "/"
  echo "若浏览器未自动打开, 请手动访问: " & url

  # 尽力打开默认浏览器 (无图形界面环境会失败, 忽略)
  try:
    openDefaultBrowser(url)
  except CatchableError:
    discard

  # 阻塞运行服务
  waitFor api.serve()

when isMainModule:
  main()
