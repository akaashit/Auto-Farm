for _, model in pairs(workspace:GetChildren()) do
    if model:FindFirstChild("CoinContainer") then
        for _, coin in pairs(model.CoinContainer:GetChildren()) do
            print(coin:GetAttribute("CoinID"), coin.Name)
        end
    end
end
-- CONFIGURACIÓN
local FARM_SPEED = 20 -- Velocidad de farmeo (20 recomendado)
local EVENT_COIN_ID = 1 -- Cambiar según el CoinID del evento

-- Clase AutoFarm
local AutoFarm = {}
AutoFarm.__index = AutoFarm

function AutoFarm.new(character)
    local self = setmetatable({}, AutoFarm)
    self.Character = character
    self.HumanoidRootPart = character:WaitForChild("HumanoidRootPart")
    self.Enabled = false
    self.speed = FARM_SPEED
    self.ToFarm = EVENT_COIN_ID
    return self
end

-- Detectar si la bolsa está llena
function AutoFarm:isBagFull()
    local gui = game.Players.LocalPlayer:FindFirstChild("PlayerGui")
    if gui then
        local main = gui:FindFirstChild("MainGUI")
        if main and main:FindFirstChild("CashBag") then
            local text = main.CashBag.Text
            local current, max = string.match(text, "(%d+)%/(%d+)")
            if tonumber(current) >= tonumber(max) then
                return true
            end
        end
    end
    return false
end

-- Obtener la moneda más cercana con el CoinID indicado
function AutoFarm:getNearestCoin()
    local closest_coin, min_distance = nil, math.huge
    for _, model in pairs(workspace:GetChildren()) do
        if model:FindFirstChild("CoinContainer") then
            for _, coin in pairs(model.CoinContainer:GetChildren()) do
                if coin:GetAttribute("CoinID") == self.ToFarm and coin:FindFirstChild("TouchInterest") then
                    local distance = (self.HumanoidRootPart.Position - coin.Position).Magnitude
                    if distance < min_distance then
                        closest_coin = coin
                        min_distance = distance
                    end
                end
            end
        end
    end
    return closest_coin, min_distance
end

-- Moverse hacia el objetivo con Tween
function AutoFarm:tweenTo(target)
    local distance = (self.HumanoidRootPart.Position - target.Position).Magnitude
    local tweenService = game:GetService("TweenService")
    local tween = tweenService:Create(
        self.HumanoidRootPart,
        TweenInfo.new(distance / self.speed, Enum.EasingStyle.Linear),
        {CFrame = target.CFrame}
    )
    tween:Play()
    return tween
end

-- Iniciar el autofarm
function AutoFarm:start()
    self.Enabled = true
    spawn(function()
        while self.Enabled do
            if self:isBagFull() then
                self:stop()
                game.Players.LocalPlayer.Character:BreakJoints() -- reset
                break
            end
            local coin, distance = self:getNearestCoin()
            if coin then
                if distance > 150 then
                    self.HumanoidRootPart.CFrame = coin.CFrame
                else
                    local tween = self:tweenTo(coin)
                    repeat task.wait() until not coin:FindFirstChild("TouchInterest") or not self.Enabled
                    tween:Cancel()
                end
            end
            task.wait(0.1)
        end
    end)
end

-- Detener el autofarm
function AutoFarm:stop()
    self.Enabled = false
end

-- ====================
-- CREAR UI
-- ====================
local screenGui = Instance.new("ScreenGui")
screenGui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0,200,0,120)
frame.Position = UDim2.new(0,10,0,10)
frame.BackgroundColor3 = Color3.fromRGB(45,45,45)
frame.BorderSizePixel = 0
frame.Parent = screenGui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,30)
title.Text = "Autofarm"
title.BackgroundColor3 = Color3.fromRGB(30,30,30)
title.TextColor3 = Color3.fromRGB(255,255,255)
title.Parent = frame

local startButton = Instance.new("TextButton")
startButton.Size = UDim2.new(1,-20,0,40)
startButton.Position = UDim2.new(0,10,0,40)
startButton.Text = "Start"
startButton.BackgroundColor3 = Color3.fromRGB(0,170,0)
startButton.TextColor3 = Color3.fromRGB(255,255,255)
startButton.Parent = frame

local stopButton = Instance.new("TextButton")
stopButton.Size = UDim2.new(1,-20,0,40)
stopButton.Position = UDim2.new(0,10,0,85)
stopButton.Text = "Stop"
stopButton.BackgroundColor3 = Color3.fromRGB(170,0,0)
stopButton.TextColor3 = Color3.fromRGB(255,255,255)
stopButton.Parent = frame

-- Crear instancia del autofarm
local farm = AutoFarm.new(game.Players.LocalPlayer.Character)

-- Conectar botones
startButton.MouseButton1Click:Connect(function()
    farm:start()
end)

stopButton.MouseButton1Click:Connect(function()
    farm:stop()
end)
