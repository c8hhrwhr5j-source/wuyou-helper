local _M = {}


function _M.create(func)
    local co =  coroutine.create(func)
    return co , coroutine.resume(co)
end

function _M.Cancel(co)
    co = nil
end

function _M.state(co)
    return coroutine.status(co)
end


return _M
