--[[
MM2 Script Hub (AF + AntiAFK) v1.6
Autor: tú
Descripción: AntiAFK + AutoFarm (evento y normal), Noclip, Auto-Reset al llenar bolsa, UI con slider 15–25.
Sin dependencias externas. Probado con exploits tipo Delta.

Si cambian cosas del juego, ajusta:
  - SETTINGS.BAG_TEXT_REGEX si el formato "12/40" cambia.
  - SETTINGS.EVENT_TOKEN_GUESS_NAMES para nuevos eventos.
]]--

--==============================--
--           SETTINGS           --
--==============================--
local SETTINGS = {
    SPEED_DEFAULT = 20,          -- valor inicial del slider (15–25)
    SPEED_MIN = 15,
    SPEED_MAX = 25,
    TELEPORT_DIST = 150,         -- si la moneda está más lejos que esto, TP directo
    BAG_LIMIT_DEFAULT = 40,      -- tope de bolsa por defecto
    BAG_TEXT_REGEX = "(%d+)%s*/%s*(%d+)", -- patrón para detectar "actual/limite" desde el GUI
    EVENT_TOKEN_GUESS_NAMES = { "Candy","Snow","SnowToken","Token","Present","Heart","CoinEvent","Ball","Orb" },
    COIN_CONTAINER_NAMES = { "CoinContainer","Coins","Coin","Drops","Tokens","CandyContainer" },
    NOTIF_ICON = nil,            -- puedes poner un asset id (rbxassetid://123) si quieres
}

--==============================--
--         DEPENDENCIAS         --
--==============================--
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local StarterGui   = game:GetService("StarterGui")
local LocalPlayer  = Players.LocalPlayer

-- Utilidad segura para notificar
local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title or "MM2 Script",
            Text = text or "",
            Duration = duration or 4,
            Icon = SETTINGS.NOTIF_ICON
        })
    end)
end

--==============================--
--        ESTADO GLOBAL         --
--==============================--
local State = {
    Enabled       = false,
    AntiAFK       = true,
    AutoReset     = true,
    NoClip        = true,
    Speed         = SETTINGS.SPEED_DEFAULT,
    EventTokenKey = "",      -- nombre personalizado para el token de evento (desde la UI)
    BagLimit      = SETTINGS.BAG_LIMIT_DEFAULT,

    Character     = nil,
    Root          = nil,
    Humanoid      = nil,

    _connections  = {},
    _noclipConn   = nil,
    _farmThread   = nil,
    _afkConn      = nil,
}

--==============================--
--      FUNCIONES AUXILIARES    --
--==============================--
local function isAlive()
    return State.Character
        and State.Character.Parent ~= nil
        and State.Root
        and State.Humanoid
        and State.Humanoid.Health > 0
end

local function bindCharacter(char)
    State.Character = char
    State.Root = char:WaitForChild("HumanoidRootPart", 5)
    State.Humanoid = char:WaitForChild("Humanoid", 5)
end

local function onSpawned()
    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    bindCharacter(char)
end
onSpawned()
LocalPlayer.CharacterAdded:Connect(bindCharacter)

-- AntiAFK
local function startAntiAFK()
    if State._afkConn then State._afkConn:Disconnect() end
    local vu = game:FindService("VirtualUser") or loadstring("") -- cargar nada, solo para evitar warnings
    vu = vu or game:GetService("VirtualUser")
    State._afkConn = LocalPlayer.Idled:Connect(function()
        pcall(function()
            vu:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            task.wait(0.1)
            vu:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
        end)
    end)
end

local function stopAntiAFK()
    if State._afkConn then State._afkConn:Disconnect() State._afkConn=nil end
end

-- Noclip
local function startNoClip()
    if State._noclipConn then State._noclipConn:Disconnect() end
    State._noclipConn = RunService.Stepped:Connect(function()
        if State.NoClip and isAlive() then
            for _,v in ipairs(State.Character:GetDescendants()) do
                if v:IsA("BasePart") then
                    v.CanCollide = false
                    v.CustomPhysicalProperties = PhysicalProperties.new(0,0,0,0,0)
                end
            end
        end
    end)
end

-- Mover hacia CFrame con tween (suave) o TP si lejos
local function moveTo(targetCFrame, distance)
    if not isAlive() then return end
    if distance and distance > SETTINGS.TELEPORT_DIST then
        State.Root.CFrame = targetCFrame
        return nil
    else
        -- duración inversa a la "velocidad": t = distancia / velocidad
        local dist = distance or (State.Root.Position - targetCFrame.Position).Magnitude
        local duration = math.max(0.05, dist / math.clamp(State.Speed, SETTINGS.SPEED_MIN, SETTINGS.SPEED_MAX))
        local tween = TweenService:Create(State.Root, TweenInfo.new(duration, Enum.EasingStyle.Linear), {CFrame = targetCFrame})
        tween:Play()
        return tween
    end
