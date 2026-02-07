---------------------------------------------------------
-- main.lua  (for LÖVE / love2d)
-- Rule-driven pixel world:
-- 10 particle types; cells are created from particles;
-- predators only come from special cell mutations and
-- only eat cells; resources decay back into particles.
---------------------------------------------------------

---------------------- Basic parameters ------------------
local GRID_W  = 80        -- width in tiles
local GRID_H  = 45        -- height in tiles
local CELL_SIZE = 12      -- tile size in pixels

local GRID_PIXEL_W = GRID_W * CELL_SIZE
local GRID_PIXEL_H = GRID_H * CELL_SIZE

local UI_WIDTH  = 360     -- right side info panel width

-- Extra vertical space for text (does not increase grid size)
local EXTRA_WINDOW_HEIGHT = 355
local WINDOW_HEIGHT = GRID_PIXEL_H + EXTRA_WINDOW_HEIGHT

local STEP_TIME = 0.05    -- world step time (seconds)

-- Time-based stage thresholds (logic only;
-- visual stage is derived from actual world state)
local STAGE_2_TICK = 200
local STAGE_3_TICK = 800
local STAGE_4_TICK = 1000

-- Particles: 10 types
local PARTICLE_TYPES = { "A","B","C","D","E","F","G","H","I","J" }
local BASE_PARTICLE_SPAWN_PROB = 0.003
local BASE_PARTICLE_DECAY_PROB = 0.001

-- Resources
local RESOURCE_MAX_ENERGY      = 20
local RESOURCE_GROW_PROB       = 0.10
local RESOURCE_DIFFUSE_PROB    = 0.02
local RESOURCE_ENERGY_PER_GROW = 1
local RESOURCE_MAX_AGE_TICKS   = 700   -- after this, resource decays into a particle

-- Cells
local CELL_BASE_METABOLISM       = 0.2
local CELL_BASE_ABSORB           = 3
local CELL_BASE_DIVIDE_THRESHOLD = 30
local CELL_BASE_LEAK             = 0.05
local CELL_MAX_AGE               = 1000   -- can live up to 1000 ticks, 800+ counts as "old"
-- starvation: how many ticks without resources until the cell dies
local CELL_STARVE_TICKS          = 160
-- cell speed-up / slow-down ages (only active after stage 6 unlocks)
local CELL_SPEEDUP_AGE           = 150
local CELL_SPEED_LOSS_AGE        = 800

-- Predators
local PREDATOR_BASE_METABOLISM   = 0.4
local PREDATOR_BASE_ATTACK_GAIN  = 10
local PREDATOR_DIVIDE_THRESHOLD  = 50
local PREDATOR_MAX_AGE           = 1200
-- predators lose their speed-up after this age (aging)
local PREDATOR_SPEED_LOSS_AGE    = 1000
-- starvation: how many ticks without eating a cell until the predator dies
local PREDATOR_STARVE_TICKS      = 100

-- Stage 5 / 6 / 7 unlock conditions
local STAGE5_KILL_THRESHOLD  = 200  -- total predator kills of cells to unlock stage 5
local STAGE6_DEATH_THRESHOLD = 80   -- after stage 5, predator deaths to unlock stage 6
local CELL_COUNTERATTACK_DEATH_THRESHOLD = 400 -- after stage 6, total cell deaths to unlock stage 7

-- Genome mutation (for cells and predators)
local MUTATION_RATE_STAGE3       = 0.15
local MUTATION_RATE_STAGE4       = 0.25
local MUTATION_MAGNITUDE         = 0.2

-- Cell -> predator mutation conditions
-- need enough absorbed resources and contact with special particle types
local PREDATOR_REQUIRED_RESOURCE  = 100      -- absorbed resource threshold
local PREDATOR_REQUIRED_PARTICLES = {"A","B","F","J"} -- must have seen at least 2 of these
local PREDATOR_MUTATION_PROB      = 1        -- probability (1 = 100%) when conditions are met

