--TrollAutoScript 日志函数
if not _START_ARGS_IP or _START_ARGS_PORT == "" then
    return
end

TABLE_TO_STRING = function (t, s , r)
    local s = s or {}
    if s[t] ~= nil then return "--" .. tostring(t) end
    s[t] = true
    local r = r or ""
    local result = table.concat({"{    --" , tostring(t) ,"\n"} )
    for k, v in pairs(t) do
        local key
        if type(k) == "string" then
            key = table.concat({r .."    ",'["' , k, '"] = '})
        else
            key = table.concat({r .."    ",'[' , k, '] = '})
        end
        if type(v) == "table" then
            local utf8Charpattern = utf8.charpattern
            if k == "utf8" then
                utf8.charpattern = ""
            end
            result = table.concat({result , key, TABLE_TO_STRING(v, s, r.."    ") ,"\n"})
            utf8.charpattern = utf8Charpattern
        elseif type(v) == "string" then
            result = table.concat({result , key, '"' , v , '"' ,",\n"})
        else
            result = table.concat({result , key, tostring(v),",\n"})
        end
    end
    result = table.concat({  result ,r, "}" ,r == "" and "" or ","})
    s[t] = nil
    return result
end

local logServerIp = _START_ARGS_IP:match("([^:]+):(%d+)")
local logPort = _START_ARGS_PORT
if logServerIp then
    print = function (...)
        local args = {...}
        local text = ""
        for i= 1 , #args do
            if type(args[i]) == "table" then
                text = table.concat({text ,TABLE_TO_STRING(args[i])})
            else
                text = table.concat({text , tostring(args[i])})
            end
            text = table.concat({text , ",    "})
        end
        http.post("http://" .. logServerIp .. ":"..logPort.."/log", 1, {}, text)
    end
    return print
end



