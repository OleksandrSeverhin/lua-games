-- Muncher: an original maze-chase game for Lilka (KeiraOS Lua API)
-- Eat every pellet, dodge the four Blobs, grab a big pellet to turn the tables.
-- Controls: D-pad = steer, START = pause, A = restart (after game over), B = exit

-- Left half of the maze (18 columns, the right half is mirrored from it)
--   # wall   . pellet   o big pellet   - ghost door   G ghost house   space = empty
local MAP_HALF = {
    "##################",
    "#o........#.......",
    "#.####.##.#.#####.",
    "#.####.##.#.#####.",
    "#.................",
    "#.####.#.#####.###",
    "#......#...#......",
    "######.#.########.",
    "######.#..........",
    "######.#.###.####-",
    "######.#.###.#GGGG",
    "      .     .#GGGG",
    "######.#.###.#####",
    "######.#..........",
    "######.#.########.",
    "#......#..........",
    "#.####.#.#####.###",
    "#o..##............",
    "###.##.#.#####.###",
    "#......#...#......",
    "#.#######.#.#####.",
    "#o................",
    "#.####.#######.###",
    "#.####............",
    "#.................",
    "#.####.##.#.#####.",
    "##################",
}

-- Configuration
local W = 35
local H = #MAP_HALF
local HUD_HEIGHT = 24
local PLAYER_START_X, PLAYER_START_Y = 17, 19
local EXIT_X, EXIT_Y = 17, 8     -- tile just outside the ghost house door
local HOME_X, HOME_Y = 17, 10    -- tile inside the ghost house
local START_LIVES = 3
local PLAYER_SPEED = 7.2         -- tiles per second
local EATEN_SPEED = 14
local FRIGHT_SPEED = 4.5
local LEAVE_SPEED = 5
local MODE_SCHEDULE = { 7, 20, 7, 20, 5, 20, 5 } -- scatter, chase, scatter, ...; then chase forever

-- Layout (computed in lilka.init)
local T, ox, oy

-- Colors
local BLACK, WHITE, RED, YELLOW, WALL_FILL, WALL_LINE, PELLET, DOOR, FRIGHT_BLUE, GRAY
local GHOST_COLORS

-- Maze data
local cells          -- cells[y][x] = character
local wall_runs      -- horizontal runs of wall tiles, for fast drawing
local pellets        -- pellets[y][x] = 1 (small) or 2 (big)
local pellets_left
local exit_dist      -- BFS distance to the ghost house exit
local home_dist      -- BFS distance to the ghost house interior

-- Directions
local UP    = { dx = 0,  dy = -1 }
local LEFT  = { dx = -1, dy = 0 }
local DOWN  = { dx = 0,  dy = 1 }
local RIGHT = { dx = 1,  dy = 0 }
local DIRS = { UP, LEFT, DOWN, RIGHT }

-- Game state
local player
local want           -- direction the player is asking for
local face           -- direction the player is facing (for the mouth and ghost AI)
local ghosts
local score, high_score = 0, 0
local lives
local level
local phase          -- "ready", "play", "dying", "win", "over"
local phase_timer
local paused
local anim
local mode, mode_idx, mode_timer
local fright_timer
local round_time
local combo
local scatter_corners

-- ## Helpers ##

local function floor(v)
    return math.floor(v)
end

local function rand_index(n)
    -- KeiraOS math.random(min, max) excludes max; clamp in case it is inclusive
    return math.min(n, math.random(1, n + 1))
end

local function tile(x, y)
    if y < 0 or y >= H then
        return "#"
    end
    return cells[y][x % W]
end

-- kind: "player" / "ghost" cannot use the house, "special" can
local function can_walk(x, y, kind)
    local c = tile(x, y)
    if c == "#" then
        return false
    end
    if c == "-" or c == "G" then
        return kind == "special"
    end
    return true
end

