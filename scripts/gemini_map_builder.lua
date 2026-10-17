-- @Title: Gemini AI Map Builder
-- @Description: Generate a validated tile layout with Gemini and apply it with undo support
-- @Version: 0.1.0
-- This uses the Google Gemini API, not an undocumented Antigravity endpoint.
-- No AI-generated Lua is executed.

local MAX_IDS = 220
local MAX_TILES = 200
local MAX_ITEMS_PER_TILE = 8
local MAX_RESPONSE_CHARS = 100000
local settings = app.storage("gemini_map_builder")
local config = settings:load() or {}

local function fail(message)
    app.alert({ title = "Gemini Map Builder", text = message, buttons = { "OK" } })
    print("[Gemini Map Builder] " .. message)
end

if not app.hasMap() then
    fail("Abra um mapa antes de executar o construtor.")
    return
end

local function integer(n)
    return type(n) == "number" and n == math.floor(n)
end

local function parseIds(raw)
    local ids, allowed, infos = {}, {}, {}
    local maxId = math.min(65535, Items.getMaxId())

    local function add(id)
        if not integer(id) or id < 1 or id > maxId or not Items.exists(id) then
            error("ID de item invalido ou nao carregado: " .. tostring(id))
        end
        if not allowed[id] then
            if #ids >= MAX_IDS then
                error("Limite de " .. MAX_IDS .. " IDs permitidos por pedido.")
            end
            local info = Items.getInfo(id)
            if not info then
                error("Nao foi possivel ler as propriedades do ID " .. id)
            end
            allowed[id] = true
            infos[id] = info
            ids[#ids + 1] = id
        end
    end

    for token in raw:gmatch("[^,%s;]+") do
        local a, b = token:match("^(%d+)%-(%d+)$")
        if a then
            a, b = tonumber(a), tonumber(b)
            if b < a or b - a + 1 > MAX_IDS then
                error("Intervalo invalido ou grande demais: " .. token)
            end
            for id = a, b do add(id) end
        else
            local id = tonumber(token)
            if not id or not integer(id) then
                error("Use IDs separados por virgula ou intervalo como 100-120.")
            end
            add(id)
        end
    end

    if #ids == 0 then error("Informe ao menos um ID de item.") end
    table.sort(ids)
    return ids, allowed, infos
end

-- Handle SSE chunks that can end in the middle of a JSON line.
local function sendGemini(key, model, prompt)
    if not model:match("^[%w_%.%-]+$") then
        error("Nome de modelo invalido.")
    end

    local url = "https://generativelanguage.googleapis.com/v1beta/models/"
        .. model .. ":streamGenerateContent?alt=sse"
    local body = {
        contents = { { role = "user", parts = { { text = prompt } } } },
        generationConfig = {
            responseMimeType = "application/json",
            temperature = 0.2,
            maxOutputTokens = 8192,
        },
    }
    local started = http.postJsonStream(url, body, {
        ["x-goog-api-key"] = key,
    })
    if not started.ok then
        error("Falha ao iniciar a chamada HTTPS: " .. tostring(started.error))
    end

    local buffer, textParts = "", {}
    local size, status = 0, 0
    local completed, streamError = false, nil

    local function handleLine(line)
        local payload = line:match("^data:%s*(.+)$")
        if not payload or payload == "[DONE]" then return end
        local ok, msg = pcall(json.decode, payload)
        if not ok or type(msg) ~= "table" then return end
        if msg.error then
            streamError = tostring(msg.error.message or "Erro da API Gemini")
            return
        end
        local candidate = msg.candidates and msg.candidates[1]
        local parts = candidate and candidate.content and candidate.content.parts
        if parts then
            for _, part in ipairs(parts) do
                if type(part.text) == "string" then
                    size = size + #part.text
                    if size > MAX_RESPONSE_CHARS then
                        streamError = "Resposta muito grande."
                        return
                    end
                    textParts[#textParts + 1] = part.text
                end
            end
        end
    end

    -- The native HTTP stream worker has its own 30-second timeout.
    for _ = 1, 600 do
        app.sleep(100)
        app.yield()
        local chunk = http.streamRead(started.sessionId)
        if chunk.data and chunk.data ~= "" then
            buffer = buffer .. chunk.data
            if #buffer > MAX_RESPONSE_CHARS then
                streamError = "Fluxo maior que o limite aceito."
                break
            end
            while true do
                local eol = buffer:find("\n", 1, true)
                if not eol then break end
                local line = buffer:sub(1, eol - 1):gsub("\r$", "")
                buffer = buffer:sub(eol + 1)
                handleLine(line)
                if streamError then break end
            end
        end
        if streamError then break end
        if chunk.hasError then
            streamError = tostring(chunk.error or "Erro de rede")
            break
        end
        if chunk.finished then
            status = chunk.status or 0
            completed = true
            if buffer ~= "" then handleLine(buffer:gsub("\r$", "")) end
            break
        end
    end
    http.streamClose(started.sessionId)

    if streamError then error(streamError) end
    if not completed then error("Tempo limite da chamada Gemini excedido.") end
    if status < 200 or status >= 300 then
        error("Gemini retornou HTTP " .. tostring(status) .. ". Verifique API key, modelo e cota.")
    end
    local responseText = table.concat(textParts)
    if responseText == "" then error("Gemini nao retornou um layout JSON.") end
    return responseText
end

local function validatePlan(plan, x0, y0, z, width, height, allowed, infos, preserve)
    if type(plan) ~= "table" or type(plan.tiles) ~= "table" then
        error('Resposta invalida. Esperado: {"tiles":[{"x":0,"y":0,"items":[123]}]}')
    end
    if #plan.tiles == 0 or #plan.tiles > MAX_TILES then
        error("A resposta deve conter de 1 a " .. MAX_TILES .. " tiles.")
    end
    local seen, toApply = {}, {}
    local skipped = 0
    local map = app.map
    for i, entry in ipairs(plan.tiles) do
        if type(entry) ~= "table" or not integer(entry.x) or not integer(entry.y)
            or entry.x < 0 or entry.x >= width or entry.y < 0 or entry.y >= height then
            error("Coordenada relativa invalida no tile " .. i)
        end
        local positionKey = entry.x .. ":" .. entry.y
        if seen[positionKey] then error("Tile duplicado: " .. positionKey) end
        seen[positionKey] = true

        if type(entry.items) ~= "table" or #entry.items < 1
            or #entry.items > MAX_ITEMS_PER_TILE then
            error("Lista de itens invalida no tile " .. i)
        end
        local hasNewGround, ordered, objects = false, {}, {}
        for _, id in ipairs(entry.items) do
            if not integer(id) or not allowed[id] then
                error("ID nao permitido no tile " .. i .. ": " .. tostring(id))
            end
            if infos[id].isGroundTile then
                if hasNewGround then error("Mais de um piso no tile " .. i) end
                hasNewGround = true
                ordered[1] = id
            else
                objects[#objects + 1] = id
            end
        end
        for _, id in ipairs(objects) do ordered[#ordered + 1] = id end
        local x, y = x0 + entry.x, y0 + entry.y
        local existing = map:getTile(x, y, z)
        -- A ground-only tile may receive objects without replacing its ground.
        -- Preserve mode rejects decorated tiles and ground replacements.
        local occupied = existing and (existing.itemCount > 0
            or (hasNewGround and existing.hasGround))
        if preserve and occupied then
            skipped = skipped + 1
        else
            if not hasNewGround and not (existing and existing.hasGround) then
                error("Tile sem piso em (" .. x .. "," .. y .. "). Inclua um ID de ground.")
            end
            toApply[#toApply + 1] = { x = x, y = y, items = ordered }
        end
    end
    return toApply, skipped
end

local dlg = Dialog({ title = "Gemini AI Map Builder (experimental)", width = 570 })
dlg:label({ text = "API Gemini: https://aistudio.google.com/apikey" })
dlg:input({ id = "apiKey", label = "API key (vazio = usar chave salva):", text = "" })
dlg:check({ id = "remember", text = "Salvar chave neste PC (sem criptografia)", selected = false })
dlg:input({ id = "model", label = "Modelo:", text = config.model or "gemini-2.5-flash" })
dlg:separator()
dlg:input({
    id = "instruction",
    label = "Descreva o que construir:",
    text = "Crie um pequeno jardim com caminho central e arvores.",
})
dlg:input({
    id = "ids",
    label = "IDs permitidos (ex.: 100,101,200-230):",
    text = config.ids or "",
})
dlg:newrow()
dlg:number({ id = "x", label = "X inicial:", value = 1000, min = 0, max = 65535 })
dlg:number({ id = "y", label = "Y inicial:", value = 1000, min = 0, max = 65535 })
dlg:number({ id = "z", label = "Piso Z:", value = 7, min = 0, max = 15 })
dlg:newrow()
dlg:number({ id = "width", label = "Largura:", value = 12, min = 1, max = 40 })
dlg:number({ id = "height", label = "Altura:", value = 12, min = 1, max = 40 })
dlg:newrow()
dlg:check({
    id = "preserve",
    text = "Nao alterar tiles ocupados (mais seguro)",
    selected = true,
})
dlg:label({ text = "Maximo de 200 tiles por pedido; IDs sao IDs de item do servidor." })
dlg:label({ text = "Sprites multipartes exigem conhecimento da posicao de cada peca." })
dlg:separator()

local submit = false
dlg:button({
    id = "generate",
    text = "Gerar plano",
    focus = true,
    onclick = function(d) submit = true; d:close() end,
})
dlg:button({
    id = "cancel",
    text = "Cancelar",
    onclick = function(d) d:close() end,
})
dlg:show()
if not submit then return end

local data = dlg.data or {}
local key = data.apiKey ~= "" and data.apiKey or config.apiKey
if not key or key == "" then
    fail("Informe uma API key Gemini.")
    return
end
local model = data.model or ""
local x0, y0 = tonumber(data.x), tonumber(data.y)
local z = tonumber(data.z)
local width, height = tonumber(data.width), tonumber(data.height)
if not integer(x0) or not integer(y0) or not integer(z)
    or not integer(width) or not integer(height)
    or z < 0 or z > 15 or width < 1 or width > 40 or height < 1 or height > 40
    or x0 < 0 or y0 < 0
    or x0 + width > math.min(65536, app.map.width)
    or y0 + height > math.min(65536, app.map.height) then
    fail("Coordenadas fora dos limites do mapa ou area invalida.")
    return
end
if not data.instruction or data.instruction:match("^%s*$") then
    fail("Descreva o que deseja construir.")
    return
end

local okIds, ids, allowed, infos = pcall(parseIds, data.ids or "")
if not okIds then fail(tostring(ids)); return end

config.model = model
config.ids = data.ids
if data.apiKey ~= "" and data.remember then config.apiKey = key end
settings:save(config)

local catalog = {}
for _, id in ipairs(ids) do
    local info = infos[id]
    catalog[#catalog + 1] = string.format("%d (%s; %s)", id,
        tostring(info.name or "sem nome"):sub(1, 50),
        info.isGroundTile and "ground" or "objeto")
end

local rows = {}
for ry = 0, height - 1 do
    local cells = {}
    for rx = 0, width - 1 do
        local tile = app.map:getTile(x0 + rx, y0 + ry, z)
        local cell = "."
        if tile then
            if tile.itemCount > 0 then cell = "X"
            elseif tile.hasGround then cell = "g" end
        end
        cells[#cells + 1] = cell
    end
    rows[#rows + 1] = table.concat(cells)
end

local prompt = table.concat({
    "Voce e um planejador de tiles para Remere's Map Editor (Tibia).",
    "Produza APENAS JSON valido, sem explicacoes ou markdown.",
    'Formato exato: {"tiles":[{"x":0,"y":0,"items":[100,200]}]}',
    "x e y sao offsets inteiros comecando em 0. Nao envie coordenadas absolutas nem z.",
    "Area: largura " .. width .. ", altura " .. height .. ". Piso z=" .. z .. ".",
    "Estado atual (linhas y=0..altura-1, colunas x=0..largura-1):",
    "Legenda: . = tile vazio; g = so piso; X = contem objetos.",
    table.concat(rows, "\n"),
    data.preserve and "Modo preservacao: NUNCA use X; em g so adicione objetos, sem criar ground." or
        "Modo de edicao: objetos preexistentes sao mantidos; ground novo substitui o anterior.",
    "Use SOMENTE os IDs da lista. Maximo " .. MAX_TILES
        .. " tiles, e maximo " .. MAX_ITEMS_PER_TILE .. " itens por tile.",
    "Quando gerar piso, informe o ground antes dos objetos e nao use mais de um ground por tile.",
    "Nao repita coordenadas, nao invente IDs e nao inclua scripts/comandos.",
    "IDs disponiveis: " .. table.concat(catalog, ", "),
    "Solicitacao do usuario: " .. data.instruction,
}, "\n")

print("[Gemini Map Builder] Solicitando layout ao Gemini...")
local okResponse, response = pcall(sendGemini, key, model, prompt)
if not okResponse then fail("Erro na API: " .. tostring(response)); return end

local okJson, plan = pcall(json.decode, response)
if not okJson then
    fail("A IA nao retornou JSON valido. Tente uma regiao menor.")
    return
end

local okPlan, placements, skipped =
    pcall(validatePlan, plan, x0, y0, z, width, height, allowed, infos, data.preserve)
if not okPlan then fail("Plano recusado: " .. tostring(placements)); return end
if #placements == 0 then
    fail("Nenhuma alteracao disponivel. A area pode estar ocupada ou os IDs nao correspondem.")
    return
end

local sample = {}
for i = 1, math.min(8, #placements) do
    local p = placements[i]
    sample[#sample + 1] = string.format("(%d,%d,%d): %s",
        p.x, p.y, z, table.concat(p.items, ","))
end
local result = app.alert({
    title = "Confirmar plano Gemini",
    text = string.format(
        "Mapa: %s\nArea: (%d,%d,%d), %dx%d\nTiles para editar: %d\nIgnorados: %d\n\nAmostra:\n%s\n\nAplicar?",
        app.map.name, x0, y0, z, width, height, #placements, skipped, table.concat(sample, "\n")
    ),
    buttons = { "Yes", "No" },
})
if result ~= 1 then
    print("[Gemini Map Builder] Plano cancelado, mapa inalterado.")
    return
end

local success, applyErr = pcall(function()
    app.transaction("Gemini Map Builder", function()
        for _, p in ipairs(placements) do
            local tile = app.map:getOrCreateTile(p.x, p.y, z)
            assert(tile, "Nao foi possivel criar tile")
            for _, id in ipairs(p.items) do
                tile:addItem(id)
            end
        end
    end)
end)
if not success then fail("Falha ao aplicar (transacao revertida): " .. tostring(applyErr)); return end

app.refresh()
app.setCameraPosition(x0 + math.floor(width / 2), y0 + math.floor(height / 2), z)
app.alert({
    title = "Gemini Map Builder",
    text = #placements .. " tiles aplicados. Use Ctrl+Z para desfazer. Salve o mapa se estiver correto.",
    buttons = { "OK" },
})
