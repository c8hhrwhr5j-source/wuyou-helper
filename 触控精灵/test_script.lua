--[[
  TickSprite - Loop color find & click test script
  iOS 15.0~16.6.1 + TrollStore
--]]

log("========== Test Script Start ==========")
log("Runtime: iOS " .. _VERSION)

local cx, cy = get_screen_size()
log("Screen: " .. cx .. "x" .. cy)

-- Read center pixel color
local sr, sg, sb = get_screen_color(cx / 2, cy / 2)
log("Center pixel RGB: (" .. sr .. "," .. sg .. "," .. sb .. ")")

local count = 0

while true do
    count = count + 1

    -- Find near-white pixel in region (100,200)-(500,800)
    -- similarity 90 = 90% match tolerance
    local tx, ty = find_color(100, 200, 500, 800, 255, 255, 255, 90)

    if tx > 0 and ty > 0 then
        log("[" .. count .. "] Found! (" .. tx .. "," .. ty .. ")")
        click(tx, ty)
        sleep(800)
    else
        if count % 10 == 0 then
            log("[" .. count .. "] Scanning...")
        end
    end

    sleep(300)

    if count >= 1000 then
        log("Reached 1000 loops, auto-stop")
        stop_script()
    end
end
