---------------------------------------------------------
-- main.lua  (for LÖVE / love2d)
-- 规则驱动的像素世界：
-- 10 种粒子；细胞由粒子产生；
-- 捕食者只由细胞变异产生，并只捕食细胞；
-- 资源会老化并降解为基础粒子。
---------------------------------------------------------

---------------------- 基础参数 --------------------------
local GRID_W  = 80        -- 世界格子宽
local GRID_H  = 45        -- 世界格子高
local CELL_SIZE = 12      -- 每个格子的像素大小

local GRID_PIXEL_W = GRID_W * CELL_SIZE
local GRID_PIXEL_H = GRID_H * CELL_SIZE

local UI_WIDTH  = 360     -- 右侧信息区宽度

-- 额外增加窗口高度，用来显示说明文字（不增加格子数）
local EXTRA_WINDOW_HEIGHT = 355
local WINDOW_HEIGHT = GRID_PIXEL_H + EXTRA_WINDOW_HEIGHT

local STEP_TIME = 0.05    -- 世界每一步的时间（秒）

-- 阶段切换（逻辑用，显示阶段改为根据实际状态判断）
local STAGE_2_TICK = 200
local STAGE_3_TICK = 800
local STAGE_4_TICK = 1000

-- 粒子：10 种
local PARTICLE_TYPES = { "A","B","C","D","E","F","G","H","I","J" }
local BASE_PARTICLE_SPAWN_PROB = 0.003
local BASE_PARTICLE_DECAY_PROB = 0.001

-- 资源
local RESOURCE_MAX_ENERGY      = 20
local RESOURCE_GROW_PROB       = 0.10
local RESOURCE_DIFFUSE_PROB    = 0.02
local RESOURCE_ENERGY_PER_GROW = 1
local RESOURCE_MAX_AGE_TICKS   = 700   -- 资源寿命，超时降解为粒子

-- 细胞
local CELL_BASE_METABOLISM       = 0.2
local CELL_BASE_ABSORB           = 3
local CELL_BASE_DIVIDE_THRESHOLD = 30
local CELL_BASE_LEAK             = 0.05
local CELL_MAX_AGE               = 1000   -- 允许活到 1000，800 以后视为“衰老期”
-- 细胞饥饿上限：连续多少 tick 没有吸收资源会死亡
local CELL_STARVE_TICKS          = 160
-- 细胞加速 / 失速年龄阈值（仅在第 6 阶段解锁后生效）
local CELL_SPEEDUP_AGE           = 150
local CELL_SPEED_LOSS_AGE        = 800

-- 捕食者
local PREDATOR_BASE_METABOLISM   = 0.4
local PREDATOR_BASE_ATTACK_GAIN  = 10
local PREDATOR_DIVIDE_THRESHOLD  = 50
local PREDATOR_MAX_AGE           = 1200
local PREDATOR_SPEED_LOSS_AGE    = 1000   -- 超过这个年龄后失去加速技能
-- 捕食者饥饿上限：连续多少 tick 没有吃到细胞会死亡
local PREDATOR_STARVE_TICKS      = 100

-- 阶段 5 / 6 / 7 解锁条件
local STAGE5_KILL_THRESHOLD  = 200  -- 捕食者累计击杀细胞数达到这个值 → 解锁阶段5
local STAGE6_DEATH_THRESHOLD = 80   -- 阶段5后，捕食者累计死亡数达到这个值 → 解锁阶段6
local CELL_COUNTERATTACK_DEATH_THRESHOLD = 400 -- 阶段6后，细胞死亡数达到这个值 → 解锁阶段7

-- 基因突变（细胞和捕食者的参数微调）
local MUTATION_RATE_STAGE3       = 0.15
local MUTATION_RATE_STAGE4       = 0.25
local MUTATION_MAGNITUDE         = 0.2

-- 细胞 → 捕食者 的变异条件
-- 需要累积吸收足够多的资源，并接触到指定粒子类型中的若干种
local PREDATOR_REQUIRED_RESOURCE  = 100      -- 资源阈值
local PREDATOR_REQUIRED_PARTICLES = {"A","B","F","J"} -- 在这几种中至少接触到 2 种
local PREDATOR_MUTATION_PROB      = 0.05        -- 满足条件时的一次性变异概率（调试时为 100%）

-- 捕食者繁殖条件：必须捕食足够数量的细胞
local PREDATOR_REQUIRED_KILLS     = 5       -- 捕食多少个细胞后才允许分裂

-- 规则进化（规则池扩容）
local RULE_EVOLVE_INTERVAL = 500
local MAX_RULES            = 120   -- 最大规则数
local INIT_RULE_COUNT      = 30    -- 初始规则数

-- 字体
local font_small, font_big, font_rules

-- 背景音乐
local bgm

