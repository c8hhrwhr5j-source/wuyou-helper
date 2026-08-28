---TrollAutoScript 脚本主入口
local ev = require("ev")
json =require("cjson")
thread = require("thread")
dofile("/var/mobile/Media/svip/lib/logFunction.lua")

local msleep = function (t) --延迟函数
    local _ , isMainThread = coroutine.running()
    if isMainThread then
        return;
    end
    local function  timeOut( loop , event)
        coroutine.resume(_)
    end
    
    

    local tmr =  ev.Timer.new(timeOut , t /1000)
    tmr:start(ev.Loop.default)
    local  err, info = pcall(function ()
        coroutine.yield()
    end)
    if not err then
        tmr:stop(ev.Loop.default)
        sys.runLoop(t)
    end
    
end


--- @param callback function
--- @param time number 毫秒
--- @param reset boolean 是否重置
--- return  timer  定时器对象
thread.timer = function (callback , time , reset)
    local timer
    if (reset ) then
        timer = ev.Timer.new(callback , time /1000 , time / 1000)
    else
        timer = ev.Timer.new(callback , time /1000)
    end
    timer:start(ev.Loop.default)
    return timer
end

sys.msleep = function (t) --延迟函数
    assert(type(t) == "number", "delay time must be number")
    msleep(5)                  --为什么会多出一个延迟函数, 因为ev 定时器BUG 当经历过一个 耗时操作时 ev的定时时间戳 或取到的是 耗时操作之前的时间戳 ,所以需要多延迟10ms 用来刷新 ev的获取时间函数
    msleep(t - 10 > 0 and t - 10 or 1)
end


function Main_loop(loop , event)   --主事件循环
    event:stop(loop)

    thread.create(function ()
        local func, err = loadfile(_SCRIPT_PATH_)
        if not func then
            runTimeError(type(err) == "string" and err or "")
        else
            local _ ,err = pcall(func)
            if not _ then
                print(type(err) == "string" and err or "")
                runTimeError(type(err) == "string" and err or "")
            end
        end
        loop:unloop()
    end)
    
end



ev.Idle.new(Main_loop):start(ev.Loop.default)
ev.Loop.default:loop()