-- Predator reproduction conditions
local PREDATOR_REQUIRED_KILLS     = 5       -- must have eaten this many cells before it can divide

-- Rule evolution (collision rule pool)
local RULE_EVOLVE_INTERVAL = 500
local MAX_RULES            = 120   -- max rules
local INIT_RULE_COUNT      = 30    -- initial rule count

-- Fonts
local font_small, font_big, font_rules

-- Background music
local bgm

---------------------- Utility functions -----------------
local function rand_int(a, b) return love.math.random(a, b) end
local function rand_choice(list) return list[rand_int(1, #list)] end
local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

-- Format seconds as "XmYYs"
local function format_sim_time(seconds)
    if not seconds then return "-" end
    local total = math.floor(seconds + 0.5)
    local mins  = math.floor(total / 60)
    local secs  = total % 60
    return string.format("%dm%02ds", mins, secs)
end

---------------------- World state -----------------------
local world = {}
local tick_count = 0
local step_accum = 0

-- Per-run statistics
local max_cell_count        = 0
local max_predator_count    = 0
local first_predator_tick   = nil
local first_predator_time   = nil   -- seconds
local max_cell_age_seen     = 0
local max_predator_age_seen = 0

-- Stage 5/6/7 statistics
local total_predator_kills               = 0   -- how many cells all predators have killed
local total_predator_deaths_after_avoid  = 0   -- predator deaths after cell avoidance is unlocked
local cell_avoidance_unlocked            = false  -- Stage 5: cells learn to avoid predators
local predator_speedup_unlocked          = false  -- Stage 6: predators run faster
local cell_deaths_after_speedup          = 0      -- cell deaths after stage 6 for unlocking stage 7
local cell_counterattack_unlocked        = false  -- Stage 7: cells can counterattack
local predator_deaths_by_cell_counter    = 0      -- this run: predators killed by cell counterattack

-- ===== Previous run statistics =========================
local last_round_exists           = false
local last_round_index            = 0
local last_total_ticks            = 0
local last_max_cell_count         = 0
local last_max_predator_count     = 0
local last_first_predator_tick    = nil
local last_first_predator_time    = nil
local last_max_cell_age_seen      = 0
local last_max_predator_age_seen  = 0
local last_predator_deaths_by_cell_counter = 0
-- =======================================================

-- Multi-run control
local SIM_RUN_DURATION   = 1800  -- one run lasts 1800 seconds (30 minutes)
local SIM_STATS_DURATION = 30    -- show stats screen for 30 seconds
local sim_mode           = "run" -- "run" or "stats"
local sim_run_time       = 0     -- seconds elapsed in this run
local sim_stats_time_left = 0    -- stats screen countdown
local sim_round_index    = 1     -- which run we are in

---------------------- Neighbours ------------------------
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

---------------------- Stage logic -----------------------
-- internal stage used for mutation logic (based on time)
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

-- Detect if a cell genome already mutated away from defaults
local function is_cell_mutated(cell)
    local g = cell.genome or {}
    local eps = 1e-3
    if math.abs((g.absorb_rate or 1.0) - 1.0) > eps then return true end
    if math.abs((g.metabolism or CELL_BASE_METABOLISM) - CELL_BASE_METABOLISM) > eps then return true end
    if math.abs((g.divide_threshold or CELL_BASE_DIVIDE_THRESHOLD) - CELL_BASE_DIVIDE_THRESHOLD) > eps then return true end
    if math.abs((g.leak_rate or CELL_BASE_LEAK) - CELL_BASE_LEAK) > eps then return true end
    return false
end

-- Display stage: based on current world + unlock flags
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

---------------------- Entity constructors ---------------
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
        resource_eaten       = 0,
        seen_particles       = {},
        predator_checked     = false,
        time_since_last_food = 0,
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
        kills  = 0,
        time_since_last_kill = 0,
        genome = {
            metabolism       = genome.metabolism       or PREDATOR_BASE_METABOLISM,
            attack_gain      = genome.attack_gain      or PREDATOR_BASE_ATTACK_GAIN,
            divide_threshold = genome.divide_threshold or PREDATOR_DIVIDE_THRESHOLD,
        }
    }
end

---------------------- Rule pool -------------------------
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

---------------------- Stage 1: particles + resources ----
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

                if e.age > RESOURCE_MAX_AGE_TICKS then
                    -- lifetime ended: decay into basic particle
                    world[y][x] = make_particle(rand_choice(PARTICLE_TYPES))
                else
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

---------------------- Cell / predator mutation & stage counters ----
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

-- Register one successful predator kill
local function register_predator_kill()
    total_predator_kills = total_predator_kills + 1
    if (not cell_avoidance_unlocked) and total_predator_kills >= STAGE5_KILL_THRESHOLD then
        cell_avoidance_unlocked = true
    end
end

-- Register one predator death (after stage 5, used to unlock stage 6)
local function register_predator_death()
    if cell_avoidance_unlocked and (not predator_speedup_unlocked) then
        total_predator_deaths_after_avoid = total_predator_deaths_after_avoid + 1
        if total_predator_deaths_after_avoid >= STAGE6_DEATH_THRESHOLD then
            predator_speedup_unlocked = true
        end
    end
end

-- Register cell death (after stage 6, used to unlock stage 7)
local function register_cell_death()
    if predator_speedup_unlocked and (not cell_counterattack_unlocked) then
        cell_deaths_after_speedup = cell_deaths_after_speedup + 1
        if cell_deaths_after_speedup >= CELL_COUNTERATTACK_DEATH_THRESHOLD then
            cell_counterattack_unlocked = true
        end
    end
end

-- Register predator killed by cell counterattack
local function register_predator_death_by_counter()
    predator_deaths_by_cell_counter = predator_deaths_by_cell_counter + 1
end

-- Has the cell seen at least two of the required particles?
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

---------------------- Life behaviour --------------------
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

-- After stage 6, long-lived cells can move faster:
-- 1) predator_speedup_unlocked == true (stage 6 unlocked)
-- 2) CELL_SPEEDUP_AGE < age <= CELL_SPEED_LOSS_AGE -> 2 moves per tick
-- 3) otherwise -> 1 move per tick
local function get_cell_move_steps(cell)
    if predator_speedup_unlocked
       and cell.age > CELL_SPEEDUP_AGE
       and cell.age <= CELL_SPEED_LOSS_AGE then
        return 2
    else
        return 1
    end