---------------------- 工具函数 --------------------------
local function rand_int(a, b) return love.math.random(a, b) end
local function rand_choice(list) return list[rand_int(1, #list)] end
local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

-- 把秒数格式化成 “X分YY秒”
local function format_sim_time(seconds)
    if not seconds then return "-" end
    local total = math.floor(seconds + 0.5)
    local mins  = math.floor(total / 60)
    local secs  = total % 60
    return string.format("%d分%02d秒", mins, secs)
end

---------------------- 世界状态 --------------------------
local world = {}
local tick_count = 0
local step_accum = 0

-- 统计数据（当前这一轮模拟内）
local max_cell_count        = 0
local max_predator_count    = 0
local first_predator_tick   = nil
local first_predator_time   = nil   -- 用“秒数”记录出现用时
local max_cell_age_seen     = 0
local max_predator_age_seen = 0

-- 阶段5/6/7统计
local total_predator_kills               = 0   -- 所有捕食者总共杀了多少细胞
local total_predator_deaths_after_avoid  = 0   -- 细胞学会躲避之后，捕食者死了多少
local cell_avoidance_unlocked            = false  -- 阶段5：细胞学会躲避
local predator_speedup_unlocked          = false  -- 阶段6：捕食者加速
local cell_deaths_after_speedup          = 0      -- 阶段6后累计细胞死亡
local cell_counterattack_unlocked        = false  -- 阶段7：细胞反击解锁
local predator_deaths_by_cell_counter    = 0      -- 本轮被细胞反击杀死的捕食者

-- ==== 上一轮统计变量 =================================
local last_round_exists           = false
local last_round_index            = 0
local last_total_ticks            = 0
local last_max_cell_count         = 0
local last_max_predator_count     = 0
local last_first_predator_tick    = nil
local last_first_predator_time    = nil   -- 也是“秒数”
local last_max_cell_age_seen      = 0
local last_max_predator_age_seen  = 0
local last_predator_deaths_by_cell_counter = 0
-- =====================================================

-- 多轮模拟控制
local SIM_RUN_DURATION   = 1800  -- 每轮运行 1800 秒（半小时）
local SIM_STATS_DURATION = 30    -- 统计画面 30 秒
local sim_mode           = "run" -- "run" 或 "stats"
local sim_run_time       = 0     -- 当前轮已经运行的时间（秒）
local sim_stats_time_left = 0    -- 统计画面剩余秒数
local sim_round_index    = 1     -- 当前为第几轮模拟

---------------------- 邻居 ------------------------------
local function in_bounds(x, y)
    return x >= 1 and x <= GRID_W and y >= 1 and y <= GRID_H
end

local neighbor_dirs8 = {
    {dx=-1,dy=-1},{dx=0,dy=-1},{dx=1,dy=-1},
    {dx=-1,dy= 0},            {dx=1,dy= 0},
    {dx=-1,dy= 1},{dx=0,dy= 1},{dx=1,dy= 1},
}

local neighbor_dirs4 = {
    {dx=1,dy=0},{dx=0,dy=1},{dx=1,dy=1},{dx=-1,dy=1},
}

local function random_neighbor(x, y)
    local d = neighbor_dirs8[rand_int(1, #neighbor_dirs8)]
    local nx, ny = x + d.dx, y + d.dy
    if in_bounds(nx, ny) then return nx, ny else return x, y end
end

local function for_each_cell(func)
    for y = 1, GRID_H do
        for x = 1, GRID_W do
            func(x, y, world[y][x])
        end
    end
end

---------------------- 阶段判定 --------------------------
-- 内部逻辑用（根据 tick 数）—— 给变异/突变用
local function get_stage_logic()
    if tick_count < STAGE_2_TICK then
        return 1
    elseif tick_count < STAGE_3_TICK then
        return 2
    elseif tick_count < STAGE_4_TICK then
        return 3
    else
        return 4
    end
end

-- 判断一个细胞是否已经发生过基因突变（和默认参数不一样）
local function is_cell_mutated(cell)
    local g = cell.genome or {}
    local eps = 1e-3
    if math.abs((g.absorb_rate or 1.0) - 1.0) > eps then return true end
    if math.abs((g.metabolism or CELL_BASE_METABOLISM) - CELL_BASE_METABOLISM) > eps then return true end
    if math.abs((g.divide_threshold or CELL_BASE_DIVIDE_THRESHOLD) - CELL_BASE_DIVIDE_THRESHOLD) > eps then return true end
    if math.abs((g.leak_rate or CELL_BASE_LEAK) - CELL_BASE_LEAK) > eps then return true end
    return false
end

-- 显示用阶段：根据当前世界实际状态 + 阶段5/6/7解锁情况判断
local function get_stage_display()
    local has_cells          = false
    local has_mutated_cells  = false
    local has_predators      = false

    for_each_cell(function(x,y,e)
        if e then
            if e.kind == "cell" then
                has_cells = true
                if (not has_mutated_cells) and is_cell_mutated(e) then
                    has_mutated_cells = true
                end
            elseif e.kind == "predator" then
                has_predators = true
            end
        end
    end)

    -- 基础阶段 1~4，按世界实际状态判断
    local base_stage
    if (not has_cells) and (not has_predators) then
        base_stage = 1
    elseif has_cells and (not has_mutated_cells) and (not has_predators) then
        base_stage = 2
    elseif has_cells and has_mutated_cells and (not has_predators) then
        base_stage = 3
    else
        base_stage = 4
    end

    -- 如果解锁了更高阶段，用 5 / 6 / 7 覆盖显示
    if cell_counterattack_unlocked then
        return 7
    elseif predator_speedup_unlocked then
        return 6
    elseif cell_avoidance_unlocked then
        return 5
    else
        return base_stage
    end
end

---------------------- 实体构造 --------------------------
local function make_particle(ptype)
    return { kind = "particle", ptype = ptype }
end

local function make_resource(energy)
    return { kind = "resource", energy = energy or 1, age = 0 }
end

local function make_cell(genome, energy)
    return {
        kind   = "cell",
        energy = energy or 5,
        age    = 0,
        resource_eaten       = 0,          -- 累计吸收的资源量
        seen_particles       = {},         -- 历史上接触过的粒子类型
        predator_checked     = false,      -- 是否已经尝试过变异
        time_since_last_food = 0,          -- 距离上次吸收资源的 tick 数
        genome = {
            absorb_rate      = genome.absorb_rate      or 1.0,
            metabolism       = genome.metabolism       or CELL_BASE_METABOLISM,
            divide_threshold = genome.divide_threshold or CELL_BASE_DIVIDE_THRESHOLD,
            leak_rate        = genome.leak_rate        or CELL_BASE_LEAK,
        }
    }
end

local function make_predator(genome, energy)
    return {
        kind   = "predator",
        energy = energy or 10,
        age    = 0,
        kills  = 0,               -- 捕食到的细胞数
        time_since_last_kill = 0, -- 距离上次捕食过去了多少 tick
        genome = {
            metabolism       = genome.metabolism       or PREDATOR_BASE_METABOLISM,
            attack_gain      = genome.attack_gain      or PREDATOR_BASE_ATTACK_GAIN,
            divide_threshold = genome.divide_threshold or PREDATOR_DIVIDE_THRESHOLD,
        }
    }
end

---------------------- 规则池 ---------------------------
local RULE_POOL = {}
local NEXT_RULE_ID = 1
local POSSIBLE_OUTCOMES = { "resource", "particle", "nothing", "cell" }

local function random_collision_rule()
    local a_type = rand_choice(PARTICLE_TYPES)
    local b_type = rand_choice(PARTICLE_TYPES)
    local outcome = rand_choice(POSSIBLE_OUTCOMES)
    local prob = love.math.random()

    local rule = {
        id      = NEXT_RULE_ID,
        kind    = "collision",
        a_type  = a_type,
        b_type  = b_type,
        outcome = outcome,
        prob    = prob,
        params  = {},
        usage   = 0,
    }
    NEXT_RULE_ID = NEXT_RULE_ID + 1

    if outcome == "resource" then
        rule.params.energy = rand_int(1, 12)
    elseif outcome == "particle" then
        rule.params.new_type = rand_choice(PARTICLE_TYPES)
    elseif outcome == "cell" then
        rule.params.energy = rand_int(6, 18)
    end
    return rule
end

local function init_rules()
    RULE_POOL = {}
    NEXT_RULE_ID = 1
    for i = 1, INIT_RULE_COUNT do
        table.insert(RULE_POOL, random_collision_rule())
    end
end

local function crossover_rules(p1, p2)
    local child = {
        id      = NEXT_RULE_ID,
        kind    = "collision",
        a_type  = (love.math.random() < 0.5) and p1.a_type or p2.a_type,
        b_type  = (love.math.random() < 0.5) and p1.b_type or p2.b_type,
        outcome = (love.math.random() < 0.5) and p1.outcome or p2.outcome,
        prob    = (p1.prob + p2.prob) / 2,
        params  = {},
        usage   = 0,
    }
    NEXT_RULE_ID = NEXT_RULE_ID + 1

    if child.outcome == "resource" then
        local e1 = p1.params.energy or 5
        local e2 = p2.params.energy or 5
        child.params.energy = math.max(1, math.floor((e1 + e2)/2))
    elseif child.outcome == "particle" then
        child.params.new_type =
            (love.math.random() < 0.5) and (p1.params.new_type or rand_choice(PARTICLE_TYPES))
                                     or (p2.params.new_type or rand_choice(PARTICLE_TYPES))
    elseif child.outcome == "cell" then
        local e1 = p1.params.energy or 10
        local e2 = p2.params.energy or 10
        child.params.energy = math.max(3, math.floor((e1 + e2)/2))
    end

    if love.math.random() < 0.2 then
        child.prob = clamp(child.prob + (love.math.random()*2-1)*0.3, 0, 1)
    end
    if love.math.random() < 0.1 then
        child.outcome = rand_choice(POSSIBLE_OUTCOMES)
    end

    return child
end

local function evolve_rules()
    if #RULE_POOL == 0 then return end

    table.sort(RULE_POOL, function(a,b)
        return (a.usage or 0) > (b.usage or 0)
    end)

    local parents = {}
    local max_parents = math.min(20, #RULE_POOL)
    for i=1,max_parents do
        if (RULE_POOL[i].usage or 0) > 0 then
            table.insert(parents, RULE_POOL[i])
        end
    end

    local children = {}
    if #parents >= 2 then
        for i=1,8 do
            local p1 = parents[rand_int(1,#parents)]
            local p2 = parents[rand_int(1,#parents)]
            if p1 ~= p2 then
                table.insert(children, crossover_rules(p1,p2))
            end
        end
    end

    if love.math.random() < 0.5 then
        table.insert(children, random_collision_rule())
        table.insert(children, random_collision_rule())
    end

    for _,c in ipairs(children) do
        table.insert(RULE_POOL, c)
    end

    if #RULE_POOL > MAX_RULES then
        while #RULE_POOL > MAX_RULES do
            table.remove(RULE_POOL)
        end
    end

    for _,r in ipairs(RULE_POOL) do
        r.usage = math.floor((r.usage or 0)*0.5)
    end
end

local function apply_collision_rules(p1, p2)
    local t1, t2 = p1.ptype, p2.ptype
    for _,rule in ipairs(RULE_POOL) do
        if rule.kind == "collision" then
            if (rule.a_type==t1 and rule.b_type==t2) or
               (rule.a_type==t2 and rule.b_type==t1) then
                if love.math.random() < rule.prob then
                    rule.usage = (rule.usage or 0) + 1
                    return rule
                end
            end
        end
    end
    return nil
end

---------------------- 阶段1：粒子+资源 ------------------
local function spawn_particles()
    for y=1,GRID_H do
        for x=1,GRID_W do
            if not world[y][x] then
                if love.math.random() < BASE_PARTICLE_SPAWN_PROB then
                    world[y][x] = make_particle(rand_choice(PARTICLE_TYPES))
                end
            end
        end
    end
end

local function decay_particles()
    for_each_cell(function(x,y,e)
        if e and e.kind=="particle" and love.math.random() < BASE_PARTICLE_DECAY_PROB then
            world[y][x] = nil
        end
    end)
end

local function handle_collisions()
    local processed = {}
    for y=1,GRID_H do
        processed[y]={}
        for x=1,GRID_W do processed[y][x]=false end
    end
    local updates = {}

    for y=1,GRID_H do
        for x=1,GRID_W do
            local e = world[y][x]
            if e and e.kind=="particle" and not processed[y][x] then
                for _,d in ipairs(neighbor_dirs4) do
                    local nx,ny = x+d.dx, y+d.dy
                    if in_bounds(nx,ny) and not processed[ny][nx] then
                        local n = world[ny][nx]
                        if n and n.kind=="particle" then
                            local rule = apply_collision_rules(e,n)
                            if rule then
                                processed[y][x], processed[ny][nx] = true,true
                                if rule.outcome=="resource" then
                                    local en = rule.params.energy or 5
                                    table.insert(updates,{x=x,y=y,type="resource",energy=en})
                                    table.insert(updates,{x=nx,y=ny,type="resource",energy=en})
                                elseif rule.outcome=="particle" then
                                    local nt = rule.params.new_type or rand_choice(PARTICLE_TYPES)
                                    table.insert(updates,{x=x,y=y,type="particle",ptype=nt})
                                    table.insert(updates,{x=nx,y=ny,type="particle",ptype=nt})
                                elseif rule.outcome=="nothing" then
                                    table.insert(updates,{x=x,y=y,type="empty"})
                                    table.insert(updates,{x=nx,y=ny,type="empty"})
                                elseif rule.outcome=="cell" then
                                    local en = rule.params.energy or 10
                                    table.insert(updates,{x=x,y=y,type="cell",energy=en})
                                    table.insert(updates,{x=nx,y=ny,type="cell",energy=en})
                                end
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    for _,u in ipairs(updates) do
        if in_bounds(u.x,u.y) then
            if u.type=="resource" then
                world[u.y][u.x] = make_resource(u.energy)
            elseif u.type=="particle" then
                world[u.y][u.x] = make_particle(u.ptype)
            elseif u.type=="cell" then
                local genome = {
                    absorb_rate = 1.0,
                    metabolism  = CELL_BASE_METABOLISM,
                    divide_threshold = CELL_BASE_DIVIDE_THRESHOLD,
                    leak_rate   = CELL_BASE_LEAK,
                }
                world[u.y][u.x] = make_cell(genome, u.energy)
            elseif u.type=="empty" then
                world[u.y][u.x] = nil
            end
        end
    end
end

local function update_resources()
    local new_res = {}
    for y=1,GRID_H do
        for x=1,GRID_W do
            local e = world[y][x]
            if e and e.kind=="resource" then
                e.age = (e.age or 0) + 1

                -- 寿命结束：降解成基础粒子
                if e.age > RESOURCE_MAX_AGE_TICKS then
                    world[y][x] = make_particle(rand_choice(PARTICLE_TYPES))
                else
                    -- 正常生长 & 扩散
                    if love.math.random() < RESOURCE_GROW_PROB then
                        e.energy = math.min(RESOURCE_MAX_ENERGY, e.energy + RESOURCE_ENERGY_PER_GROW)
                    end
                    if love.math.random() < RESOURCE_DIFFUSE_PROB and e.energy>2 then
                        local nx,ny = random_neighbor(x,y)
                        if in_bounds(nx,ny) and not world[ny][nx] then
                            local split = math.floor(e.energy/2)
                            e.energy = e.energy - split
                            table.insert(new_res,{x=nx,y=ny,energy=split})
                        end
                    end
                end
            end
        end
    end
    for _,r in ipairs(new_res) do
        if in_bounds(r.x,r.y) and not world[r.y][r.x] then
            world[r.y][r.x] = make_resource(r.energy)
        end
    end
end

---------------------- 细胞基因突变 & 阶段计数 ----------------------
local function mutate_genome(genome, stage)
    local rate = 0
    if stage>=4 then rate=MUTATION_RATE_STAGE4
    elseif stage>=3 then rate=MUTATION_RATE_STAGE3
    else return genome end

    local mag = MUTATION_MAGNITUDE
    local function maybe(v)
        if love.math.random() < rate then
            local factor = 1 + (love.math.random()*2-1)*mag
            return math.max(0.01, v*factor)
        else return v end
    end

    return {
        absorb_rate      = maybe(genome.absorb_rate),
        metabolism       = maybe(genome.metabolism),
        divide_threshold = maybe(genome.divide_threshold),
        leak_rate        = maybe(genome.leak_rate),
    }
end

-- 记录一次捕食者成功捕食
local function register_predator_kill()
    total_predator_kills = total_predator_kills + 1
    if (not cell_avoidance_unlocked) and total_predator_kills >= STAGE5_KILL_THRESHOLD then
        cell_avoidance_unlocked = true
    end
end

-- 记录一次捕食者死亡（阶段5解锁以后才计入，用来解锁阶段6）
local function register_predator_death()
    if cell_avoidance_unlocked and (not predator_speedup_unlocked) then
        total_predator_deaths_after_avoid = total_predator_deaths_after_avoid + 1
        if total_predator_deaths_after_avoid >= STAGE6_DEATH_THRESHOLD then
            predator_speedup_unlocked = true
        end
    end
end

-- 记录细胞死亡（阶段6 解锁后才用来解锁阶段7）
local function register_cell_death()
    if predator_speedup_unlocked and (not cell_counterattack_unlocked) then
        cell_deaths_after_speedup = cell_deaths_after_speedup + 1
        if cell_deaths_after_speedup >= CELL_COUNTERATTACK_DEATH_THRESHOLD then
            cell_counterattack_unlocked = true
        end
    end
end

-- 记录被细胞反击杀死的捕食者
local function register_predator_death_by_counter()
    predator_deaths_by_cell_counter = predator_deaths_by_cell_counter + 1
end

-- 在 REQUIRED_PARTICLES 中，至少接触到两种即可
local function has_seen_required_particles(cell)
    if not cell.seen_particles then return false end
    local count = 0
    for _,ptype in ipairs(PREDATOR_REQUIRED_PARTICLES) do
        if cell.seen_particles[ptype] then
            count = count + 1
        end
    end
    return count >= 2
end

---------------------- 生命行为 ---------------------------
local function find_empty_neighbor(x,y)
    for i=1,#neighbor_dirs8 do
        local d = neighbor_dirs8[rand_int(1,#neighbor_dirs8)]
        local nx,ny = x+d.dx, y+d.dy
        if in_bounds(nx,ny) and not world[ny][nx] then
            return nx,ny
        end
    end
    return nil,nil
end

-- 第六阶段后，长寿细胞的加速 / 衰老规则：
-- 1）predator_speedup_unlocked == true（已经解锁第六阶段）
-- 2）细胞 age > CELL_SPEEDUP_AGE 且 age ≤ CELL_SPEED_LOSS_AGE 时，本 tick 移动 2 步
-- 3）age > CELL_SPEED_LOSS_AGE 或未解锁第六阶段：仍然只移动 1 步
local function get_cell_move_steps(cell)
    if predator_speedup_unlocked
       and cell.age > CELL_SPEEDUP_AGE
       and cell.age <= CELL_SPEED_LOSS_AGE then
        return 2
    else
        return 1
    end
end

local function step_cell(x,y,cell,stage)
    if cell.energy<=0 then
        register_cell_death()
        world[y][x]=nil
        return
    end
    cell.age = cell.age + 1
    if cell.age > CELL_MAX_AGE then
        register_cell_death()
        world[y][x] = make_resource(math.floor(cell.energy))
        return
    end
    -- 更新最长寿细胞记录
    if cell.age > max_cell_age_seen then
        max_cell_age_seen = cell.age
    end

    -- 饥饿计数：每一步都增加
    cell.time_since_last_food = (cell.time_since_last_food or 0) + 1

    -- 记录邻近粒子（用于变异条件）
    local near_required_particle = false
    for _,d in ipairs(neighbor_dirs8) do
        local nx,ny = x+d.dx, y+d.dy
        if in_bounds(nx,ny) then
            local n = world[ny][nx]
            if n and n.kind=="particle" then
                cell.seen_particles = cell.seen_particles or {}
                cell.seen_particles[n.ptype] = true
                for _,ptype in ipairs(PREDATOR_REQUIRED_PARTICLES) do
                    if n.ptype == ptype then
                        near_required_particle = true
                        break
                    end
                end
            end
        end
    end

    -- 阶段 4 才允许细胞变异为捕食者，每个细胞只尝试一次
    if stage == 4
       and not cell.predator_checked
       and near_required_particle
       and has_seen_required_particles(cell)
       and (cell.resource_eaten or 0) >= PREDATOR_REQUIRED_RESOURCE then

        cell.predator_checked = true   -- 只尝试一次
        if love.math.random() < PREDATOR_MUTATION_PROB then
            local pg = {
                metabolism       = cell.genome.metabolism * 1.5,
                attack_gain      = PREDATOR_BASE_ATTACK_GAIN + 5,
                divide_threshold = PREDATOR_DIVIDE_THRESHOLD,
            }
            world[y][x] = make_predator(pg, cell.energy)
            return
        end
    end

    -- 代谢
    cell.energy = cell.energy - cell.genome.metabolism
    cell.energy = cell.energy - cell.genome.leak_rate * cell.energy
    if cell.energy<=0 then
        register_cell_death()
        world[y][x]=nil
        return
    end

    -- 吃资源
    local ate=false
    for _,d in ipairs(neighbor_dirs8) do
        local nx,ny = x+d.dx, y+d.dy
        if in_bounds(nx,ny) then
            local n = world[ny][nx]
            if n and n.kind=="resource" then
                local absorb = CELL_BASE_ABSORB * cell.genome.absorb_rate
                local taken = math.min(absorb, n.energy)
                cell.energy = cell.energy + taken
                n.energy = n.energy - taken
                cell.resource_eaten = (cell.resource_eaten or 0) + taken
                cell.time_since_last_food = 0    -- 刚吃到资源，清零饥饿计数
                if n.energy<=0 then world[ny][nx]=nil end
                ate=true; break
            end
        end
    end

    -- 没吃到资源 → 移动（可能多步）
    if not ate then
        local moves = get_cell_move_steps(cell)

        for step = 1, moves do
            -- 如果在前一次移动中，这个格子已经不再是同一个 cell（被吃掉 / 覆盖），就停下
            if world[y][x] ~= cell then
                break
            end

            if cell_avoidance_unlocked then
                -- 尝试找一个“附近没有捕食者”的安全格子
                local safe_positions = {}

                for _,d in ipairs(neighbor_dirs8) do
                    local nx,ny = x + d.dx, y + d.dy
                    if in_bounds(nx,ny) and not world[ny][nx] then
                        local danger = false
                        -- 看看这个新位置周围 8 邻居里有没有捕食者
                        for _,d2 in ipairs(neighbor_dirs8) do
                            local ex,ey = nx + d2.dx, ny + d2.dy
                            if in_bounds(ex,ey) then
                                local ne = world[ey][ex]
                                if ne and ne.kind == "predator" then
                                    danger = true
                                    break
                                end
                            end
                        end
                        if not danger then
                            table.insert(safe_positions, {nx, ny})
                        end
                    end
                end

                if #safe_positions > 0 then
                    local choice = safe_positions[rand_int(1, #safe_positions)]
                    local nx,ny = choice[1], choice[2]
                    world[ny][nx] = cell
                    world[y][x]  = nil
                    x,y = nx,ny
                else
                    -- 实在找不到“完全安全”的，就退回原始随机游走
                    local nx,ny = random_neighbor(x,y)
                    if in_bounds(nx,ny) and not world[ny][nx] then
                        world[ny][nx] = cell
                        world[y][x]  = nil
                        x,y = nx,ny
                    end
                end
            else
                -- 未解锁阶段5：正常随机游走
                local nx,ny = random_neighbor(x,y)
                if in_bounds(nx,ny) and not world[ny][nx] then
                    world[ny][nx] = cell
                    world[y][x]  = nil
                    x,y = nx,ny
                end
            end
        end
    end

    -- 阶段7：细胞反击逻辑（2 格范围内统计）
    if cell_counterattack_unlocked then
        local cell_count = 0
        local predators = {}

        for dy = -2, 2 do
            for dx = -2, 2 do
                local nx, ny = x + dx, y + dy
                if in_bounds(nx, ny) then
                    local n = world[ny][nx]
                    if n then
                        if n.kind == "cell" then
                            cell_count = cell_count + 1
                        elseif n.kind == "predator" then
                            table.insert(predators, {nx, ny})
                        end
                    end
                end
            end
        end

        -- 至少 4 个细胞，且捕食者数量为 1 时，可以联手反杀（最多杀 1 个）
        if cell_count >= 4 and #predators > 0 and #predators < 2 then
            local kills = math.min(1, #predators)
            for i = 1, kills do
                local px, py = predators[i][1], predators[i][2]
                local p = world[py][px]
                if p and p.kind == "predator" then
                    register_predator_death()
                    register_predator_death_by_counter()
                    world[py][px] = nil
                end
            end
        end
    end

    -- 饥饿死亡：长时间没吃到资源则死亡
    if (cell.time_since_last_food or 0) >= CELL_STARVE_TICKS then
        register_cell_death()
        world[y][x] = nil
        return
    end

    -- 分裂
    if cell.energy >= cell.genome.divide_threshold then
        local cx,cy = find_empty_neighbor(x,y)
        if cx and cy then
            local child_energy = cell.energy * 0.5
            cell.energy = cell.energy * 0.5
            local new_genome = mutate_genome(cell.genome,stage)
            world[cy][cx] = make_cell(new_genome, child_energy)
        end
    end
end

local function step_predator(x,y,pred,stage)
    -- 先检查能量/年龄
    if pred.energy <= 0 then
        register_predator_death()
        world[y][x] = nil
        return
    end

    pred.age = pred.age + 1
    if pred.age > PREDATOR_MAX_AGE then
        register_predator_death()
        world[y][x] = make_resource(math.floor(pred.energy / 2))
        return
    end

    -- 更新最长寿捕食者记录
    if pred.age > max_predator_age_seen then
        max_predator_age_seen = pred.age
    end

    -- 每一步都增加“距离上次捕食的 tick 数”
    pred.time_since_last_kill = (pred.time_since_last_kill or 0) + 1

    -- 代谢消耗
    pred.energy = pred.energy - pred.genome.metabolism
    if pred.energy <= 0 then
        register_predator_death()
        world[y][x] = nil
        return
    end

    -- 根据是否解锁阶段6 + 是否已经衰老，决定本 tick 行动次数
    local is_old = pred.age > PREDATOR_SPEED_LOSS_AGE
    local moves = (predator_speedup_unlocked and (not is_old)) and 2 or 1

    for step = 1, moves do
        -- 防御：如果这个捕食者在前一次循环里已经被移除，就直接结束
        if not world[y][x] or world[y][x] ~= pred then
            return
        end

        -- 只吃细胞
        local hunted=false
        for _,d in ipairs(neighbor_dirs8) do
            local nx,ny = x+d.dx, y+d.dy
            if in_bounds(nx,ny) then
                local n = world[ny][nx]
                if n and n.kind=="cell" then
                    pred.energy = pred.energy + pred.genome.attack_gain + n.energy
                    pred.kills  = (pred.kills or 0) + 1
                    pred.time_since_last_kill = 0         -- 刚吃到细胞，清零饥饿计时

                    register_predator_kill()              -- 记录一次成功捕食
                    register_cell_death()                 -- 细胞死亡

                    world[ny][nx] = pred
                    world[y][x] = nil
                    x,y = nx,ny
                    hunted=true; break
                end
            end
        end

        if not hunted then
            local nx,ny = random_neighbor(x,y)
            if in_bounds(nx,ny) and not world[ny][nx] then
                world[ny][nx]=pred
                world[y][x]=nil
                x,y = nx,ny
            end
        end
    end

    -- 饿死判定：如果太久没吃到细胞，直接死亡
    if (pred.time_since_last_kill or 0) >= PREDATOR_STARVE_TICKS then
        register_predator_death()
        world[y][x] = nil
        return
    end

    -- 捕食者繁殖：需要能量 + 捕食次数达到阈值
    if pred.energy >= pred.genome.divide_threshold
       and (pred.kills or 0) >= PREDATOR_REQUIRED_KILLS then

        local cx,cy = find_empty_neighbor(x,y)
        if cx and cy then
            local child_energy = pred.energy * 0.5
            pred.energy = pred.energy * 0.5
            pred.kills  = 0   -- 分裂后重新累计

            local g = pred.genome
            local child_genome = {
                metabolism       = g.metabolism,
                attack_gain      = g.attack_gain,
                divide_threshold = g.divide_threshold,
            }
            local rate = (stage>=4) and MUTATION_RATE_STAGE4 or MUTATION_RATE_STAGE3
            if love.math.random() < rate then
                local mag = MUTATION_MAGNITUDE
                local function mut(v)
                    local factor = 1+(love.math.random()*2-1)*mag
                    return math.max(0.01, v*factor)
                end
                child_genome.metabolism       = mut(child_genome.metabolism)
                child_genome.attack_gain      = mut(child_genome.attack_gain)
                child_genome.divide_threshold = mut(child_genome.divide_threshold)
            end
            local child = make_predator(child_genome, child_energy)
            world[cy][cx] = child
        end
    end
end

local function update_life()
    local stage = get_stage_logic()   -- 内部逻辑仍按时间阶段（参数突变用）
    local positions = {}
    for y=1,GRID_H do
        for x=1,GRID_W do
            local e = world[y][x]
            if e and (e.kind=="cell" or e.kind=="predator") then
                table.insert(positions,{x=x,y=y})
            end
        end
    end
    for i=#positions,2,-1 do
        local j = rand_int(1,i)
        positions[i],positions[j] = positions[j],positions[i]
    end
    for _,pos in ipairs(positions) do
        local x,y = pos.x,pos.y
        local e = world[y][x]
        if e then
            if e.kind=="cell" then
                step_cell(x,y,e,stage)
            elseif e.kind=="predator" then
                step_predator(x,y,e,stage)
            end
        end
    end
end

---------------------- 世界一步 --------------------------
local function step_world()
    tick_count = tick_count + 1

    spawn_particles()
    decay_particles()
    handle_collisions()
    update_resources()
    update_life()

    -- 每一步更新数量统计 & 最大值
    local count_particles, count_resources = 0,0
    local count_cells, count_predators = 0,0
    for_each_cell(function(x,y,e)
        if e then
            if e.kind=="particle" then count_particles=count_particles+1
            elseif e.kind=="resource" then count_resources=count_resources+1
            elseif e.kind=="cell" then count_cells=count_cells+1
            elseif e.kind=="predator" then count_predators=count_predators+1
            end
        end
    end)

    if count_cells > max_cell_count then
        max_cell_count = count_cells
    end
    if count_predators > max_predator_count then
        max_predator_count = count_predators
    end

    -- 记录第一个捕食者出现的 tick 和用时（秒）
    if count_predators > 0 and not first_predator_tick then
        first_predator_tick = tick_count
        first_predator_time = tick_count * STEP_TIME
    end

    if tick_count % RULE_EVOLVE_INTERVAL == 0 then
        evolve_rules()
    end
end

---------------------- 渲染：世界 ------------------------
local function draw_world()
    for y=1,GRID_H do
        for x=1,GRID_W do
            local e = world[y][x]
            if e then
                if e.kind=="particle" then
                    local idx = 1
                    for i,t in ipairs(PARTICLE_TYPES) do
                        if t == e.ptype then idx=i break end
                    end
                    local v = 0.25 + 0.05*idx
                    love.graphics.setColor(v,v,v)
                elseif e.kind=="resource" then
                    local t = e.energy/RESOURCE_MAX_ENERGY
                    love.graphics.setColor(0,0.45+0.55*t,0)
                elseif e.kind=="cell" then
                    love.graphics.setColor(0.2,0.6,1.0)
                elseif e.kind=="predator" then
                    love.graphics.setColor(1.0,0.2,0.2)
                end
                love.graphics.rectangle("fill",
                    (x-1)*CELL_SIZE, (y-1)*CELL_SIZE,
                    CELL_SIZE, CELL_SIZE)
            end
        end
    end

    love.graphics.setColor(0.6,0.6,0.6,0.8)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", 0, 0, GRID_PIXEL_W, GRID_PIXEL_H)
end

---------------------- 渲染：右侧 UI ---------------------
local function draw_ui()
    -- 顶部状态栏
    love.graphics.setFont(font_small)
    love.graphics.setColor(1,1,1)

    local stage = get_stage_display()  -- 显示用：根据实际状态判断
    local stage_name = ({
        [1]="阶段1：粒子 + 资源（物质诞生）",
        [2]="阶段2：粒子碰撞 → 细胞产生",
        [3]="阶段3：细胞进化（参数突变）",
        [4]="阶段4：捕食者出现，形成食物链",
        [5]="阶段5：细胞学会躲避捕食者",
        [6]="阶段6：捕食者解锁加速技能\n细胞在长寿后也可习得加速（所有生物过老会失去加速）",
        [7]="阶段7：细胞学会群体反击\n 2格范围内有4个细胞最多联手反杀周围1个捕食者",
    })[stage] or "未知阶段"

    local count_particles, count_resources = 0,0
    local count_cells, count_predators = 0,0
    for_each_cell(function(x,y,e)
        if e then
            if e.kind=="particle" then count_particles=count_particles+1
            elseif e.kind=="resource" then count_resources=count_resources+1
            elseif e.kind=="cell" then count_cells=count_cells+1
            elseif e.kind=="predator" then count_predators=count_predators+1
            end
        end
    end)

    local baseX = GRID_PIXEL_W + 10
    local y = 10
    love.graphics.print(string.format("第 %d 轮  |  Tick：%d  |  本轮已运行：%.1f 分钟", sim_round_index, tick_count, (sim_run_time/60)), baseX, y)
    y = y + 24
    love.graphics.print(stage_name, baseX, y)
    y = y + 28
    love.graphics.print(
        string.format("\n当前：粒子 %d    资源 %d", count_particles, count_resources),
        baseX, y)
    y = y + 22
    love.graphics.print(
        string.format("\n当前：细胞 %d    捕食者 %d", count_cells, count_predators),
        baseX, y)

    -- 最大数量统计
    y = y + 22
    love.graphics.print(
        string.format("\n峰值：细胞 %d    捕食者 %d", max_cell_count, max_predator_count),
        baseX, y)

    -- 第一个捕食者出现时间
    y = y + 22
    local first_info
    if first_predator_tick then
        first_info = string.format("\n第一个捕食者：Tick %d, 用时 %s",
            first_predator_tick, format_sim_time(first_predator_time))
    else
        first_info = "\n第一个捕食者：尚未出现"
    end
    love.graphics.print(first_info, baseX, y)

    -- 最长寿统计
    y = y + 22
    love.graphics.print(
        string.format("\n最长寿：细胞 %d tick    捕食者 %d tick",
            max_cell_age_seen, max_predator_age_seen),
        baseX, y)

    -- 细胞反击击杀统计
    y = y + 22
    love.graphics.print(
        string.format("\n本轮被细胞反击击杀的捕食者：%d", predator_deaths_by_cell_counter),
        baseX, y)

    -- 图例框
    local panelW = UI_WIDTH - 20
    local panelH = 660
    local panelX = GRID_PIXEL_W + 10
    local panelY = 220   -- 稍微下移，避免遮挡上面的状态文本

    love.graphics.setColor(0,0,0,0.65)
    love.graphics.rectangle("fill", panelX, panelY, panelW, panelH)
    love.graphics.setColor(1,1,1,0.85)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", panelX, panelY, panelW, panelH)

    love.graphics.setFont(font_big)
    love.graphics.print("图例", panelX + 10, panelY + 6)

    love.graphics.setFont(font_small)
    local boxX = panelX + 14
    local rowY = panelY + 40
    local lineH_small = font_small:getHeight() + 2

    local function legend_entry(r,g,b, lines)
        love.graphics.setColor(r,g,b)
        love.graphics.rectangle("fill", boxX, rowY, 18, 18)

        love.graphics.setColor(1,1,1)
        for i,txt in ipairs(lines) do
            love.graphics.print(txt, boxX + 50, rowY + (i-1)*lineH_small)
        end

        rowY = rowY + lineH_small * #lines + 8
    end

    -- 四条图例说明
    legend_entry(0.8,0.8,0.8, {
        "粒子 A~J（基础物质，多种属性）",
    })

    legend_entry(0,0.8,0, {
        "资源：可被细胞吸收的能量场，",
        "寿命结束后会降解为粒子",
    })

    legend_entry(0.2,0.6,1.0, {
        "细胞：由粒子碰撞产生，会吃资源并繁殖，",
        "具有可突变的参数（基因）",
    })

    legend_entry(1.0,0.2,0.2, {
        "捕食者：由部分细胞在特定条件下变异产生，",
        "只捕食细胞，不会直接消耗资源",
    })

    -- 规则池标题
    rowY = rowY + 10
    love.graphics.setColor(1,1,1)
    love.graphics.print("规则池示例（粒子碰撞，使用量最高前 20 条）：\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n nothing ->无事发生  particle -> 产生随机粒子\n resource ->产生资源        cell -> 产生细胞",
                        boxX, rowY)

    -- 规则部分用更小的字体
    love.graphics.setFont(font_rules)
    local lineH_rules = font_rules:getHeight() + 2

    local sortedRules = {}
    for i,r in ipairs(RULE_POOL) do
        sortedRules[i] = r
    end
    table.sort(sortedRules, function(a,b)
        return (a.usage or 0) > (b.usage or 0)
    end)

    local maxShow = math.min(20, #sortedRules)
    for i = 1, maxShow do
        local r = sortedRules[i]
        rowY = rowY + lineH_rules
        local txt = string.format(
            "#%d %s + %s → %s   概率:%.2f  使用:%d",
            r.id, r.a_type, r.b_type, r.outcome, r.prob, r.usage or 0
        )
        love.graphics.print(txt, boxX, rowY)
    end


    ----------------------------------------------------------------
    -- 底部说明区域：显示细胞 & 捕食者的条件 + 上一轮统计框
    ----------------------------------------------------------------
    love.graphics.setFont(font_small)
    love.graphics.setColor(1,1,1)

    local bottomX = 10
    local bottomY = GRID_PIXEL_H + 10
    -- 整个下方区域的总宽度
    local totalWidth = GRID_PIXEL_W + UI_WIDTH - 400
    -- 说明文字默认使用的宽度，如果右侧画统计框，就再缩小
    local textWidth = totalWidth

    ----------------------------------------------------------------
    -- 上一轮模拟的统计框：放在主体世界下方，和说明文字同一行，靠右
    ----------------------------------------------------------------
    if last_round_exists then
        local boxW, boxH = 300, 150
        -- 统计框放在右侧，和说明文字顶部对齐
        local boxX = bottomX + totalWidth - boxW
        local boxY = bottomY

        love.graphics.setColor(0,0,0,0.8)
        love.graphics.rectangle("fill", boxX, boxY, boxW, boxH)
        love.graphics.setColor(1,1,1,0.9)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", boxX, boxY, boxW, boxH)

        love.graphics.setFont(font_small)
        local lineY = boxY + 10

        love.graphics.print(
            string.format("上一轮（第 %d 轮）统计：", last_round_index or 0),
            boxX + 10, lineY
        )
        lineY = lineY + 22

        love.graphics.print(
            string.format("总 Tick：%d", last_total_ticks or 0),
            boxX + 10, lineY
        )
        lineY = lineY + 20

        love.graphics.print(
            string.format("细胞峰值：%d    捕食者峰值：%d",
                last_max_cell_count or 0,
                last_max_predator_count or 0),
            boxX + 10, lineY
        )
        lineY = lineY + 20

        local last_first_info
        if last_first_predator_tick then
            last_first_info = string.format("第一个捕食者：Tick %d, 用时 %s",
                last_first_predator_tick,
                format_sim_time(last_first_predator_time))
        else
            last_first_info = "第一个捕食者：尚未出现"
        end
        love.graphics.print(last_first_info, boxX + 10, lineY)
        lineY = lineY + 20

        love.graphics.print(
            string.format("最长寿细胞：%d tick    捕食者：%d tick",
                last_max_cell_age_seen or 0,
                last_max_predator_age_seen or 0),
            boxX + 10, lineY
        )
        lineY = lineY + 20

        love.graphics.print(
            string.format("被细胞反击死亡的捕食者：%d",
                last_predator_deaths_by_cell_counter or 0),
            boxX + 10, lineY
        )

        -- 右边占了 boxW，再给说明文字留出 20 像素空隙
        textWidth = totalWidth - boxW - 20
    end

    ----------------------------------------------------------------
    -- 左侧说明文字（和统计框同一高度，从 bottomY 开始）
    ----------------------------------------------------------------
    local cond_text = string.format(
[[（注：本模拟30分钟结算重置一次）
所有生物持续消耗能量，如果能量耗尽则死亡。
细胞存活条件(最大寿命%d tick)：
1）如果连续 %d 个 tick 没有吸收到资源，则视为饿死；
2）第6阶段后寿命超过%d的细胞解锁加速技能，寿命达到%d失去加速技能。

%d tick后，细胞 → 捕食者 的变异条件：
1）该细胞历史上累计吸收的资源量 ≥ %d；                   
2）在生命周期中至少接触过以下粒子类型中的任意两种：%s；
3）当前邻居格中存在上述粒子之一时，有一定概率发生变异（概率为%d%%，
  每个细胞只判定一次）。

捕食者繁殖条件：
1）捕食到的细胞数量 ≥ %d；
2）自身能量达到内部的分裂阈值；满足条件时才会在附近空格产生新的捕食者。

捕食者存活条件(最大寿命%d tick)：
1）只能捕食细胞，如果连续 %d 个 tick 没有捕食到细胞，则视为饿死；
2）第6阶段后捕食者获得加速，寿命超过%d tick 后会失去加速技能。]],
        CELL_MAX_AGE,
        CELL_STARVE_TICKS,
        CELL_SPEEDUP_AGE,
        CELL_SPEED_LOSS_AGE,
        STAGE_4_TICK,
        PREDATOR_REQUIRED_RESOURCE,
        table.concat(PREDATOR_REQUIRED_PARTICLES, " / "),
        (PREDATOR_MUTATION_PROB*100),
        PREDATOR_REQUIRED_KILLS,
        PREDATOR_MAX_AGE,
        PREDATOR_STARVE_TICKS,
        PREDATOR_SPEED_LOSS_AGE
    )

    -- 说明文字只画在左侧 textWidth 的区域内
    love.graphics.printf(cond_text, bottomX, bottomY, textWidth)
end

---------------------- 统计画面 --------------------------
local function draw_stats_screen()
    love.graphics.setColor(1,1,1)

    local screenW, screenH = love.graphics.getWidth(), love.graphics.getHeight()

    -- 先拿到行高
    love.graphics.setFont(font_big)
    local line_h_big = font_big:getHeight()
    local title      = string.format("第 %d 轮模拟统计", sim_round_index)

    love.graphics.setFont(font_small)
    local line_h_small = font_small:getHeight()

    -- 这里统计小行数：
    -- 1) 本轮总 Tick
    -- 2) 细胞数量峰值
    -- 3) 捕食者数量峰值
    -- 4) 第一个捕食者信息
    -- 5) 最长寿细胞
    -- 6) 最长寿捕食者
    -- 7) 被细胞反击死亡
    -- 8) 倒计时提示
    local small_line_count = 8

    local totalH =
        line_h_big               -- 标题
        + 20                     -- 标题和第一行之间的空隙
        + small_line_count * (line_h_small + 6)  -- 每行小字 + 行间距

    -- 块整体的起始 y（垂直居中）
    local baseY = (screenH - totalH) / 2
    local centerX = screenW / 2

    ----------------------------------------------------------------
    -- 标题（大字，居中）
    ----------------------------------------------------------------
    love.graphics.setFont(font_big)
    local title_w = font_big:getWidth(title)
    love.graphics.print(title, centerX - title_w / 2, baseY)

    ----------------------------------------------------------------
    -- 下面的统计行（小字，逐行居中打印）
    ----------------------------------------------------------------
    love.graphics.setFont(font_small)
    local y = baseY + line_h_big + 20

    local function print_center_line(str)
        local w = font_small:getWidth(str)
        love.graphics.print(str, centerX - w / 2, y)
        y = y + line_h_small + 6
    end

    -- 具体内容
    print_center_line(string.format("本轮总 Tick：%d", tick_count))
    print_center_line(string.format("细胞数量峰值：%d", max_cell_count))
    print_center_line(string.format("捕食者数量峰值：%d", max_predator_count))

    local first_info
    if first_predator_tick then
        first_info = string.format("第一个捕食者：Tick %d, 用时 %s",
            first_predator_tick, format_sim_time(first_predator_time))
    else
        first_info = "第一个捕食者：尚未出现"
    end
    print_center_line(first_info)

    print_center_line(string.format("最长寿细胞：%d tick", max_cell_age_seen))
    print_center_line(string.format("最长寿捕食者：%d tick", max_predator_age_seen))
    print_center_line(string.format("被细胞反击死亡的捕食者：%d", predator_deaths_by_cell_counter))

    local seconds_left = math.ceil(sim_stats_time_left)
    print_center_line(
        string.format("将在 %d 秒后重置世界并开始第 %d 轮模拟……",
            seconds_left, sim_round_index + 1)
    )
end

---------------------- LÖVE 回调 -------------------------
function love.load()
    love.window.setTitle("混沌世界v4.0")
    love.window.setMode(GRID_PIXEL_W + UI_WIDTH, WINDOW_HEIGHT)
    love.math.setRandomSeed(os.time())

    if love.filesystem.getInfo("SourceHanSansCN-Regular.otf") then
        font_small  = love.graphics.newFont("SourceHanSansCN-Regular.otf", 14)
        font_big    = love.graphics.newFont("SourceHanSansCN-Regular.otf", 18)
        font_rules  = love.graphics.newFont("SourceHanSansCN-Regular.otf", 12)
    else
        font_small  = love.graphics.newFont(12)
        font_big    = love.graphics.newFont(16)
        font_rules  = love.graphics.newFont(10)
    end
    love.graphics.setFont(font_small)

    ----------------------------------------------------------------
    -- 背景音乐
    ----------------------------------------------------------------
    if love.filesystem.getInfo("bgm.ogg") then
        bgm = love.audio.newSource("bgm.ogg", "stream")  -- 长音乐用 stream
        bgm:setLooping(true)                             -- 循环播放
        bgm:setVolume(0.6)                               -- 音量 0~1，自行调
        bgm:play()
    end
    ----------------------------------------------------------------

    for y=1,GRID_H do
        world[y]={}
        for x=1,GRID_W do world[y][x]=nil end
    end
    init_rules()
end

function love.update(dt)
    if sim_mode == "run" then
        -- 正常模拟
        sim_run_time = sim_run_time + dt
        step_accum = step_accum + dt
        while step_accum >= STEP_TIME do
            step_world()
            step_accum = step_accum - STEP_TIME
        end

        if sim_run_time >= SIM_RUN_DURATION then
            -- 进入统计模式
            sim_mode = "stats"
            sim_stats_time_left = SIM_STATS_DURATION

            -- 进入统计画面时暂停 BGM
            if bgm then
                bgm:pause()
            end
        end

    elseif sim_mode == "stats" then
        -- 只做倒计时，不再推进世界
        sim_stats_time_left = sim_stats_time_left - dt
        if sim_stats_time_left <= 0 then
            -- 把本轮结果保存为上一轮
            last_round_exists          = true
            last_round_index           = sim_round_index
            last_total_ticks           = tick_count
            last_max_cell_count        = max_cell_count
            last_max_predator_count    = max_predator_count
            last_first_predator_tick   = first_predator_tick
            last_first_predator_time   = first_predator_time
            last_max_cell_age_seen     = max_cell_age_seen
            last_max_predator_age_seen = max_predator_age_seen
            last_predator_deaths_by_cell_counter = predator_deaths_by_cell_counter

            -- 准备下一轮模拟：重置世界和统计
            sim_round_index = sim_round_index + 1
            sim_mode = "run"
            sim_run_time = 0
            step_accum = 0
            tick_count = 0

            max_cell_count        = 0
            max_predator_count    = 0
            first_predator_tick   = nil
            first_predator_time   = nil
            max_cell_age_seen     = 0
            max_predator_age_seen = 0

            -- 重置阶段5 / 6 / 7 相关状态
            total_predator_kills              = 0
            total_predator_deaths_after_avoid = 0
            cell_avoidance_unlocked           = false
            predator_speedup_unlocked         = false
            cell_deaths_after_speedup         = 0
            cell_counterattack_unlocked       = false
            predator_deaths_by_cell_counter   = 0

            for y=1,GRID_H do
                world[y]={}
                for x=1,GRID_W do world[y][x]=nil end
            end

            -- 新一轮开始时恢复 BGM
            if bgm then
                if not bgm:isPlaying() then
                    bgm:play()
                end
                bgm:setVolume(0.6)
            end

            init_rules()
        end
    end
end

function love.draw()
    love.graphics.clear(0,0,0.10)
    if sim_mode == "run" then
        draw_world()
        draw_ui()
    else
        draw_stats_screen()
    end
end

