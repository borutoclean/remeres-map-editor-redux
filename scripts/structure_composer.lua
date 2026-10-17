-- @Title: Multi-Sprite Structure Composer
-- @Description: Arrange multiple server item IDs into reusable, previewable structures
-- @Version: 0.2.0
-- Works offline. Numeric item order alone does not prove correct sprite geometry.

local MAX_IDS = 220
local MAX_ITEMS_PER_TILE = 8
local templateStorage = app.storage("structure_composer_library")
local library = templateStorage:load() or {}
local settingsStorage = app.storage("structure_composer_settings")
local settings = settingsStorage:load() or {}

local function notice(message)
    print("[Structure Composer] " .. message)
    app.alert({ title = "Structure Composer", text = message, buttons = { "OK" } })
end

local function isInteger(x)
    return type(x) == "number" and x == math.floor(x)
end

local function safeName(name)
    if type(name) ~= "string" or #name < 1 or #name > 60 or
        not name:match("^[%w_%-. ]+$") then
        error("Nome de template invalido (use letras, numeros, espacos, -, _ ou .).")
    end
    return name
end

local function parseIDs(input)
    local ids, found = {}, {}
    local max = math.min(65535, Items.getMaxId())
    local function add(id)
        if not isInteger(id) or id < 1 or id > max or not Items.exists(id) then
            error("ID nao existe no seu servidor/cliente: " .. tostring(id))
        end
        if found[id] then error("ID duplicado na lista: " .. id) end
        if #ids >= MAX_IDS then error("Maximo de " .. MAX_IDS .. " IDs.") end
        found[id] = true
        ids[#ids + 1] = id
    end
    for token in (input or ""):gmatch("[^,%s;]+") do
        local a, b = token:match("^(%d+)%-(%d+)$")
        if a then
            a, b = tonumber(a), tonumber(b)
            if b < a or b - a >= MAX_IDS then
                error("Intervalo maior que " .. MAX_IDS .. " ou invertido.")
            end
            for id = a, b do add(id) end
        else
            add(tonumber(token))
        end
    end
    return ids
end

local function manualEntries(input)
    local entries = {}
    for token in (input or ""):gmatch("[^;%s]+") do
        local id, x, y = token:match("^(%d+):(%d+):(%d+)$")
        if not id then
            error("Formato manual incorreto. Exemplo: 46967:0:0;46968:1:0")
        end
        entries[#entries + 1] = { id = tonumber(id), x = tonumber(x), y = tonumber(y) }
        if #entries > MAX_IDS then error("Lista manual muito longa.") end
    end
    return entries
end

local function arrange(ids, width, height, mode)
    local entries = {}
    if #ids > width * height then
        error("A area e menor que a lista de IDs: " .. #ids .. " > " .. (width * height))
    end
    if mode == "Edge heuristic" then
        if #ids ~= width * height then
            error("Heuristica requer grade completa (uma peca por SQM).")
        end
        local result = Image.autoArrange(ids, width, height)
        print(string.format("[Structure Composer] Auto-arrangement: %d seams compared; avg cost %.3f; %d images unavailable/non-32px",
            result.matchedEdges, result.averageCost, result.unsupportedSprites))
        return result.entries
    end

    for i, id in ipairs(ids) do
        local x, y
        if mode == "Column major" then
            x = math.floor((i - 1) / height)
            y = (i - 1) % height
        else
            y = math.floor((i - 1) / width)
            x = (i - 1) % width
            if mode == "Snake rows" and y % 2 == 1 then
                x = width - 1 - x
            end
        end
        entries[#entries + 1] = { id = id, x = x, y = y }
    end
    return entries
end

local function transform(entries, w, h, transformMode)
    if transformMode == "None" then return entries, w, h end
    local result = {}
    local newWidth, newHeight = w, h
    if transformMode == "Rotate positions 90" or transformMode == "Rotate positions 270" then
        newWidth, newHeight = h, w
    end
    for _, e in ipairs(entries) do
        local x, y = e.x, e.y
        if transformMode == "Rotate positions 90" then x, y = h - 1 - y, x
        elseif transformMode == "Rotate positions 180" then x, y = w - 1 - x, h - 1 - y
        elseif transformMode == "Rotate positions 270" then x, y = y, w - 1 - x
        elseif transformMode == "Flip positions X" then x = w - 1 - x
        elseif transformMode == "Flip positions Y" then y = h - 1 - y
        end
        result[#result + 1] = { id = e.id, x = x, y = y }
    end
    return result, newWidth, newHeight
end

local function validate(entries, width, height)
    if not isInteger(width) or not isInteger(height) or width < 1 or height < 1
        or width > 40 or height > 40 then error("Dimensoes devem estar entre 1 e 40.") end
    if #entries < 1 or #entries > MAX_IDS then error("Quantidade invalida de pecas.") end
    local group = {}
    local count = {}
    for i, e in ipairs(entries) do
        if type(e) ~= "table" or not isInteger(e.id) or e.id < 1
            or e.id > math.min(65535, Items.getMaxId()) or not Items.exists(e.id) then
            error("Item desconhecido na posicao " .. i)
        end
        if not isInteger(e.x) or not isInteger(e.y) or
            e.x < 0 or e.x >= width or e.y < 0 or e.y >= height then
            error("Coordenadas relativas invalidas na posicao " .. i)
        end
        local k = e.x .. ":" .. e.y
        local g = group[k]
        if not g then g = { x = e.x, y = e.y, ids = {}, hasGround = false }; group[k] = g end
        local info = Items.getInfo(e.id)
        if info.isGroundTile then
            if g.hasGround then error("Dois pisos no mesmo SQM: " .. k) end
            g.hasGround = true
            table.insert(g.ids, 1, e.id)
        else
            g.ids[#g.ids + 1] = e.id
        end
        if #g.ids > MAX_ITEMS_PER_TILE then error("Mais de 8 itens no SQM " .. k) end
    end
    local tiles = {}
    for _, g in pairs(group) do tiles[#tiles + 1] = g end
    table.sort(tiles, function(a,b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    return tiles
end

local function listSaved()
    local names = {}
    for name, t in pairs(library) do
        if type(t) == "table" and type(t.entries) == "table" then names[#names + 1] = name end
    end
    table.sort(names)
    if #names == 0 then return "(nenhum ainda)" end
    return table.concat(names, ", ")
end

local dlg = Dialog({ title = "Multi-Sprite Structure Composer", width = 650 })
dlg:label({ text = "Crie estruturas com IDs de item do servidor. Trabalho offline." })
dlg:label({ text = "Modos: Row major | Column major | Snake rows | Edge heuristic | Manual | Saved" })
dlg:label({ text = "Templates existentes: " .. listSaved():sub(1, 160) })
dlg:separator()
dlg:combobox({
    id = "mode", label = "Montagem:",
    options = { "Row major", "Column major", "Snake rows", "Edge heuristic", "Manual", "Saved" },
    option = "Row major",
})
dlg:input({
    id = "ids", label = "IDs (ex.: 46967-47146):",
    text = settings.ids or "46967-47146",
})
dlg:input({
    id = "manual", label = "Manual: ID:x:y;ID:x:y",
    text = settings.manual or "",
})
dlg:input({
    id = "name", label = "Nome do template (ou salvo):",
    text = settings.name or "minha_estrutura",
})
dlg:newrow()
dlg:number({ id = "width", label = "Largura SQM:", value = 15, min = 1, max = 40 })
dlg:number({ id = "height", label = "Altura SQM:", value = 12, min = 1, max = 40 })
dlg:combobox({
    id = "transform", label = "Posicoes:",
    options = { "None", "Rotate positions 90", "Rotate positions 180", "Rotate positions 270",
        "Flip positions X", "Flip positions Y" },
    option = "None",
})
dlg:newrow()
dlg:number({ id = "x", label = "Mapa X:", value = 1000, min = 0, max = 65535 })
dlg:number({ id = "y", label = "Mapa Y:", value = 1000, min = 0, max = 65535 })
dlg:number({ id = "z", label = "Mapa Z:", value = 7, min = 0, max = 15 })
dlg:check({ id = "preserve", text = "Bloquear montagem se houver colisao (recomendado)", selected = true })
dlg:label({ text = "Rotacao transforma POSICOES, nao gira o desenho dos itens." })
dlg:label({ text = "Heuristica avalia ate 220 pecas, mas so compara bordas 32x32." })
dlg:separator()
local submitted = false
dlg:button({ id = "next", text = "Visualizar", focus = true,
    onclick = function(d) submitted = true; d:close() end })
dlg:button({ id = "exit", text = "Cancelar", onclick = function(d) d:close() end })
dlg:show()
if not submitted then return end
local data = dlg.data or {}
settings.ids, settings.manual, settings.name = data.ids, data.manual, data.name
settingsStorage:save(settings)

local ok, entries, width, height = pcall(function()
    local w, h = tonumber(data.width), tonumber(data.height)
    local mode = data.mode or "Row major"
    local plan
    if mode == "Saved" then
        local name = safeName(data.name)
        local saved = library[name]
        if type(saved) ~= "table" or type(saved.entries) ~= "table" then
            error("Template nao encontrado: " .. name)
        end
        w, h = saved.width, saved.height
        plan = saved.entries
    elseif mode == "Manual" then
        plan = manualEntries(data.manual)
    else
        local ids = parseIDs(data.ids)
        plan = arrange(ids, w, h, mode)
    end
    validate(plan, w, h)
    local transformed, nw, nh = transform(plan, w, h, data.transform or "None")
    validate(transformed, nw, nh)
    return transformed, nw, nh
end)
if not ok then notice("Erro no layout: " .. tostring(entries)); return end

local tiles = validate(entries, width, height)
local preview = Image.composeItems(width, height, entries)
if not preview or not preview.valid then
    notice("O editor nao conseguiu gerar a imagem da estrutura.")
    return
end
local columns = {}
for y = 0, height - 1 do
    local row = {}
    for x = 0, width - 1 do row[#row + 1] = "." end
    columns[y + 1] = row
end
for i, e in ipairs(entries) do
    columns[e.y + 1][e.x + 1] = "#"
end
local footprint = {}
for i = 1, math.min(height, 20) do footprint[#footprint + 1] = table.concat(columns[i]) end
if height > 20 then footprint[#footprint + 1] = "... (linhas omitidas)" end

local confirm = Dialog({ title = "Preview da estrutura", width = 680 })
confirm:label({ text = string.format("%d pecas, %d SQMs, %dx%d. Preview aproximado com sprites reais.",
    #entries, #tiles, width, height) })
confirm:image({
    id = "preview",
    image = preview,
    width = math.max(1, math.floor(width * 32 * math.min(1, 620 / (width * 32), 440 / (height * 32)))),
    height = math.max(1, math.floor(height * 32 * math.min(1, 620 / (width * 32), 440 / (height * 32)))),
    smooth = false,
})
confirm:label({ text = "Mapa de ocupacao (# = contem item):" })
confirm:label({ text = table.concat(footprint, "\n") })
confirm:label({ text = "Revise o encaixe antes de aplicar. Girar posicoes NAO gira sprites." })
confirm:separator()
local decision = "cancel"
confirm:button({ id = "save", text = "Salvar template", onclick = function(d)
    decision = "save"; d:close()
end })
confirm:button({ id = "apply", text = "Aplicar no mapa", focus = true, onclick = function(d)
    decision = "apply"; d:close()
end })
confirm:button({ id = "cancel", text = "Cancelar", onclick = function(d) d:close() end })
confirm:show()
if decision == "cancel" then return end

local function saveTemplate()
    local name = safeName(data.name)
    -- Persist plain JSON data, never Lua code or image bytes.
    library[name] = { version = 1, width = width, height = height, entries = entries }
    assert(templateStorage:save(library), "Nao foi possivel salvar o template.")
    print("[Structure Composer] Template salvo: " .. name)
end

if decision == "save" then
    local success, err = pcall(saveTemplate)
    if not success then notice(tostring(err)) else notice("Template salvo. Ele pode ser reutilizado no modo Saved.") end
    return
end

if not app.hasMap() then notice("Abra um mapa para aplicar a estrutura."); return end
local x0, y0, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
if not isInteger(x0) or not isInteger(y0) or not isInteger(z) or
    z < 0 or z > 15 or x0 < 0 or y0 < 0 or
    x0 + width > math.min(65536, app.map.width) or
    y0 + height > math.min(65536, app.map.height) then
    notice("A posicao excede os limites do mapa.")
    return
end
local blocked = {}
for _, tileInfo in ipairs(tiles) do
    local x, y = x0 + tileInfo.x, y0 + tileInfo.y
    local current = app.map:getTile(x, y, z)
    local containsGround = tileInfo.hasGround
    if data.preserve and current and
        (current.itemCount > 0 or (containsGround and current.hasGround)) then
        blocked[#blocked + 1] = "(" .. x .. "," .. y .. ")"
    elseif not tileInfo.hasGround and not (current and current.hasGround) then
        blocked[#blocked + 1] = "(" .. x .. "," .. y .. ") sem piso"
    end
end
if #blocked > 0 then
    notice("Montagem cancelada. Corrija " .. #blocked .. " SQMs, incluindo: "
        .. table.concat({ blocked[1], blocked[2], blocked[3] }, ", "))
    return
end

local approved = app.alert({
    title = "Confirmar escrita no mapa",
    text = string.format("Aplicar %d itens em %d SQMs, a partir de (%d,%d,%d)?\n"
        .. "Esta acao nao remove objetos existentes; Ctrl+Z desfaz.", #entries, #tiles, x0, y0, z),
    buttons = { "Yes", "No" },
})
if approved ~= 1 then return end

local succeeded, err = pcall(function()
    app.transaction("Place Structure: " .. tostring(data.name), function()
        for _, p in ipairs(tiles) do
            local tile = app.map:getOrCreateTile(x0 + p.x, y0 + p.y, z)
            assert(tile, "Erro criando SQM")
            for _, id in ipairs(p.ids) do tile:addItem(id) end
        end
    end)
end)
if not succeeded then notice("A aplicacao falhou e foi revertida: " .. tostring(err)); return end
app.refresh()
app.setCameraPosition(x0 + math.floor(width / 2), y0 + math.floor(height / 2), z)
notice("Estrutura posicionada. Revise o resultado e use Ctrl+Z se necessario.")
