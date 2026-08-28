# 中学排课系统（Nim 桌面应用）

![CI](https://github.com/ghosttk/middle-school-scheduler/actions/workflows/release.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Nim](https://img.shields.io/badge/Nim-2.2.10-ffe953.svg)

一个用 [Nim](https://nim-lang.org) 编写的中学排课桌面软件。单一可执行文件，内嵌 HTTP 服务 + 单页前端（HTML/CSS/JS 编译期嵌入），启动后自动打开系统浏览器——零原生 GUI 依赖、跨平台。

## 功能特性

- **基础数据管理**：科目（含周课时/是否主科）、班级、教师（可教科目）、教学任务（教师-班级-科目-周课时）增删
- **排课参数**：每周天数、每天节数、上午节数
- **一键排课**：随机贪心构造 + 多次重启 + 软约束评分择优
  - 硬约束零容忍：教师不冲突、班级单时段单课
  - 软约束：主科优先排上午、同日同科不超过 2 节、科目跨天分散
- **课表查看**：班级课表 / 教师课表 两种视图
- **调课**：点击同班级两个单元格交换，自动校验教师冲突并回退
- **数据持久化**：保存/加载到 `~/.paimai/school.json`，内置示例数据一键载入

## 环境要求

- Nim ≥ 2.0（推荐 2.2.x）
- C 编译器：`gcc` 或 `clang`

## 快速开始

```bash
# 安装依赖 (xl / zippy)
nimble refresh
nimble install xl zippy -y

# 构建
nim c -d:release --mm:orc --threads:off -o:bin/scheduler src/scheduler/main.nim

# 运行（默认 8765 端口，自动打开浏览器）
./bin/scheduler
# 指定端口
./bin/scheduler 9000
```

浏览器访问 `http://127.0.0.1:8765/`。首次启动若无历史数据会自动载入示例数据（2 个年级 × 3 个班、13 个科目）。

## 项目结构

```
scheduler/
├── scheduler.nimble            # 包配置
├── src/scheduler/
│   ├── domain.nim              # 领域模型 + 校验
│   ├── store.nim               # 内存状态 / 磁盘持久化 / 示例数据
│   ├── timetable.nim           # 排课算法
│   ├── configloader.nim        # JSON 配置加载（兼容保留）
│   ├── xlsxio.nim              # Excel 配置载入 + 排课结果导出
│   ├── httpapi.nim             # HTTP 服务与路由（staticRead 内嵌前端）
│   └── main.nim                # 入口 / 自动打开浏览器
├── config/                     # 配置文件（Excel 格式，优先加载）
│   ├── classes.xlsx            # 班级—课程—教师表
│   ├── rules.xlsx              # 排课规则
│   ├── classes.json            # 旧 JSON（回退，保留）
│   └── rules.json              # 旧 JSON（回退，保留）
└── www/index.html              # 前端单页应用
```

## 排课算法

`src/scheduler/timetable.nim` 中 `runSchedule`：

1. 校验数据合法性（班级总课时不超过可用时段等）
2. 随机贪心构造：班级按总课时降序，逐课时在可行时段中按评分择优安置
3. 最多 80 次重启，以 `完成节数 × 10000 + 软约束分` 排序取最优解
4. 软约束评分：主科上午加分、同日同科多节惩罚、跨天分散加分、主科避排下午末节

## HTTP API

| 方法 | 路径 | 说明 |
|------|------|------|
| GET  | `/` | 前端单页 |
| GET  | `/api/state` | 完整状态（学校数据 + 排课结果）|
| POST | `/api/save-school` | 保存学校数据（请求体为 School JSON）|
| POST | `/api/schedule` | 执行排课 |
| POST | `/api/swap` | 交换同班级两时段（校验教师冲突）|
| POST | `/api/set-cell` | 设置某单元格科目 |
| POST | `/api/persist` | 写入磁盘 |
| POST | `/api/load` | 从磁盘加载 |
| POST | `/api/sample` | 载入示例数据 |
| POST | `/api/config/load` | 从 `config/` 重新载入配置（优先 xlsx，缺则回退 JSON）|
| POST | `/api/export/xlsx` | 导出排课结果为 Excel（`概览` + 每个班级 + 每位教师，共 N sheet）|
| POST | `/api/clear` | 清空排课结果 |

## 数据存储

运行时数据保存于用户主目录：`~/.paimai/school.json`。

## 配置文件

项目 `config/` 下提供两份 Excel 配置（**优先加载**）；若不存在则回退到同名 JSON（保留作兼容）。启动时若没有历史磁盘数据则自动加载（也可调 `POST /api/config/load` 重新载入）。

### `config/classes.xlsx` — 班级—课程—教师表

- **第 1 行**：填写说明（保留，不被当作数据）
- **参数区（可选，A/B 两列键值）**：`daysPerWeek` / `periodsPerDay` / `morningCount` 三项，缺省时分别取 `5 / 8 / 4`
- **表头行**：前两列为 `年级 | 班级`，之后按 `科目 | 教师姓名 | 科目 | 教师姓名 ...` 交替成对出现；自动定位到含 `年级` / `班级` 的行为表头
- **数据行**：科目列填**周课时**（正整数或 `4+1` 表示 4 节单课 + 1 次连堂 = 6 课时，或 `美工+劳技` 表示单双周两科拼接）。课时为 0 或对应教师姓名列空白 → 该班不开此课。重名教师请在姓名后加数字标识

### `config/rules.xlsx` — 排课规则

表头：`科目 | 教师 | 星期 | 节次 | 规则 | 备注`（自动定位含 `科目` 的行）。每行一条规则，空白单元格取默认值：

- 教师列空 → 该科目全体教师
- 星期列空 → 全部星期；填写支持：`一` / `一二` / `一,二,三` / `1,2,3`
- 节次列空 → 全部节次；填写支持 `1,2,3` 或范围 `1-5`（1 基）
- 规则列（必填）：
  - `必排`：硬性占用并锁定该时段（全校科目不存在时自动补建，例如 `升旗` 会自动给每个班级生成占位任务并锁定）
  - `不排`：该科目/教师不得排入指定时段
  - `优先`：软偏好，落入指定时段加分

> 两份 JSON (`classes.json` / `rules.json`) 仍保留在 `config/` 作备用加载源。

## 排课结果导出 Excel

- HTTP: `POST /api/export/xlsx` → 返回 `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`，文件名 `timetable.xlsx`
- 也可在磁盘调用 `xlsxio.exportResultToXlsx(school, result, 路径)`
- 生成的 xlsx 包含：
  - `概览` sheet：排课成功状态、总分、消息、班/师/科/任务统计、未排上冲突清单
  - `班级-<班名>`：每个班级一张课表（行=节次，列=星期，单元格=科目\\n(教师)）
  - `教师-<姓名>`：每位教师一张课表（单元格=科目\\n班级）

## License

MIT
