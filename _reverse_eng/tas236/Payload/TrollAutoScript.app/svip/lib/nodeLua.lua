local _M = {}
local _H = {}
local isKeep = false
local keepNode
local GET_SUPERVIEW
local BY_CLASS_NAME
local BY_TEXT
local BY_LABLE
local BY_PATH
local GET_SUBVIEWS
local BY_NODE
local BY_MATCH

_H.GetPoint = function (self)
    return self.frame.x , self.frame.y
end

_H.GetClassName = function (self)
    return self.class
end

_H.GetSuperClassName = function (self)
    return self.superClass
end

_H.GetSize = function (self)
    return self.frame.width, self.frame.height
end

_H.GetText = function (self)
    return self.text
end

_H.GetLable = function (self)
    return self.lable
end

_H.GetFrame = function (self)
    return self.frame
end

_H.GetAlpha = function (self)
    return self.alpha
end

_H.GetAddres = function (self)
    return self.addres
end

_H.GetHidden = function (self)
    return self.isHidden
end

_H.GetCenterPoint = function (self)
    return math.floor(self.frame.width / 2 + self.frame.x) , math.floor(self.frame.height / 2 + self.frame.y)
end

_H.OnTap = function (self)
    local x, y = math.floor(self.frame.width / 2 + self.frame.x) , math.floor(self.frame.height / 2 + self.frame.y);
    touch.tap(x, y);
end

_H.SetText = function (self ,text)
    return appNode.setText(self.class, self.addres, text)
end

local function TableCopy(tab)               --copy table
    local result = {}
    for k,v in pairs(tab) do
        if (k ~= "subviews") then
            result[k] = v
        end
    end
    return result
end



GET_SUPERVIEW =  function (nodeInfo , className , addres )
    for k,v in pairs(nodeInfo) do
        if (type(v.subviews) == "table" ) then
            for key, value in pairs(v.subviews) do
                if (value.class == className) and (value.addres == addres) then
                    return TableCopy(v)
                end
            end
            local result = GET_SUPERVIEW(v.subviews, className, addres)
            if (result) then return result end
        end

    end
end



_H.GetSuperNode = function (self)
    local result
    if (isKeep) then
        result = GET_SUPERVIEW(keepNode, self.class, self.addres)
    else
        result = appNode.getSuperView(self.class, self.addres)
    end
    if (type(result) == "table" ) then
        setmetatable(result, _H)
        return result
    end
end

local function ReturnResult(tab)            --return result
    if (type(tab) ~= "table") then
        return
    end
    for k,v in pairs(tab) do
        if (type(v) == "table") then
            setmetatable(v, _H)
        end
    end
    return #tab > 0 and tab or nil
end




GET_SUBVIEWS = function (nodeInfo , className , addres , result)
    for k,v in pairs(nodeInfo) do
        if (v.class == className) and (v.addres == addres) then
            -- table.insert(result ,TableCopy(v))
            if (type(v.subviews) =="table") then
                for key, value in pairs(v.subviews) do
                    table.insert(result ,TableCopy(value))
                end
            end
            return
        end
        if (type(v.subviews) =="table") then
            GET_SUBVIEWS(v.subviews, className, addres, result)
        end
    end
end

_H.GetSubNode = function (self , subClassName)
    if (isKeep) then
        local result = {}
        GET_SUBVIEWS(keepNode, self.class, self.addres, result)
        return ReturnResult(result)

    else
        local tab = appNode.getSubView(self.class, self.addres, subClassName)
        return ReturnResult(tab)
    end
end


_H.__index = _H






BY_CLASS_NAME =  function (nodeInfo ,className, superClass , result)   --is keep model find Class Name
    for k,v in pairs(nodeInfo) do
        local varClassName = superClass and superClass or v.superClass
        if (v.class == className) and (v.superClass == varClassName) then
            table.insert(result ,TableCopy(v))
        end
        if (type(v.subviews) == "table") then
            BY_CLASS_NAME(v.subviews, className ,superClass, result)
        end
    end
end

_M.byClassName = function (className , superClassName)
    if (isKeep) then
        local result = {}
        BY_CLASS_NAME(keepNode, className, superClassName, result)
        return ReturnResult(result)
    else
        local tab = appNode.byClassName(className, superClassName)
        return ReturnResult(tab)
    end
end