end

-- Heurística: ¿es contenedor de monedas/tokens?
local function isCoinContainerName(n)
    if not n then return false end
    for _,k in ipairs(SETTINGS.COIN_CONTAINER_NAMES) do
        if string.find(string.lower(n), string.lower(k)) then return true end
    end
    return false
end

-- ¿Esta parte parece moneda/token?
local function looksLikeCoin(part)
    if not part or not part:IsA("BasePart") then return false end
    if not part:FindFirstChildOfClass("TouchTransmitter") and not part:FindFirstChild("TouchInterest") then
        return false
    end
    local n = part.Name or ""
    -- nombres típicos
    for _,guess in ipairs(SETTINGS.EVENT_TOKEN_GUESS_NAMES) do
        if string.find(string.lower(n), string.lower(guess)) then return true end
    end
    if part:GetAttribute("CoinID") ~= nil then return true end
    -- padre con nombre conocido
    local p = part.Parent
    if p and isCoinContainerName(p.Name) then return true end
    return false
end

-- Obtiene lista de monedas priorizando token de evento (por nombre/clave)
local function getAllCoins()
    local targetKey = string.lower(State.EventTokenKey or "")
    local eventCandidates, normalCandidates = {}, {}

    for _,obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") and (obj:FindFirstChild("TouchInterest") or obj:FindFirstChildOfClass("TouchTransmitter")) then
            if looksLikeCoin(obj) then
                local nameLower = string.lower(obj.Name)
                local parentLower = obj.Parent and string.lower(obj.Parent.Name) or ""
                local isEvent =
                    (targetKey ~= "" and (string.find(nameLower, targetKey) or string.find(parentLower, targetKey))) or
                    (obj:GetAttribute("IsEvent") == true)

                if not isEvent then
                    -- Si no hay clave específica, usa heurística "se parece a evento"
                    for _,guess in ipairs(SETTINGS.EVENT_TOKEN_GUESS_NAMES) do
                        if string.find(nameLower, string.lower(guess)) or string.find(parentLower, string.lower(guess)) then
                            isEvent = true
                            break
                        end
                    end
                end

                if isEvent then
                    table.insert(eventCandidates, obj)
                else
                    table.insert(normalCandidates, obj)
                end
            end
        end
    end

    -- Prioriza tokens de evento si existen
    if #eventCandidates > 0 then
        return eventCandidates, true
    else
        return normalCandidates, false
    end
end

-- Moneda más cercana
local function getNearestCoin()
    local coins = select(1, getAllCoins())
    local nearest, minDist = nil, math.huge
    if not isAlive() then return nil, minDist end
    for _,coin in ipairs(coins) do
        local d = (State.Root.Position - coin.Position).Magnitude
        if d < minDist then
            nearest = coin
            minDist = d
        end
    end
    return nearest, minDist
end