end

-- Predators: after stage 6 they move faster, but lose speed after
-- PREDATOR_SPEED_LOSS_AGE (aging).
local function get_predator_move_steps(pred)
    if predator_speedup_unlocked and pred.age <= PREDATOR_SPEED_LOSS_AGE then
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
    if cell.age > max_cell_age_seen then
        max_cell_age_seen = cell.age
    end

    cell.time_since_last_food = (cell.time_since_last_food or 0) + 1

    -- track nearby particles (for mutation conditions)
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

    -- Stage 4: cells may mutate into predators (each cell checks only once)
    if stage == 4
       and not cell.predator_checked
       and near_required_particle
       and has_seen_required_particles(cell)
       and (cell.resource_eaten or 0) >= PREDATOR_REQUIRED_RESOURCE then

        cell.predator_checked = true
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

    -- Metabolism
    cell.energy = cell.energy - cell.genome.metabolism
    cell.energy = cell.energy - cell.genome.leak_rate * cell.energy
    if cell.energy<=0 then
        register_cell_death()
        world[y][x]=nil
        return
    end

    -- Eat resources
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
                cell.time_since_last_food = 0
                if n.energy<=0 then world[ny][nx]=nil end
                ate=true; break
            end
        end
    end

    -- No food this tick -> movement (possibly multiple steps)
    if not ate then
        local moves = get_cell_move_steps(cell)

        for step = 1, moves do
            if world[y][x] ~= cell then
                break
            end

            if cell_avoidance_unlocked then
                -- try to move to a tile whose neighbours have no predators
                local safe_positions = {}

                for _,d in ipairs(neighbor_dirs8) do
                    local nx,ny = x + d.dx, y + d.dy
                    if in_bounds(nx,ny) and not world[ny][nx] then
                        local danger = false
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
                    -- fallback to simple random walk
                    local nx,ny = random_neighbor(x,y)
                    if in_bounds(nx,ny) and not world[ny][nx] then
                        world[ny][nx] = cell
                        world[y][x]  = nil
                        x,y = nx,ny
                    end
                end
            else
                -- before stage 5: simple random walk
                local nx,ny = random_neighbor(x,y)
                if in_bounds(nx,ny) and not world[ny][nx] then
                    world[ny][nx] = cell
                    world[y][x]  = nil
                    x,y = nx,ny
                end
            end
        end
    end

    -- Stage 7: cell counterattack (group defence)
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

        -- at least 4 cells in 2-tile radius and 1-2 predators -> kill up to 2 predators
        if cell_count >= 4 and #predators > 0 and #predators <= 2 then
            local kills = math.min(2, #predators)
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

    -- Starvation
    if (cell.time_since_last_food or 0) >= CELL_STARVE_TICKS then
        register_cell_death()
        world[y][x] = nil
        return
    end

    -- Division
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

    if pred.age > max_predator_age_seen then
        max_predator_age_seen = pred.age
    end

    pred.time_since_last_kill = (pred.time_since_last_kill or 0) + 1

    pred.energy = pred.energy - pred.genome.metabolism
    if pred.energy <= 0 then
        register_predator_death()
        world[y][x] = nil
        return
    end

    local moves = get_predator_move_steps(pred)

    for step = 1, moves do
        if not world[y][x] or world[y][x] ~= pred then
            return
        end

        local hunted=false
        for _,d in ipairs(neighbor_dirs8) do
            local nx,ny = x+d.dx, y+d.dy
            if in_bounds(nx,ny) then
                local n = world[ny][nx]
                if n and n.kind=="cell" then
                    pred.energy = pred.energy + pred.genome.attack_gain + n.energy
                    pred.kills  = (pred.kills or 0) + 1
                    pred.time_since_last_kill = 0

                    register_predator_kill()
                    register_cell_death()

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

    if (pred.time_since_last_kill or 0) >= PREDATOR_STARVE_TICKS then
        register_predator_death()
        world[y][x] = nil
        return
    end

    -- Reproduce
    if pred.energy >= pred.genome.divide_threshold
       and (pred.kills or 0) >= PREDATOR_REQUIRED_KILLS then

        local cx,cy = find_empty_neighbor(x,y)
        if cx and cy then
            local child_energy = pred.energy * 0.5
            pred.energy = pred.energy * 0.5
            pred.kills  = 0

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
    local stage = get_stage_logic()
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

---------------------- One world step --------------------
local function step_world()
    tick_count = tick_count + 1

    spawn_particles()
    decay_particles()
    handle_collisions()
    update_resources()
    update_life()

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

    if count_predators > 0 and not first_predator_tick then
        first_predator_tick = tick_count
        first_predator_time = tick_count * STEP_TIME
    end

    if tick_count % RULE_EVOLVE_INTERVAL == 0 then
        evolve_rules()
    end
end

---------------------- Rendering: world ------------------
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

---------------------- Rendering: right UI ---------------
local function draw_ui()
    love.graphics.setFont(font_small)
    love.graphics.setColor(1,1,1)

    local stage = get_stage_display()
    local stage_name = ({
        [1]="Stage 1: Particles + resources (matter appears)",
        [2]="Stage 2: Collisions create cells",
        [3]="Stage 3: Cells evolve (parameter mutation)",
        [4]="Stage 4: Predators appear and form a food chain",
        [5]="Stage 5: Cells learn to avoid predators",
        [6]="Stage 6: Predators gain speed; long-lived cells may also speed up",
        [7]="Stage 7: Cells can group counterattack (within 2 tiles, up to 2 predators)",
    })[stage] or "Unknown stage"

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
    love.graphics.print(string.format(
        "Run %d | Tick: %d | Elapsed: %.1f min",
        sim_round_index, tick_count, (sim_run_time/60)), baseX, y)
    y = y + 24
    love.graphics.printf(stage_name, baseX, y, UI_WIDTH - 20)
    y = y + 32
    love.graphics.print(
        string.format("Now: particles %d   resources %d", count_particles, count_resources),
        baseX, y)
    y = y + 20
    love.graphics.print(
        string.format("Now: cells %d   predators %d", count_cells, count_predators),
        baseX, y)

    y = y + 20
    love.graphics.print(
        string.format("Peak: cells %d   predators %d", max_cell_count, max_predator_count),
        baseX, y)

    y = y + 20
    local first_info
    if first_predator_tick then
        first_info = string.format(
            "First predator: tick %d, time %s",
            first_predator_tick, format_sim_time(first_predator_time))
    else
        first_info = "First predator: not yet"
    end
    love.graphics.print(first_info, baseX, y)

    y = y + 20
    love.graphics.print(
        string.format("Max lifetime: cell %d ticks   predator %d ticks",
            max_cell_age_seen, max_predator_age_seen),
        baseX, y)

    y = y + 20
    love.graphics.print(
        string.format("Predators killed by cell counterattack (this run): %d",
            predator_deaths_by_cell_counter),
        baseX, y)

    -- Legend panel
    local panelW = UI_WIDTH - 20
    local panelH = 700
    local panelX = GRID_PIXEL_W + 10
    local panelY = 190

    love.graphics.setColor(0,0,0,0.65)
    love.graphics.rectangle("fill", panelX, panelY, panelW, panelH)
    love.graphics.setColor(1,1,1,0.85)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", panelX, panelY, panelW, panelH)

    love.graphics.setFont(font_big)
    love.graphics.print("Legend", panelX + 10, panelY + 6)

    love.graphics.setFont(font_small)
    local boxX = panelX + 14
    local rowY = panelY + 40
    local lineH_small = font_small:getHeight() + 2
    local text_width = panelW - 70

    -- Legend text uses wrapping; advance Y by the *wrapped* line count
    -- to avoid overlap when a sentence exceeds the available width.
    local function legend_entry(r,g,b, lines)
        love.graphics.setColor(r,g,b)
        love.graphics.rectangle("fill", boxX, rowY, 18, 18)

        love.graphics.setColor(1,1,1)
        local textY = rowY
        for _, txt in ipairs(lines) do
            local _, wrapped = font_small:getWrap(txt, text_width)
            for _, wline in ipairs(wrapped) do
                love.graphics.print(wline, boxX + 50, textY)
                textY = textY + lineH_small
            end
        end

        rowY = textY + 8
    end

    legend_entry(0.8,0.8,0.8, {
        "Particles A~J: basic matter with different properties.",
    })

    legend_entry(0,0.8,0, {
        "Resources: energy fields that cells can absorb.",
        "When lifetime ends they decay into particles.",
    })

    legend_entry(0.2,0.6,1.0, {
        "Cells: created by particle collisions, eat resources,",
        "reproduce, and have mutable parameters (genome).",
    })

    legend_entry(1.0,0.2,0.2, {
        "Predators: mutated from some special cells,",
        "only eat cells and do not consume resources directly.",
    })

    rowY = rowY + 10
    love.graphics.setColor(1,1,1)
    local ruleHeader = "Rule pool samples (top 20 collision rules by usage):"
    love.graphics.printf(ruleHeader, boxX, rowY, panelW - 30)
    do
        local _, wrapped = font_small:getWrap(ruleHeader, panelW - 30)
        rowY = rowY + lineH_small * math.max(1, #wrapped) + 4
    end

    -- Rules in a smaller font
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
            "#%d %s + %s -> %s   p=%.2f  used:%d",
            r.id, r.a_type, r.b_type, r.outcome, r.prob, r.usage or 0
        )
        love.graphics.print(txt, boxX, rowY)
    end

    love.graphics.setFont(font_small)
    rowY = rowY + lineH_small * 2
    love.graphics.print("nothing -> nothing happens", boxX, rowY); rowY = rowY + lineH_small
    love.graphics.print("particle -> generate a random particle", boxX, rowY); rowY = rowY + lineH_small
    love.graphics.print("resource -> generate resource", boxX, rowY); rowY = rowY + lineH_small
    love.graphics.print("cell -> generate cell", boxX, rowY)

    ----------------------------------------------------------------
    -- Bottom description area: cell/predator conditions + last run
    ----------------------------------------------------------------
    love.graphics.setFont(font_small)
    love.graphics.setColor(1,1,1)

    local bottomX = 10
    local bottomY = GRID_PIXEL_H + 10
    local totalWidth = GRID_PIXEL_W + UI_WIDTH - 400
    local textWidth = totalWidth

    if last_round_exists then
        local boxW, boxH = 300, 150
        local boxX2 = bottomX + totalWidth - boxW
        local boxY2 = bottomY

        love.graphics.setColor(0,0,0,0.8)
        love.graphics.rectangle("fill", boxX2, boxY2, boxW, boxH)
        love.graphics.setColor(1,1,1,0.9)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", boxX2, boxY2, boxW, boxH)

        local lineY = boxY2 + 10

        love.graphics.print(
            string.format("Previous run (Run %d):", last_round_index or 0),
            boxX2 + 10, lineY
        )
        lineY = lineY + 22

        love.graphics.print(
            string.format("Total ticks: %d", last_total_ticks or 0),
            boxX2 + 10, lineY
        )
        lineY = lineY + 20

        love.graphics.print(
            string.format("Peak cells: %d   peak predators: %d",
                last_max_cell_count or 0,
                last_max_predator_count or 0),
            boxX2 + 10, lineY
        )
        lineY = lineY + 20

        local last_first_info
        if last_first_predator_tick then
            last_first_info = string.format("First predator: tick %d, time %s",
                last_first_predator_tick,
                format_sim_time(last_first_predator_time))
        else
            last_first_info = "First predator: not yet"
        end
        love.graphics.print(last_first_info, boxX2 + 10, lineY)
        lineY = lineY + 20

        love.graphics.print(
            string.format("Max lifetime cell: %d   predator: %d",
                last_max_cell_age_seen or 0,
                last_max_predator_age_seen or 0),
            boxX2 + 10, lineY
        )
        lineY = lineY + 20

        love.graphics.print(
            string.format("Predators killed by cell counterattack: %d",
                last_predator_deaths_by_cell_counter or 0),
            boxX2 + 10, lineY
        )

        textWidth = totalWidth - boxW - 20
    end

    local cond_text = string.format(
[[Note: the simulation automatically restarts every 30 minutes.

Cell survival (max lifetime %d ticks):
1) Cells constantly consume energy. If energy reaches zero, the cell dies.
2) If a cell fails to absorb resources for %d consecutive ticks, it starves.
3) After stage 6 is unlocked, cells older than %d ticks gain a speed boost,
   but once they pass %d ticks they lose this boost (old age).

After tick %d, some cells may mutate into predators if:
1) Total resources absorbed by this cell >= %d;
2) During its lifetime it has contacted at least two of: %s;
3) When at least one of these particles is in the 8-neighbourhood, the cell
   has a %d%% chance to mutate (checked only once per cell).