BY_TEXT = function (nodeInfo, className ,text , result)
    for k,v in pairs(nodeInfo) do
        local varClassName = className and className or v.class
        if (v.class == varClassName) and (v.text == text) then
            table.insert(result ,TableCopy(v))
        end
        if (type(v.subviews) == "table") then
            BY_TEXT(v.subviews, className ,text, result)
        end
    end
end

_M.byText = function (text, className)
    if (isKeep) then
        local result = {}
        BY_TEXT(keepNode, className, text, result)
        return ReturnResult(result)
    else
        local tab = appNode.byText(text, className)
        return ReturnResult(tab)
    end
end

BY_LABLE = function (nodeInfo, className ,lable , result)
    
    for k,v in pairs(nodeInfo) do
        local varClassName = className and className or v.class
        if (v.class == varClassName) and (v.lable == lable) then
            table.insert(result ,TableCopy(v))
        end
        if (type(v.subviews) == "table") then
            BY_LABLE(v.subviews, className ,lable, result)
        end
    end
end

_M.byLable = function (lable, className)
    if (isKeep) then
        local result = {}
        BY_LABLE(keepNode, className, lable, result)
        return ReturnResult(result)
    else
        local tab = appNode.byLable(lable, className)
        return ReturnResult(tab)
    end
end

local byPathArgs = function (path)
    local nodePath = type(path) == "string" and path:split("/") or nil
    if type(nodePath) == "table" and #nodePath > 0 then
        if nodePath[1] == "" then
            table.remove(nodePath, 1)
        end
        if #nodePath > 0 and nodePath[#nodePath] == "" then
            table.remove(nodePath, #nodePath)
        end
        return #nodePath > 0 and nodePath or nil
    end
end


BY_PATH = function (nodeInfo, path , index , result)
    local className = path[index]
    for key, value in pairs(nodeInfo) do
        if (className == value.class) then
            if (#path == index) then
                table.insert(result ,TableCopy(value))
            else
                if type(value.subviews) == "table" then
                    BY_PATH(value.subviews, path, index + 1 , result)
                end
                
            end
        end
    end
end

_M.byPath = function (nodePath)
    if (isKeep) then
        local result = {}
        local pathTab = byPathArgs(nodePath)
        if pathTab then
            BY_PATH(keepNode, pathTab, 1, result)
        end
        return ReturnResult(result)
    else
        local tab = appNode.byPath(nodePath)
        return ReturnResult(tab)
    end
end

_M.info = function ()
    if (isKeep) then
        return keepNode
    else
        local info = appNode.info()
        local tab = json.decode(type(info) == "string" and info or "{}")
        if (type(tab) == "table") then
            return #tab > 0 and tab or nil
        end
        return 0
    end
end

local checkNode = function (currNode, nodeTab )
    for k,v in pairs(nodeTab) do
        if (currNode[k] ~= v) then
            return false
        end
    end
    return true
end

BY_NODE = function (nodeInfo, nodeTab , result)
    for k,v in pairs(nodeInfo) do
        if (checkNode(v, nodeTab)) then
            table.insert(result ,TableCopy(v))
        end
        if (type(v.subviews) == "table") then
            BY_NODE(v.subviews, nodeTab , result)
        end
    end
end

local copyTableArgs = function (tab)
    local result = {}
    for k,v in pairs(tab) do
        if (k ~= "path" and type(v) ~= "function") then
            result[k] = v
        end
    end
    return result
end

_M.byNode = function (nodeTab)
    local tab = keepNode or appNode.info()
    if (type(tab) == "table") then
        local result = {}
        BY_NODE(tab, copyTableArgs(nodeTab) , result)
        return ReturnResult(result)
    end
end

BY_MATCH = function (nodeInfo , matchCall , result)
    for k, v in ipairs(nodeInfo) do
        if (matchCall(v)) then
            table.insert(result ,TableCopy(v))
        end
        if type(v.subviews) == "table" then
            BY_MATCH(v.subviews, matchCall, result)
        end
    end
end


_M.byMatch = function (matchCall)
    local tab = keepNode or appNode.info()
    if (type(tab) == "table") then
        local result = {}
        BY_MATCH(tab, matchCall , result)
        return ReturnResult(result)
    end
end

_M.keep = function ()
    local info = appNode.info()
    local tab = json.decode(type(info) == "string" and info or "{}")
    if (type(tab) == "table") then
        isKeep = true;
        keepNode = tab
    end
end

_M.unKeep = function ()
    isKeep = false
    keepNode = nil
end



return _M


