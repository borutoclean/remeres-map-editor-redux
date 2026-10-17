-- @Title: Sprite ID Inspector
-- @Description: Preview loaded client appearances and find matching server item IDs
-- @Version: 0.1.0
-- A client appearance ID is NOT automatically a placeable server item ID.

local function alert(msg)
    print("[Sprite Inspector] " .. msg)
    app.alert({ title = "Sprite ID Inspector", text = msg, buttons = { "OK" } })
end
local setup = Dialog({ title = "Sprite ID Inspector", width = 530 })
setup:label({ text = "Inspecione um intervalo de ate 220 IDs carregados no cliente." })
setup:combobox({
    id = "source", label = "Tipo de ID:",
    options = { "Server item ID", "Client appearance ID" },
    option = "Server item ID",
})
setup:newrow()
setup:number({ id = "from", label = "ID inicial:", value = 46967, min = 1, max = 65535 })
setup:number({ id = "to", label = "ID final:", value = 47146, min = 1, max = 65535 })
setup:separator()
setup:label({ text = "A galeria nao coloca itens no mapa nem modifica o cliente." })
local proceed = false
setup:button({ id = "open", text = "Abrir galeria", focus = true, onclick = function(d)
    proceed = true; d:close()
end })
setup:button({ id = "cancel", text = "Cancelar", onclick = function(d) d:close() end })
setup:show()
if not proceed then return end
local values = setup.data or {}
local from = tonumber(values.from)
local to = tonumber(values.to)
if not from or not to or from ~= math.floor(from) or to ~= math.floor(to)
    or to < from or to - from + 1 > 220 then
    alert("Intervalo invalido. Use de 1 ate 220 IDs em ordem crescente.")
    return
end

local isClient = values.source == "Client appearance ID"
local mapped = {}
local matches = 0
if isClient then
    local upper = math.min(65535, Items.getMaxId())
    for id = 1, upper do
        if Items.exists(id) then
            local info = Items.getInfo(id)
            if info and type(info.clientId) == "number"
                and info.clientId >= from and info.clientId <= to then
                if not mapped[info.clientId] then mapped[info.clientId] = {} end
                mapped[info.clientId][#mapped[info.clientId] + 1] = id
                matches = matches + 1
            end
        end
    end
end

local entries = {}
local placeable = {}
local hasBad = false
local noImage = 0
for id = from, to do
    local picture
    if isClient then
        picture = Image.fromSprite(id)
    elseif id <= Items.getMaxId() and Items.exists(id) then
        picture = Image.fromItemSprite(id)
    else
        picture = Image() -- unknown server ID; show an empty gallery cell
    end
    local label = tostring(id)
    local tooltip = ""
    if isClient then
        local choices = mapped[id]
        if choices and #choices > 0 then
            label = label .. " -> " .. choices[1]
            tooltip = "Client appearance " .. id .. " -> server item IDs: " .. table.concat(choices, ",")
            placeable[#placeable + 1] = choices[1]
        else
            label = label .. " (no item)"
            tooltip = "Nenhum ID de item do servidor usa esta appearance ID"
            hasBad = true
        end
    else
        if Items.exists(id) then
            local info = Items.getInfo(id)
            label = tostring(id)
            tooltip = string.format("Server item %d, client appearance %s: %s",
                id, tostring(info.clientId), tostring(info.name or "sem nome"))
            placeable[#placeable + 1] = id
        else
            label = label .. " (invalid)"
            tooltip = "Nao existe na lista de itens do servidor"
            hasBad = true
        end
    end
    if not picture or not picture.valid then noImage = noImage + 1 end
    entries[#entries + 1] = { text = label, image = picture, tooltip = tooltip }
end

local panel = Dialog({ title = "Sprite Gallery - " .. from .. " a " .. to, width = 760, height = 610 })
panel:label({ text = isClient and
    ("Client appearance IDs: " .. matches .. " relacionamentos com itens de servidor") or
    ("Server item IDs: " .. (to - from + 1) .. " aparencias verificadas") })
panel:label({ text = noImage .. " imagens nao renderizadas. Passe o mouse para detalhes do ID." })
panel:grid({
    id = "spriteGallery",
    items = entries,
    icon_width = 48,
    icon_height = 48,
    cell_width = 126,
    cell_height = 80,
    show_text = true,
})
panel:separator()
local copy = false
panel:button({ id = "copy", text = "Copiar IDs do servidor", onclick = function(d)
    copy = true; d:close()
end })
panel:button({ id = "close", text = "Fechar", onclick = function(d) d:close() end })
panel:show()

if copy then
    if #placeable == 0 then alert("Nenhum item de servidor reconhecido."); return end
    app.setClipboard(table.concat(placeable, ","))
    if hasBad then
        alert("Copiados " .. #placeable .. " IDs validos para a area de transferencia. Alguns IDs nao foram reconhecidos.")
    else
        alert("Copiados " .. #placeable .. " IDs. Cole no campo IDs do Structure Composer.")
    end
end
