-- Configuration
GRID_SIZE = 8       -- Size of each block in pixels
GRID_WIDTH = 26     -- Game area width in grid units
GRID_HEIGHT = 18    -- Game area height in grid units

-- Define colors
local BLACK = display.color565(0, 0, 0)
local WHITE = display.color565(255, 255, 255)
local RED = display.color565(255, 0, 0)
local GREEN = display.color565(0, 255, 0)

-- Game state variables
local snake
local food
local direction
local score
local game_over
local timer
local game_speed

-- Helper function to reset and start the game
function reset_game()
    snake = {
        { x = 5, y = 5 },
        { x = 4, y = 5 },
        { x = 3, y = 5 }
    }
    
    direction = { x = 1, y = 0 }
    
    score = 0
    game_over = false
    timer = 0
    game_speed = 0.15
    
    spawn_food()
end

-- Helper function to spawn food in a random location
function spawn_food()
    while true do
        food = {
            x = math.random(0, GRID_WIDTH - 1),
            y = math.random(0, GRID_HEIGHT - 1)
        }
        
        local on_snake = false
        for _, segment in ipairs(snake) do
            if food.x == segment.x and food.y == segment.y then
                on_snake = true
                break
            end
        end
        
        if not on_snake then
            break
        end
    end
end

-- lilka.init() is called once at the start
function lilka.init()
    -- KeiraOS seeds math.random automatically
    reset_game()
end

-- lilka.update(delta) is called every frame for game logic
function lilka.update(delta)
    
    -- ### 1. Handle Input ###
    
    local state = controller.get_state() 

    -- Added a way to exit the game
    if state.b.justPressed then
        util.exit()
    end

    if game_over then
        if state.a.justPressed then
            reset_game()
        end
    else
        if state.up.justPressed and direction.y == 0 then
            direction = { x = 0, y = -1 }
        elseif state.down.justPressed and direction.y == 0 then
            direction = { x = 0, y = 1 }
        elseif state.left.justPressed and direction.x == 0 then
            direction = { x = -1, y = 0 }
        elseif state.right.justPressed and direction.x == 0 then
            direction = { x = 1, y = 0 }
        end
    end
    
    -- ### 2. Update Game Logic ###
    
    timer = timer + delta
    
    -- Only run the main game logic if the timer has exceeded our game speed
    if timer > game_speed and not game_over then
        timer = 0 
        
        local head = snake[1]
        
        local new_head = {
            x = head.x + direction.x,
            y = head.y + direction.y
        }
        
        -- Check for Wall collision
        if new_head.x < 0 or new_head.x >= GRID_WIDTH or
           new_head.y < 0 or new_head.y >= GRID_HEIGHT then
            game_over = true
        end
        
        -- Check for Self-collision
        for _, segment in ipairs(snake) do
            if new_head.x == segment.x and new_head.y == segment.y then
                game_over = true
                break
            end
        end
        
        if not game_over then
            -- Add the new head to the front of the snake
            table.insert(snake, 1, new_head)
            
            -- Check for food
            if new_head.x == food.x and new_head.y == food.y then
                score = score + 1
                spawn_food()
                game_speed = game_speed * 0.98 -- Increase speed
            else
                -- Remove the tail segment to simulate movement
                table.remove(snake)
            end
        end
    end
end

-- lilka.draw() is called after update, for all rendering
function lilka.draw()
    
    -- Clear the screen
    display.fill_screen(BLACK)
    
    -- Draw the food
    display.fill_rect(food.x * GRID_SIZE, food.y * GRID_SIZE, GRID_SIZE, GRID_SIZE, RED)
    
    -- Draw the snake
    for i, segment in ipairs(snake) do
        local color = WHITE
        if i == 1 then
            color = GREEN -- Make the head green
        end
        display.fill_rect(segment.x * GRID_SIZE, segment.y * GRID_SIZE, GRID_SIZE, GRID_SIZE, color)
    end
    
    -- Draw the score
    display.set_cursor(2, 2)
    display.print("Score: " .. score)
    
    -- Draw Game Over message
    if game_over then
        display.set_cursor( (GRID_WIDTH * GRID_SIZE / 2) - 40, (GRID_HEIGHT * GRID_SIZE / 2) - 10)
        display.print("GAME OVER")
        display.set_cursor( (GRID_WIDTH * GRID_SIZE / 2) - 50, (GRID_HEIGHT * GRID_SIZE / 2) + 10)
        display.print("Press A to Restart")
    end
    
    -- No display.queue_draw() needed; the OS handles it
end