Predator reproduction:
1) The predator has eaten at least %d cells;
2) Its energy reaches the internal divide threshold; then a new predator
   may appear on a nearby empty tile.

Predator survival (max lifetime %d ticks):
1) Predators constantly consume energy. If energy reaches zero, it dies.
2) If a predator fails to eat any cell for %d consecutive ticks, it starves.]],
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
        PREDATOR_STARVE_TICKS
    )

    love.graphics.printf(cond_text, bottomX, bottomY, textWidth)
end

---------------------- Stats screen ----------------------
local function draw_stats_screen()
    love.graphics.setColor(1,1,1)

    local screenW, screenH = love.graphics.getWidth(), love.graphics.getHeight()

    love.graphics.setFont(font_big)
    local line_h_big = font_big:getHeight()
    local title      = string.format("Run %d statistics", sim_round_index)

    love.graphics.setFont(font_small)
    local line_h_small = font_small:getHeight()

    local small_line_count = 8

    local totalH =
        line_h_big
        + 20
        + small_line_count * (line_h_small + 6)

    local baseY = (screenH - totalH) / 2
    local centerX = screenW / 2

    love.graphics.setFont(font_big)
    local title_w = font_big:getWidth(title)
    love.graphics.print(title, centerX - title_w / 2, baseY)

    love.graphics.setFont(font_small)
    local y = baseY + line_h_big + 20

    local function print_center_line(str)
        local w = font_small:getWidth(str)
        love.graphics.print(str, centerX - w / 2, y)
        y = y + line_h_small + 6
    end

    print_center_line(string.format("Total ticks this run: %d", tick_count))
    print_center_line(string.format("Peak cells: %d", max_cell_count))
    print_center_line(string.format("Peak predators: %d", max_predator_count))

    local first_info
    if first_predator_tick then
        first_info = string.format("First predator: tick %d, time %s",
            first_predator_tick, format_sim_time(first_predator_time))
    else
        first_info = "First predator: not yet"
    end
    print_center_line(first_info)

    print_center_line(string.format("Max lifetime cell: %d ticks", max_cell_age_seen))
    print_center_line(string.format("Max lifetime predator: %d ticks", max_predator_age_seen))
    print_center_line(string.format("Predators killed by cell counterattack: %d", predator_deaths_by_cell_counter))

    local seconds_left = math.ceil(sim_stats_time_left)
    print_center_line(
        string.format("World will reset in %d seconds, starting run %d...",
            seconds_left, sim_round_index + 1)
    )