local function bfs(sx, sy)
    local dist = { [sy * W + sx] = 0 }
    local queue = { { sx, sy } }
    local head = 1
    while head <= #queue do
        local cur = queue[head]
        head = head + 1
        local d = dist[cur[2] * W + cur[1]]
        for _, dir in ipairs(DIRS) do
            local nx = (cur[1] + dir.dx) % W
            local ny = cur[2] + dir.dy
            local key = ny * W + nx
            if dist[key] == nil and can_walk(nx, ny, "special") then
                dist[key] = d + 1
                queue[#queue + 1] = { nx, ny }
            end
        end
    end
    return dist
end

local function build_maze()
    cells = {}
    for y = 0, H - 1 do
        local half = MAP_HALF[y + 1]
        local row = half .. string.reverse(string.sub(half, 1, 17))
        cells[y] = {}
        for x = 0, W - 1 do
            cells[y][x] = string.sub(row, x + 1, x + 1)
        end
    end

    wall_runs = {}
    for y = 0, H - 1 do
        local x = 0
        while x < W do
            if cells[y][x] == "#" then
                local start = x
                while x < W and cells[y][x] == "#" do
                    x = x + 1
                end
                wall_runs[#wall_runs + 1] = { x = start, y = y, len = x - start }
            else
                x = x + 1
            end
        end
    end

    exit_dist = bfs(EXIT_X, EXIT_Y)
    home_dist = bfs(HOME_X, HOME_Y)
end

local function build_pellets()
    pellets = {}
    pellets_left = 0
    for y = 0, H - 1 do
        pellets[y] = {}
        for x = 0, W - 1 do
            local c = cells[y][x]
            if (c == "." or c == "o") and not (x == PLAYER_START_X and y == PLAYER_START_Y) then
                pellets[y][x] = (c == "o") and 2 or 1
                pellets_left = pellets_left + 1
            end
        end
    end
end

-- Moves an entity back along the way it came
local function flip(e)
    if e.dx ~= 0 or e.dy ~= 0 then
        e.x = (e.x + e.dx) % W
        e.y = e.y + e.dy
        e.dx = -e.dx
        e.dy = -e.dy
        e.prog = 1 - e.prog
    end
end

-- Moves an entity along its direction. `choose` is called on arriving at each tile
-- (and when standing still) to pick the next direction.
local function advance(e, speed, delta, choose)
    if e.dx == 0 and e.dy == 0 then
        choose(e)
        if e.dx == 0 and e.dy == 0 then
            return
        end
    end
    e.prog = e.prog + speed * delta
    while e.prog >= 1 do
        e.prog = e.prog - 1
        e.x = (e.x + e.dx) % W
        e.y = e.y + e.dy
        choose(e)
        if e.dx == 0 and e.dy == 0 then
            e.prog = 0
            break
        end
    end
end

local function position(e)
    return e.x + e.dx * e.prog, e.y + e.dy * e.prog
end

-- ## Player ##

local function start_fright()
    fright_timer = math.max(2.5, 7 - (level - 1) * 0.6)
    combo = 1
    for _, g in ipairs(ghosts) do
        if g.state == "normal" or g.state == "leaving" then
            if not g.fright and g.state == "normal" then
                flip(g)
            end
            g.fright = true
        end
    end
end

local function player_choose(e)
    -- Eat whatever is on this tile
    local p = pellets[e.y][e.x]
    if p then
        pellets[e.y][e.x] = nil
        pellets_left = pellets_left - 1
        if p == 2 then
            score = score + 50
            start_fright()
        else
            score = score + 10
        end
    end

    if want and can_walk(e.x + want.dx, e.y + want.dy, "player") then
        e.dx, e.dy = want.dx, want.dy
    elseif not can_walk(e.x + e.dx, e.y + e.dy, "player") then
        e.dx, e.dy = 0, 0
    end
    if e.dx ~= 0 or e.dy ~= 0 then
        face = { dx = e.dx, dy = e.dy }
    end
end

-- ## Ghosts ##

local function make_ghost(x, y, state, dx, dy, release)
    return { x = x, y = y, dx = dx, dy = dy, prog = 0, state = state, release = release, fright = false }
end

local function ghost_target(g, index)
    if mode == "scatter" then
        return scatter_corners[index][1], scatter_corners[index][2]
    end
    if index == 1 then
        return player.x, player.y
    elseif index == 2 then
        return player.x + 4 * face.dx, player.y + 4 * face.dy
    elseif index == 3 then
        local lead = ghosts[1]
        local ax, ay = player.x + 2 * face.dx, player.y + 2 * face.dy
        return 2 * ax - lead.x, 2 * ay - lead.y
    end
    local dx, dy = player.x - g.x, player.y - g.y
    if dx * dx + dy * dy > 64 then
        return player.x, player.y
    end
    return scatter_corners[index][1], scatter_corners[index][2]
end

local function ghost_choose(g, index)
    if g.state == "leaving" and g.x == EXIT_X and g.y == EXIT_Y then
        g.state = "normal"
        g.dx, g.dy = -1, 0
    end
    if g.state == "eaten" and g.x == HOME_X and g.y == HOME_Y then
        g.state = "leaving"
    end

    -- Going home or leaving home: follow the shortest path
    if g.state == "leaving" or g.state == "eaten" then
        local dist = (g.state == "leaving") and exit_dist or home_dist
        local best, best_d = nil, 1e9
        for _, d in ipairs(DIRS) do
            local nx = (g.x + d.dx) % W
            local ny = g.y + d.dy
            if can_walk(nx, ny, "special") then
                local dd = dist[ny * W + nx]
                if dd and dd < best_d then
                    best, best_d = d, dd
                end
            end
        end
        if best then
            g.dx, g.dy = best.dx, best.dy
        end
        return
    end

    -- Roaming: pick any direction except straight back
    local opts = {}
    for _, d in ipairs(DIRS) do
        if not (d.dx == -g.dx and d.dy == -g.dy) and can_walk(g.x + d.dx, g.y + d.dy, "ghost") then
            opts[#opts + 1] = d
        end
    end
    if #opts == 0 then
        g.dx, g.dy = -g.dx, -g.dy
        return
    end

    local pick
    if g.fright then
        pick = opts[rand_index(#opts)]
    else
        local tx, ty = ghost_target(g, index)
        local best_d = 1e9
        for _, d in ipairs(opts) do
            local ex, ey = g.x + d.dx - tx, g.y + d.dy - ty
            local dd = ex * ex + ey * ey
            if dd < best_d then
                pick, best_d = d, dd
            end
        end
    end
    g.dx, g.dy = pick.dx, pick.dy
end

local function ghost_speed(g)
    if g.state == "eaten" then
        return EATEN_SPEED
    elseif g.state == "leaving" then
        return LEAVE_SPEED
    elseif g.fright then
        return FRIGHT_SPEED
    end
    return math.min(7.0, 6.2 + (level - 1) * 0.25)
end

-- ## Round / level setup ##

local function reset_actors()
    player = { x = PLAYER_START_X, y = PLAYER_START_Y, dx = 0, dy = 0, prog = 0 }
    want = LEFT
    face = LEFT

    local speedup = math.max(0.4, 1 - (level - 1) * 0.1)
    ghosts = {
        make_ghost(17, 8, "normal", -1, 0, 0),
        make_ghost(15, 11, "waiting", 0, 0, 3 * speedup),
        make_ghost(17, 11, "waiting", 0, 0, 6 * speedup),
        make_ghost(19, 11, "waiting", 0, 0, 9 * speedup),
    }

    mode = "scatter"
    mode_idx = 1
    mode_timer = MODE_SCHEDULE[1]
    fright_timer = 0
    round_time = 0
    combo = 1
    anim = 0
    phase = "ready"
    phase_timer = 2
end

local function start_level()
    build_pellets()
    reset_actors()
end

local function new_game()
    score = 0
    lives = START_LIVES
    level = 1
    paused = false
    start_level()
end

-- ## Per-frame logic ##

local function lose_life()
    phase = "dying"
    phase_timer = 1.6
    lives = lives - 1
    if score > high_score then
        high_score = score
    end
end

local function update_modes(delta)
    if mode_idx <= #MODE_SCHEDULE then
        mode_timer = mode_timer - delta
        if mode_timer <= 0 then
            mode_idx = mode_idx + 1
            mode = (mode == "scatter") and "chase" or "scatter"
            mode_timer = MODE_SCHEDULE[mode_idx] or 1e9
            for _, g in ipairs(ghosts) do
                if g.state == "normal" and not g.fright then
                    flip(g)
                end
            end
        end
    end

    if fright_timer > 0 then
        fright_timer = fright_timer - delta
        if fright_timer <= 0 then
            for _, g in ipairs(ghosts) do
                g.fright = false
            end
        end
    end
end

local function check_collisions()
    local px, py = position(player)
    for _, g in ipairs(ghosts) do
        if g.state == "normal" or g.state == "leaving" then
            local gx, gy = position(g)
            local dx, dy = gx - px, gy - py
            if dx * dx + dy * dy < 0.5 then
                if g.fright then
                    g.state = "eaten"
                    g.fright = false
                    score = score + 200 * combo
                    combo = combo * 2
                else
                    lose_life()
                    return
                end
            end
        end
    end
end

local function play_update(delta, state)
    -- Input
    local pressed
    if state.up.pressed then
        pressed = UP
    elseif state.down.pressed then
        pressed = DOWN
    elseif state.left.pressed then
        pressed = LEFT
    elseif state.right.pressed then
        pressed = RIGHT
    end
    if pressed then
        want = pressed
        -- Reversing is allowed at any moment
        if player.dx == -pressed.dx and player.dy == -pressed.dy and (player.dx ~= 0 or player.dy ~= 0) then
            flip(player)
            face = pressed
        end
    end

    round_time = round_time + delta
    anim = anim + delta
    update_modes(delta)

    advance(player, PLAYER_SPEED, delta, player_choose)

    for i, g in ipairs(ghosts) do
        if g.state == "waiting" and round_time >= g.release then
            g.state = "leaving"
        end
        if g.state ~= "waiting" then
            advance(g, ghost_speed(g), delta, function(e) ghost_choose(e, i) end)
        end
    end

    check_collisions()

    if phase == "play" and pellets_left <= 0 then
        phase = "win"
        phase_timer = 2
        if score > high_score then
            high_score = score
        end
    end
end

function lilka.init()
    BLACK = display.color565(0, 0, 0)
    WHITE = display.color565(255, 255, 255)
    RED = display.color565(255, 60, 60)
    YELLOW = display.color565(255, 230, 0)
    WALL_FILL = display.color565(0, 0, 90)
    WALL_LINE = display.color565(40, 90, 255)
    PELLET = display.color565(255, 210, 170)
    DOOR = display.color565(255, 150, 200)
    FRIGHT_BLUE = display.color565(40, 60, 255)
    GRAY = display.color565(90, 90, 90)
    GHOST_COLORS = {
        display.color565(255, 40, 40),
        display.color565(255, 150, 200),
        display.color565(0, 230, 230),
        display.color565(255, 150, 0),
    }

    T = math.max(1, math.min(floor(display.width / W), floor((display.height - HUD_HEIGHT) / H)))
    ox = floor((display.width - W * T) / 2)
    oy = HUD_HEIGHT + floor((display.height - HUD_HEIGHT - H * T) / 2)

    scatter_corners = {
        { W - 2, 1 },
        { 1, 1 },
        { W - 2, H - 2 },
        { 1, H - 2 },
    }

    build_maze()
    new_game()
end

function lilka.update(delta)
    delta = math.min(delta or 0, 0.1)
    local state = controller.get_state()

    if state.b.just_pressed then
        util.exit()
        return
    end

    if phase == "over" then
        if state.a.just_pressed then
            new_game()
        end
        return
    end

    if state.start.just_pressed and phase == "play" then
        paused = not paused
    end
    if paused then
        return
    end

    if phase == "ready" then
        phase_timer = phase_timer - delta
        if phase_timer <= 0 then
            phase = "play"
        end
    elseif phase == "play" then
        play_update(delta, state)
    elseif phase == "dying" then
        phase_timer = phase_timer - delta
        if phase_timer <= 0 then
            if lives <= 0 then
                phase = "over"
            else
                reset_actors()
            end
        end
    elseif phase == "win" then
        phase_timer = phase_timer - delta
        if phase_timer <= 0 then
            level = level + 1
            start_level()
        end
    end
end

-- ## Drawing ##

local function center_of(px, py)
    return floor(ox + (px + 0.5) * T), floor(oy + (py + 0.5) * T)
end

local function draw_text_centered(text, y, char_w)
    display.set_cursor(floor((display.width - #text * char_w) / 2), y)
    display.print(text)
end

local function draw_banner(lines)
    -- lines: list of { text, color }
    local h = #lines * 24 + 12
    local w = 200
    local x = floor((display.width - w) / 2)
    local y = floor((display.height - h) / 2)
    display.fill_rect(x, y, w, h, BLACK)
    display.draw_rect(x, y, w, h, WALL_LINE)
    display.set_font("10x20")
    for i, line in ipairs(lines) do
        display.set_text_color(line[2])
        draw_text_centered(line[1], y + 6 + i * 24 - 6, 10)
    end
end

local function draw_player(radius)
    local px, py = position(player)
    local cx, cy = center_of(px, py)
    if radius < 1 then
        return
    end
    display.fill_circle(cx, cy, radius, YELLOW)

    if phase == "dying" then
        return
    end
    -- Chomping mouth: a black wedge pointing the way we face
    local open = math.abs(((anim * 5) % 2) - 1) -- 0..1 triangle wave
    if player.dx == 0 and player.dy == 0 then
        open = 0.5
    end
    local len = radius + 2
    local fx, fy = face.dx, face.dy
    local sx, sy = -fy, fx
    local w = open * 0.9
    display.fill_triangle(
        cx, cy,
        floor(cx + fx * len + sx * len * w), floor(cy + fy * len + sy * len * w),
        floor(cx + fx * len - sx * len * w), floor(cy + fy * len - sy * len * w),
        BLACK)
end

local function draw_ghost(g, index)
    local gx, gy = position(g)
    local cx, cy = center_of(gx, gy)
    local r = math.max(2, floor(T / 2))
    local fx, fy = g.dx, g.dy

    if g.state ~= "eaten" then
        local color = GHOST_COLORS[index]
        if g.fright then
            color = FRIGHT_BLUE
            if fright_timer < 2 and floor(fright_timer * 5) % 2 == 0 then
                color = WHITE
            end
        end
        display.fill_circle(cx, cy - 1, r, color)
        display.fill_rect(cx - r, cy - 1, r * 2 + 1, r + 1, color)
        -- Wavy skirt
        display.fill_rect(cx - r, cy + r - 1, 2, 1, BLACK)
        display.fill_rect(cx, cy + r - 1, 1, 1, BLACK)
        display.fill_rect(cx + r - 1, cy + r - 1, 2, 1, BLACK)
    end

    -- Eyes (frightened ghosts get a scared face instead)
    if g.fright then
        display.fill_rect(cx - 2, cy - 2, 1, 2, WHITE)
        display.fill_rect(cx + 1, cy - 2, 1, 2, WHITE)
    else
        display.fill_rect(cx - 3, cy - 3, 3, 3, WHITE)
        display.fill_rect(cx + 1, cy - 3, 3, 3, WHITE)
        display.fill_rect(cx - 2 + fx, cy - 2 + fy, 1, 1, FRIGHT_BLUE)
        display.fill_rect(cx + 2 + fx, cy - 2 + fy, 1, 1, FRIGHT_BLUE)
    end
end

local function draw_maze()
    local line = WALL_LINE
    if phase == "win" and floor(phase_timer * 6) % 2 == 0 then
        line = WHITE
    end
    for _, r in ipairs(wall_runs) do
        display.fill_rect(ox + r.x * T, oy + r.y * T, r.len * T, T, WALL_FILL)
        display.draw_rect(ox + r.x * T, oy + r.y * T, r.len * T, T, line)
    end

    -- Ghost house door
    display.fill_rect(ox + EXIT_X * T, oy + (EXIT_Y + 1) * T + floor(T / 2) - 1, T, 2, DOOR)

    -- Pellets
    local half = floor(T / 2)
    local blink = floor(anim * 4) % 2 == 0
    for y = 0, H - 1 do
        local row = pellets[y]
        for x = 0, W - 1 do
            local p = row[x]
            if p == 1 then
                display.fill_rect(ox + x * T + half - 1, oy + y * T + half - 1, 2, 2, PELLET)
            elseif p == 2 and blink then
                display.fill_circle(ox + x * T + half, oy + y * T + half, math.max(2, half - 1), PELLET)
            end
        end
    end
end

local function draw_hud()
    display.set_font("6x13")
    display.set_text_size(1)
    display.set_text_color(WHITE)
    display.set_cursor(4, 16)
    display.print("SCORE " .. score)

    local mid = "HI " .. high_score .. "  LV " .. level
    display.set_cursor(floor((display.width - #mid * 6) / 2) + 10, 16)
    display.print(mid)

    -- Remaining lives as little yellow dots
    for i = 1, math.max(0, lives) do
        display.fill_circle(display.width - 8 - (i - 1) * 14, 11, 5, YELLOW)
    end
end

function lilka.draw()
    display.fill_screen(BLACK)

    draw_hud()
    draw_maze()

    if phase == "dying" then
        local t = math.max(0, phase_timer / 1.6)
        draw_player(floor(math.max(2, floor(T / 2)) * t + 0.5))
    elseif phase == "play" or phase == "ready" or phase == "win" then
        draw_player(math.max(2, floor(T / 2)))
    end

    if phase ~= "dying" and phase ~= "win" then
        for i, g in ipairs(ghosts) do
            draw_ghost(g, i)
        end
    end

    if phase == "ready" then
        display.set_font("10x20")
        display.set_text_color(YELLOW)
        display.fill_rect(floor((display.width - 80) / 2), oy + 13 * T - 2, 80, 22, BLACK)
        draw_text_centered("READY!", oy + 13 * T + 14, 10)
    end

    if paused then
        draw_banner({ { "PAUSED", YELLOW }, { "START: resume", WHITE } })
    elseif phase == "over" then
        draw_banner({
            { "GAME OVER", RED },
            { "Score " .. score, WHITE },
            { "A: again  B: exit", GRAY },
        })
    end
end
