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
# 构建
nim c -d:release -o:bin/scheduler src/scheduler/main.nim

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
│   ├── httpapi.nim             # HTTP 服务与路由（staticRead 内嵌前端）
│   └── main.nim                # 入口 / 自动打开浏览器
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
| POST | `/api/config/load` | 从 `config/` 重新载入配置 |
| POST | `/api/clear` | 清空排课结果 |

## 数据存储

运行时数据保存于用户主目录：`~/.paimai/school.json`。

## 配置文件

项目 `config/` 下提供两份人可读的 JSON 配置，启动时若没有历史磁盘数据则自动加载（也可调 `POST /api/config/load` 重新载入）：

- `config/classes.json`：班级—课程—教师表。每班列出开课科目、教师、周课时；`4+1` 表示 4 节单课 + 1 次连堂（共 6 课时）；课时为 0 或教师为空表示该班不开此课。
- `config/rules.json`：排课规则。每条含 `subject` / `teacher`（空=全体）/ `days`（空=所有天，如 `["一"]`）/ `periods`（1 基，空=全部节次）/ `kind`：
  - `必排`：硬性占用并锁定该时段（如升旗每周一第 2 节，全校锁定）
  - `不排`：该科目/教师不得排入指定时段
  - `优先`：软偏好，落入指定时段加分（择优时倾向）

配置文件用名称（非 id）书写，应用加载时自动映射为内部 id 并构建 `School`。

## License

MIT