end

---------------------- LÖVE callbacks --------------------
function love.load()
    love.window.setTitle("Rule-evolving pixel world")
    love.window.setMode(GRID_PIXEL_W + UI_WIDTH, WINDOW_HEIGHT)
    love.math.setRandomSeed(os.time())

    -- Use default fonts (system-dependent); ASCII only, so any font is fine.
    font_small  = love.graphics.newFont(12)
    font_big    = love.graphics.newFont(16)
    font_rules  = love.graphics.newFont(10)
    love.graphics.setFont(font_small)

    -- Background music (optional)
    if love.filesystem.getInfo("bgm.ogg") then
        bgm = love.audio.newSource("bgm.ogg", "stream")
        bgm:setLooping(true)
        bgm:setVolume(0.6)
        bgm:play()
    end

    for y=1,GRID_H do
        world[y]={}
        for x=1,GRID_W do world[y][x]=nil end
    end
    init_rules()
end

function love.update(dt)
    if sim_mode == "run" then
        sim_run_time = sim_run_time + dt
        step_accum = step_accum + dt
        while step_accum >= STEP_TIME do
            step_world()
            step_accum = step_accum - STEP_TIME
        end

        if sim_run_time >= SIM_RUN_DURATION then
            sim_mode = "stats"
            sim_stats_time_left = SIM_STATS_DURATION

            if bgm then
                bgm:pause()
            end
        end

    elseif sim_mode == "stats" then
        sim_stats_time_left = sim_stats_time_left - dt
        if sim_stats_time_left <= 0 then
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
