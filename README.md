# 规则进化像素世界 / Rule-Evolving Pixel World (LÖVE2D)

一个基于 **LÖVE (love2d)** 的小型“生命模拟器”：  
从随机粒子开始，通过规则碰撞生成资源与细胞，细胞再进化出捕食者，最终形成带有多阶段规则进化的生态系统，非常适合拿来做 7x24 小时直播背景。

A small **LÖVE (love2d)**-based “life simulator”:  
It starts from random particles, then collision rules generate resources and cells, cells evolve into predators, and the ecosystem goes through multiple evolutionary stages. It’s also suitable as a 24/7 livestream background.

---

## ✨ 特性简介 / Features

- **规则驱动的世界 / Rule-based world**
  - 10 种基础粒子 A–J，通过碰撞规则（规则池）演化出资源与细胞  
  - 规则会根据使用频率进行“进化”，形成高频规则集  
  - 规则池会周期性扩充与交叉变异

  - 10 basic particles A–J evolve into resources and cells via collision rules.  
  - Frequently used rules are favored and “evolve” over time.  
  - Rule pool periodically expands with crossover and mutation.

- **七个演化阶段 / Seven evolution stages**

  1. **阶段 1**：只有粒子与资源  
     Stage 1: Only particles and resources.

  2. **阶段 2**：粒子碰撞产生细胞  
     Stage 2: Particle collisions create cells.

  3. **阶段 3**：细胞参数（代谢、吸收、分裂阈值等）开始随机突变  
     Stage 3: Cell parameters (metabolism, absorb rate, divide threshold, etc.) start mutating.

  4. **阶段 4**：满足特定条件的细胞变异为捕食者，形成食物链  
     Stage 4: Cells that meet certain conditions mutate into predators, forming a food chain.

  5. **阶段 5**：细胞学会“躲避”捕食者，优先移动到周围无捕食者的安全格子  
     Stage 5: Cells learn to avoid predators and try to move to safe tiles.

  6. **阶段 6**：  
     - 捕食者解锁“加速”技能，每 tick 行动 2 步  
     - 同时，如果第六阶段已经解锁，**寿命超过某阈值的细胞也会获得加速**，但到达更高寿命后会因“衰老”失去加速  
       
     Stage 6:  
     - Predators unlock a speed-up ability (up to 2 moves per tick).  
     - Also, long-lived cells can gain speed temporarily, but lose it again when they become too old.

  7. **阶段 7**：细胞群体反击  
     - 在一定范围内细胞足够密集且附近捕食者较少时，会“联手”反杀一定数量的捕食者  
     Stage 7: Cell group counterattack  
     - When enough cells cluster within a certain radius and predators are few, cells can “counter-kill” nearby predators.

- **长寿与衰老机制 / Longevity & aging**
  - 细胞：寿命超过特定值后获得加速，超过更高阈值后失去加速  
  - 捕食者：年龄越大越接近最大寿命，达到寿命上限会死亡  

  Cells: gain speed when older than a threshold, lose it again when too old.  
  Predators: age and eventually die after surpassing a maximum age.

- **多轮自动模拟 / Multi-round auto simulation**
  - 默认每轮运行 30 分钟（可配置），结束后进入统计画面  
  - 统计包括：最大细胞数、最大捕食者数、首个捕食者出现时间、最长寿个体、被反击击杀的捕食者数量等  
  - 自动重置世界并进入下一轮，适合长期运行 / 直播  

  Each round runs for a configurable duration (default 30 minutes), then shows a stats screen and auto-resets for the next round. Perfect for long-running or streaming.

- **支持背景音乐与中文字体 / Optional music & Chinese font**
  - 如存在 `bgm.ogg` 会自动循环播放背景音乐  
  - 如存在 `MSYH.TTC`（微软雅黑）会优先使用中文字体显示 UI  

  If `bgm.ogg` exists, it will be looped as background music.  
  If `MSYH.TTC` (Microsoft YaHei) exists, the UI will use it for better CJK text rendering.

---

## 🧬 模拟规则概要 / Simulation Logic Overview

> 以下只是概要介绍，具体数值请看 `main.lua` 里的常量定义。

> This is only a summary. See constants in `main.lua` for exact values.

### 粒子 & 资源 / Particles & Resources