-- Detectar bolsa llena.
-- Estrategia: leer cualquier TextLabel del PlayerGui que contenga "num/num".
-- Si falla, usa el BagLimit configurado manualmente.
local function getBagProgress()
    local gui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local current, limit = nil, nil

    local function scan(inst)
        for _,d in ipairs(inst:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local text = tostring(d.Text or "")
                local a,b = string.match(text, SETTINGS.BAG_TEXT_REGEX)
                if a and b then
                    local ca, cb = tonumber(a), tonumber(b)
                    if ca and cb and cb > 0 and ca <= cb then
                        current, limit = ca, cb
                        return true
                    end
                end
            end
        end
        return false
    end

    if gui then scan(gui) end
    limit = limit or State.BagLimit
    current = current or 0
    return current, limit
end

local function resetCharacter()
    if not isAlive() then return end
    pcall(function()
        State.Humanoid:ChangeState(Enum.HumanoidStateType.Dead)
        State.Character:BreakJoints()
    end)
end

--==============================--
--         BUCLE FARM           --
--==============================--
local function startFarm()
    if State._farmThread then return end
    State._farmThread = task.spawn(function()
        notify("AutoFarm", "Iniciado.", 3)
        while State.Enabled do
            if isAlive() then
                -- ¿Bolsa llena?
                local have, cap = getBagProgress()
                if have >= cap then
                    notify("AutoFarm", "Bolsa llena ("..tostring(have).."/"..tostring(cap)..")", 3)
                    if State.AutoReset then
                        resetCharacter()
                        -- Espera respawn
                        LocalPlayer.CharacterAdded:Wait()
                        task.wait(1.0)
                        bindCharacter(LocalPlayer.Character)
                        task.wait(0.5)
                        goto continue
                    else
                        -- Si no hay reset, espera a que termine la ronda o a que el límite cambie
                        task.wait(1.0)
                        goto continue
                    end
                end

                -- Buscar moneda/token más cercano
                local coin, dist = getNearestCoin()
                if coin and coin.Parent then
                    local tween = moveTo(coin.CFrame, dist)
                    -- espera hasta recogerla o que se desactive
                    local t0 = os.clock()
                    while State.Enabled and coin and coin.Parent and isAlive() do
                        -- Si ya no tiene TouchInterest (recogida), sal
                        if not coin:FindFirstChild("TouchInterest") and not coin:FindFirstChildOfClass("TouchTransmitter") then
                            break
                        end
                        -- seguridad: si tarda demasiado, cancela y continúa
                        if os.clock() - t0 > 3.0 then
                            break
                        end
                        task.wait(0.05)
                    end
                    if tween then pcall(function() tween:Cancel() end) end
                else
                    -- No hay monedas visibles: espera un poco
                    task.wait(0.2)
                end
            end
            ::continue::
            task.wait(0.05)
        end
        notify("AutoFarm", "Detenido.", 3)
    end)
end

local function stopFarm()
    State.Enabled = false
    if State._farmThread then
        -- el hilo saldrá solo en el siguiente ciclo
        State._farmThread = nil
    end
end

--==============================--
--              UI              --
--==============================--
-- UI nativa (sin libs), estética simple
local function buildUI()
    -- Limpia instancias anteriores
    pcall(function()
        local old = game.CoreGui:FindFirstChild("MM2Hub_UI")
        if old then old:Destroy() end
    end)

    local sg = Instance.new("ScreenGui")
    sg.Name = "MM2Hub_UI"
    sg.IgnoreGuiInset = true
    sg.ResetOnSpawn = false
    sg.Parent = game:GetService("CoreGui")

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.new(0, 360, 0, 230)
    main.Position = UDim2.new(0.5, -180, 0.5, -115)
    main.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    main.BorderSizePixel = 0
    main.Parent = sg

    local uic = Instance.new("UICorner", main)
    uic.CornerRadius = UDim.new(0, 16)

    local shadow = Instance.new("ImageLabel", main)
    shadow.ZIndex = 0
    shadow.AnchorPoint = Vector2.new(0.5, 0.5)
    shadow.Position = UDim2.new(0.5, 0, 0.5, 6)
    shadow.Size = UDim2.new(1, 40, 1, 40)
    shadow.BackgroundTransparency = 1
    shadow.Image = "rbxassetid://5028857084"
    shadow.ImageTransparency = 0.3
    shadow.ScaleType = Enum.ScaleType.Slice
    shadow.SliceCenter = Rect.new(24, 24, 276, 276)

    local title = Instance.new("TextLabel", main)
    title.Text = "MM2 Script Hub — AF"
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(235,235,245)
    title.BackgroundTransparency = 1
    title.Position = UDim2.new(0, 16, 0, 10)
    title.Size = UDim2.new(1, -32, 0, 24)

    local line = Instance.new("Frame", main)
    line.BackgroundColor3 = Color3.fromRGB(40,40,50)
    line.BorderSizePixel = 0
    line.Position = UDim2.new(0, 16, 0, 38)
    line.Size = UDim2.new(1, -32, 0, 1)

    -- Botones/toggles helpers
    local function makeToggle(text, default, posY, callback)
        local btn = Instance.new("TextButton", main)
        btn.Text = ""
        btn.AutoButtonColor = false
        btn.BackgroundColor3 = Color3.fromRGB(30,30,38)
        btn.Position = UDim2.new(0, 16, 0, posY)
        btn.Size = UDim2.new(0, 160, 0, 36)
        btn.BorderSizePixel = 0
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)

        local lbl = Instance.new("TextLabel", btn)
        lbl.BackgroundTransparency = 1
        lbl.Text = text
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 14
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextColor3 = Color3.fromRGB(220,220,230)
        lbl.Position = UDim2.new(0, 12, 0, 0)
        lbl.Size = UDim2.new(1, -56, 1, 0)

        local dot = Instance.new("Frame", btn)
        dot.Size = UDim2.new(0, 18, 0, 18)
        dot.Position = UDim2.new(1, -28, 0.5, -9)
        dot.BackgroundColor3 = default and Color3.fromRGB(85,200,120) or Color3.fromRGB(90,90,100)
        dot.BorderSizePixel = 0
        Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

        local state = default
        btn.MouseButton1Click:Connect(function()
            state = not state
            dot.BackgroundColor3 = state and Color3.fromRGB(85,200,120) or Color3.fromRGB(90,90,100)
            callback(state)
        end)
        -- inicializa
        dot.BackgroundColor3 = default and Color3.fromRGB(85,200,120) or Color3.fromRGB(90,90,100)
        callback(default)
        return btn
    end

    local function makeButton(text, posY, callback)
        local btn = Instance.new("TextButton", main)
        btn.Text = text
        btn.Font = Enum.Font.GothamSemibold
        btn.TextSize = 14
        btn.TextColor3 = Color3.fromRGB(240,240,250)
        btn.AutoButtonColor = true
        btn.BackgroundColor3 = Color3.fromRGB(50,50,65)
        btn.BorderSizePixel = 0
        btn.Position = UDim2.new(0, 16, 0, posY)
        btn.Size = UDim2.new(0, 160, 0, 36)
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 12)
        btn.MouseButton1Click:Connect(callback)
        return btn
    end

    local function makeSlider(text, posY, minV, maxV, defaultV, onChange)
        local holder = Instance.new("Frame", main)
        holder.BackgroundTransparency = 1
        holder.Position = UDim2.new(0, 192, 0, posY)
        holder.Size = UDim2.new(0, 152, 0, 48)

        local lbl = Instance.new("TextLabel", holder)
        lbl.BackgroundTransparency = 1
        lbl.Text = text.." ("..tostring(defaultV)..")"
        lbl.Font = Enum.Font.Gotham
        lbl.TextSize = 14
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextColor3 = Color3.fromRGB(220,220,230)
        lbl.Position = UDim2.new(0, 0, 0, 0)
        lbl.Size = UDim2.new(1, 0, 0, 18)

        local bar = Instance.new("Frame", holder)
        bar.BackgroundColor3 = Color3.fromRGB(40,40,52)
        bar.BorderSizePixel = 0
        bar.Position = UDim2.new(0, 0, 0, 22)
        bar.Size = UDim2.new(1, 0, 0, 8)
        Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 6)

        local fill = Instance.new("Frame", bar)
        fill.BackgroundColor3 = Color3.fromRGB(100,170,255)
        fill.BorderSizePixel = 0
        fill.Size = UDim2.new((defaultV-minV)/(maxV-minV), 0, 1, 0)
        Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 6)

        local dragging = false
        local function setFromX(x)
            local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
            local val = math.floor(minV + rel * (maxV - minV) + 0.5)
            fill.Size = UDim2.new((val-minV)/(maxV-minV), 0, 1, 0)
            lbl.Text = text.." ("..tostring(val)..")"
            onChange(val)
        end

        bar.InputBegan:Connect(function(io)
            if io.UserInputType.Name == "MouseButton1" then
                dragging = true
                setFromX(io.Position.X)
            end
        end)
        bar.InputEnded:Connect(function(io)
            if io.UserInputType.Name == "MouseButton1" then dragging = false end
        end)
        bar.InputChanged:Connect(function(io)
            if dragging and io.UserInputType.Name == "MouseMovement" then
                setFromX(io.Position.X)
            end
        end)
        -- init
        onChange(defaultV)
        return holder
    end

    local function makeTextbox(placeholder, posY, default, onCommit)
        local tb = Instance.new("TextBox", main)
        tb.PlaceholderText = placeholder
        tb.Text = default or ""
        tb.Font = Enum.Font.Gotham
        tb.TextSize = 14
        tb.TextColor3 = Color3.fromRGB(230,230,240)
        tb.BackgroundColor3 = Color3.fromRGB(30,30,38)
        tb.BorderSizePixel = 0
        tb.Position = UDim2.new(0, 192, 0, posY)
        tb.Size = UDim2.new(0, 152, 0, 36)
        Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 10)
        tb.FocusLost:Connect(function(enter)
            if enter then onCommit(tb.Text) end
        end)
        return tb
    end

    -- Toggles izquierda
    makeToggle("AutoFarm", false, 56, function(on)
        State.Enabled = on
        if on then
            if not State._farmThread then startFarm() end
        else
            stopFarm()
        end
    end)

    makeToggle("Anti-AFK", true, 100, function(on)
        State.AntiAFK = on
        if on then startAntiAFK() else stopAntiAFK() end
    end)

    makeToggle("Auto-Reset", true, 144, function(on)
        State.AutoReset = on
    end)

    makeToggle("Noclip", true, 188, function(on)
        State.NoClip = on
        if on then startNoClip() end
    end)

    -- Controles derecha
    makeSlider("Velocidad", 56, SETTINGS.SPEED_MIN, SETTINGS.SPEED_MAX, SETTINGS.SPEED_DEFAULT, function(v)
        State.Speed = v
    end)

    makeTextbox("Token de evento (ej. Candy)", 108, "", function(txt)
        State.EventTokenKey = (txt or "")
        notify("AutoFarm", "Token objetivo: "..(State.EventTokenKey=="" and "auto" or State.EventTokenKey), 3)
    end)

    makeTextbox("Límite bolsa (default 40)", 152, tostring(SETTINGS.BAG_LIMIT_DEFAULT), function(txt)
        local n = tonumber(txt)
        if n and n > 0 then
            State.BagLimit = n
         
