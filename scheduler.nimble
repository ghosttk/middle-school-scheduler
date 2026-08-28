# Package
version       = "1.0.0"
author        = "TRAE"
description   = "中学排课桌面软件 (Nim)"
license       = "MIT"
srcDir        = "src"
bin           = @["scheduler"]

# 任务: 内嵌 www/index.html 需要相对 src 目录定位
binDir = "bin"

requires "nim >= 2.0.0"
requires "xl >= 1.1.0"
requires "zippy >= 0.10.4"
