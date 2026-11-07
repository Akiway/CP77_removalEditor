config = {}

function config.fileExists(filename)
    local f=io.open(filename,"r")
    if (f~=nil) then io.close(f) return true else return false end
end

function config.tryCreateConfig(path, data)
	if not config.fileExists(path) then
        local file = io.open(path, "w")
        local jconfig = json.encode(data)
        file:write(jconfig)
        file:close()
    end
end

--- Reads a JSON file without ever raising an error
---@param path string
---@return any? data
---@return string? err Reason the file could not be read
function config.tryLoadFile(path)
    local file = io.open(path, "r")
    if not file then return nil, "cannot be opened" end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(json.decode, content)
    if not ok then return nil, "not valid JSON (" .. tostring(data) .. ")" end
    if data == nil then return nil, "empty" end

    return data
end

function config.loadFile(path)
    local data, err = config.tryLoadFile(path)
    if err then
        error(string.format("[RemovalEditor] %s: %s", path, err))
    end
    return data
end

function config.saveFile(path, data)
    local file = io.open(path, "w")
    if not file then
        print(string.format("[RemovalEditor] Error: %s cannot be written!", path))
        return false
    end

    local jconfig = json.encode(data)
    file:write(jconfig)
    file:close()
    return true
end

function config.loadPaths(path)
    local paths = {}
    file = io.open(path)
    for line in file:lines() do

        local n = line
        if string.find(n, "\\") then
            n = n:match("\\[^\\]*$") -- Everything after last \
        end
        n = n:gsub(".ent", ""):gsub("\\", "_") -- Remove .ent, replace \ by _
        n = n:sub(2)

        table.insert(paths, {path = line, obj = nil, name = n})

    end
    file:close()
    return paths
end

function config.backwardComp(path, data)
    local f = config.loadFile(path)

    for k, e in pairs(data) do
        if f[k] == nil then
            f[k] = e
        end
    end

    config.saveFile(path, f)
end

return config