- 粒子随机生成与衰减（产生 & 消失）  
- 粒子之间碰撞时，根据规则池可能产生：  
  - 新粒子  
  - 资源  
  - 细胞  
  - 或“什么也不发生”  

Particles spawn and decay randomly. When two particles collide, the rule pool may cause:
- New particles  
- Resources  
- Cells  
- Or nothing  

资源会随时间增长、扩散，并在寿命结束后降解为粒子。  
Resources grow, diffuse, and eventually decay back into particles.

### 细胞 / Cells

- 从粒子碰撞产生，具有能量、年龄、基因参数等属性  
- 会消耗能量、吸收附近资源、达到阈值后分裂  
- 过度饥饿或能量耗尽会死亡  
- 某些细胞在满足：  
  - 累计吸收足够资源  
  - 接触过指定类型粒子  
  - 当前邻居有特定粒子  
  后，有概率变异为捕食者  

Cells are created from particle collisions. They:
- Consume energy over time  
- Absorb nearby resources  
- Divide when energy exceeds a threshold  
- Die when starved or out of energy  
- Under certain conditions, have a chance to mutate into predators.

### 捕食者 / Predators

- 只能由细胞变异产生  
- 只捕食细胞，不直接吃资源  
- 捕食成功会获得能量和击杀计数，能量足够 + 击杀数达到阈值时可以繁殖  
- 同样有饥饿与寿命机制，长时间未捕食会死亡  

Predators:
- Only come from mutated cells  
- Eat cells (not resources)  
- Gain energy and kill count when hunting  
- Reproduce when energy and kill count exceed thresholds  
- Can starve and die after too long without hunting.

### 高级机制 / Advanced Mechanics

- **细胞躲避捕食者（阶段 5）**：细胞移动时优先选择附近无捕食者的安全格子。  
- **捕食者加速（阶段 6）**：捕食者每 tick 可以移动两步。  
- **细胞长寿加速 / 衰老（阶段 6 之后生效）**：  
  - 细胞寿命超过某值后获取加速  
  - 寿命再次超过更高的阈值后失去加速  
- **细胞群体反击（阶段 7）**：  
  - 当一定范围内细胞数目 ≥ 阈值，且附近捕食者数量有限时，细胞可以联合“反杀”若干捕食者  
  - 反杀死亡的捕食者会被单独计数  

- Cell avoidance (Stage 5)  
- Predator speed-up (Stage 6)  
- Long-lived cell speed-up and aging (after Stage 6)  
- Group counterattack by cells (Stage 7), with dedicated stats for kill-by-counterattack.

---

## 🕹️ 操作 / Controls

本项目目前是“观赏型模拟”，无交互操作：  

This project is currently a non-interactive simulation:

- 启动后自动运行，按 LÖVE 默认行为可使用：  
  - `Esc`：退出程序（love2d 默认）  
- 其他行为通过修改 `main.lua` 内的常量实现，例如：  
  - 世界大小（`GRID_W`, `GRID_H`, `CELL_SIZE`）  
  - 时间步长（`STEP_TIME`）  
  - 各阶段的触发 Tick（`STAGE_2_TICK`, `STAGE_3_TICK`, …）  
  - 突变概率、寿命、饥饿阈值等  

The simulation runs automatically. For more control, edit constants in `main.lua`:
- World size, step time  
- Stage thresholds  
- Mutation rates, lifetimes, starvation ticks, etc.

---

## 🧰 环境需求 / Requirements

- [LÖVE (love2d)](https://love2d.org/) 版本 11.x（建议使用最新稳定版）  
- 支持的操作系统：Windows / macOS / Linux  

- LÖVE (love2d) 11.x (latest stable recommended)  
- Works on Windows / macOS / Linux.

---

## 🚀 运行方式 / Getting Started

### 1. 克隆仓库 / Clone the repo

```bash
git clone https://github.com/your-name/your-repo-name.git
cd your-repo-name

```
## 示例结构（实际以你的仓库为准）/Example structure (may vary slightly)：

.
├── main.lua        # 主逻辑 / Main simulation logic
├── LICENSE         # 开源协议（建议 MIT）
├── README.md       # 本文件 / This file
├── bgm.ogg         # （可选）背景音乐 / Optional background music
└── MSYH.TTC        # （可选）中文字体（微软雅黑）/ Optional CJK font


