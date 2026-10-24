-- Classic Snake for Lilka (KeiraOS Lua API)
-- Controls: D-pad = steer, START = pause, A = restart (after game over), B = exit

-- Configuration
local CELL = 10          -- Size of each cell in pixels
local HUD_HEIGHT = 20    -- Top strip reserved for the score
local START_STEP = 0.16  -- Seconds per move at the start
local MIN_STEP = 0.06    -- Fastest possible speed
local SPEED_UP = 0.97    -- Step multiplier for every food eaten
local MAX_QUEUED_TURNS = 2

-- Derived layout (computed in lilka.init, once the display size is known)
local grid_w, grid_h
local offset_x, offset_y

-- Colors
local BLACK, WHITE, RED, GREEN, DARK_GREEN, GRAY

-- Game state
local snake          -- array of {x, y}; snake[1] is the head
local direction      -- direction of the last performed move
local turn_queue     -- buffered direction changes from the D-pad
local food
local score
local high_score = 0
local step_time
local accumulator
local game_over
local won
local paused

-- Direction vectors
local UP    = { x = 0,  y = -1 }
local DOWN  = { x = 0,  y = 1 }
local LEFT  = { x = -1, y = 0 }
local RIGHT = { x = 1,  y = 0 }

-- Draws text centered horizontally at the given y (font is 10px wide per char)
local function draw_centered(text, y)
    display.set_cursor(math.floor((display.width - #text * 10) / 2), y)
    display.print(text)
end

-- Places food on a random free cell. Returns false when the board is full.
local function spawn_food()
    local occupied = {}
    for _, s in ipairs(snake) do
        occupied[s.y * grid_w + s.x] = true
    end

    local free = {}
    for y = 0, grid_h - 1 do
        for x = 0, grid_w - 1 do
            if not occupied[y * grid_w + x] then
                free[#free + 1] = { x = x, y = y }
            end
        end
    end

    if #free == 0 then
        food = nil
        return false
    end

    -- KeiraOS math.random(min, max) excludes max; clamp in case it is inclusive
    food = free[math.min(#free, math.random(1, #free + 1))]
    return true
end

local function reset_game()
    local sx = math.floor(grid_w / 2)
    local sy = math.floor(grid_h / 2)

    snake = {
        { x = sx,     y = sy },
        { x = sx - 1, y = sy },
        { x = sx - 2, y = sy },
    }
    direction = RIGHT
    turn_queue = {}
    score = 0
    step_time = START_STEP
    accumulator = 0
    game_over = false
    won = false
    paused = false

    spawn_food()
end

-- Queues a turn, ignoring reversals and repeats relative to the last queued direction
local function queue_turn(dir)
    if #turn_queue >= MAX_QUEUED_TURNS then
        return
    end
    local last = turn_queue[#turn_queue] or direction
    if (dir.x == -last.x and dir.y == -last.y) or (dir.x == last.x and dir.y == last.y) then
        return
    end
    turn_queue[#turn_queue + 1] = dir
end

local function finish_game()
    game_over = true
    if score > high_score then
        high_score = score
    end
end

-- Advances the snake by one cell
local function step()
    if #turn_queue > 0 then
        direction = table.remove(turn_queue, 1)
    end

    local head = snake[1]
    local nx = head.x + direction.x
    local ny = head.y + direction.y

    -- Wall collision
    if nx < 0 or nx >= grid_w or ny < 0 or ny >= grid_h then
        finish_game()
        return
    end

    local eating = food ~= nil and nx == food.x and ny == food.y

    -- Self collision. The tail cell is about to be vacated, so it is safe
    -- to step onto it unless we are growing this turn.
    local last = #snake
    if not eating then
        last = last - 1
    end
    for i = 1, last do
        if snake[i].x == nx and snake[i].y == ny then
            finish_game()
            return
        end
    end

    table.insert(snake, 1, { x = nx, y = ny })

    if eating then
        score = score + 1
        step_time = math.max(MIN_STEP, step_time * SPEED_UP)
        if not spawn_food() then
            won = true
            finish_game()
        end
    else
        table.remove(snake)
    end
end

function lilka.init()
    BLACK = display.color565(0, 0, 0)
    WHITE = display.color565(255, 255, 255)
    RED = display.color565(255, 0, 0)
    GREEN = display.color565(0, 255, 0)
    DARK_GREEN = display.color565(0, 160, 0)
    GRAY = display.color565(80, 80, 80)

    grid_w = math.floor(display.width / CELL)
    grid_h = math.floor((display.height - HUD_HEIGHT) / CELL)
    offset_x = math.floor((display.width - grid_w * CELL) / 2)
    offset_y = HUD_HEIGHT + math.floor((display.height - HUD_HEIGHT - grid_h * CELL) / 2)

    reset_game()
end

function lilka.update(delta)
    local state = controller.get_state()

    if state.b.just_pressed then
        util.exit()
        return
    end

    if game_over then
        if state.a.just_pressed then
            reset_game()
        end
        return
    end

    if state.start.just_pressed then
        paused = not paused
    end
    if paused then
        return
    end

    if state.up.just_pressed then
        queue_turn(UP)
    elseif state.down.just_pressed then
        queue_turn(DOWN)
    elseif state.left.just_pressed then
        queue_turn(LEFT)
    elseif state.right.just_pressed then
        queue_turn(RIGHT)
    end

    -- Fixed time step so speed doesn't depend on the frame rate
    accumulator = accumulator + delta
    while accumulator >= step_time and not game_over do
        accumulator = accumulator - step_time
        step()
    end
end

local function draw_cell(cx, cy, color)
    display.fill_rect(offset_x + cx * CELL, offset_y + cy * CELL, CELL - 1, CELL - 1, color)
end

function lilka.draw()
    display.fill_screen(BLACK)

    -- Playfield border
    display.draw_rect(offset_x - 1, offset_y - 1, grid_w * CELL + 2, grid_h * CELL + 2, GRAY)

    -- Food
    if food then
        draw_cell(food.x, food.y, RED)
    end

    -- Snake
    for i, segment in ipairs(snake) do
        draw_cell(segment.x, segment.y, i == 1 and GREEN or DARK_GREEN)
    end

    -- HUD
    display.set_font("10x20")
    display.set_text_size(1)
    display.set_text_color(WHITE)
    display.set_cursor(4, 16)
    display.print("Score: " .. score)
    local best = "Best: " .. high_score
    display.set_cursor(display.width - #best * 10 - 4, 16)
    display.print(best)

    if paused then
        draw_centered("PAUSED", math.floor(display.height / 2))
    end

    if game_over then
        local mid = math.floor(display.height / 2)
        draw_centered(won and "YOU WIN!" or "GAME OVER", mid - 10)
        draw_centered("A: restart  B: exit", mid + 20)
    end
end
