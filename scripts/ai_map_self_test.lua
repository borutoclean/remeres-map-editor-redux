-- @Title: AI Mapping Self Test
-- @Description: Read-only validation of Lua mapping, sprite preview, and Gemini HTTP primitives
-- @Version: 0.1.0
-- Does not modify your map or send API requests.

local tests = {}
local function check(name, fn)
    local ok, result = pcall(fn)
    local passed = ok and result ~= false
    tests[#tests + 1] = { name = name, passed = passed, detail = ok and "" or tostring(result) }
end

check("Lua app/transaction API", function()
    assert(type(app.hasMap) == "function")
    assert(type(app.transaction) == "function")
    assert(type(app.refresh) == "function")
end)

check("Item metadata API", function()
    assert(type(Items.exists) == "function")
    assert(type(Items.getInfo) == "function")
    assert(Items.getMaxId() > 0)
end)

check("Gemini HTTPS streaming primitives", function()
    assert(type(http.postJsonStream) == "function")
    assert(type(http.streamRead) == "function")
    assert(type(http.streamClose) == "function")
end)

check("Native sprite preview API", function()
    assert(type(Image.composeItems) == "function")
    assert(type(Image.fromItemSprite) == "function")
end)

check("Native seam matching", function()
    assert(type(Image.edgeCost) == "function")
    assert(type(Image.autoArrange) == "function")
end)

local firstId
for id = 1, math.min(65535, Items.getMaxId()) do
    if Items.exists(id) then
        local info = Items.getInfo(id)
        if info and info.isGroundTile then
            firstId = id
            break
        end
    end
end

if firstId then
    check("Compose 2x2 sprite preview", function()
        local preview = Image.composeItems(2, 2, {
            { id = firstId, x = 0, y = 0 },
        })
        assert(preview and preview.valid and preview.width == 64 and preview.height == 64)
    end)

    check("Auto-arrange 1x1 grid", function()
        local layout = Image.autoArrange({firstId}, 1, 1)
        assert(layout and layout.entries and #layout.entries == 1)
        assert(layout.entries[1].id == firstId)
    end)

    check("Edge comparison returns numeric score", function()
        local cost = Image.edgeCost(firstId, firstId, "right")
        assert(type(cost) == "number")
    end)
else
    tests[#tests + 1] = {
        name = "Found loaded ground item for sprite tests", passed = false,
        detail = "Nenhum ground item carregado (abra um mapa e verifique itens.otb).",
    }
end

local successes, failures = 0, {}
for _, test in ipairs(tests) do
    local label = test.passed and "OK" or "FALHOU"
    print("[AI Self Test] " .. label .. ": " .. test.name)
    if test.passed then successes = successes + 1
    else failures[#failures + 1] = test.name .. ": " .. test.detail end
end
local summary = string.format("%d de %d verificacoes OK.\n", successes, #tests)
if #failures > 0 then
    summary = summary .. "Falhas:\n" .. table.concat(failures, "\n"):sub(1, 1000)
else
    summary = summary .. "API pronta para testes manuais em uma copia do mapa."
end
app.alert({ title = "AI Mapping Self Test", text = summary, buttons = { "OK" } })
