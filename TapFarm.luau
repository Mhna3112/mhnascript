local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local CONFIG = {
	Tap = true,
	TapInterval = 0.12,
	Hatch = true,
	Egg = nil :: string?,
	EquipBest = true,
	EquipBestMode = "Clicks",
	EquipBestInterval = 30,
	AntiAfk = true,
	Webhook = true,
	WebhookUrl = "",
	RareOneIn = 1000,
}

local WEBHOOK_FILE = "TapFarm_webhook.txt"
pcall(function()
	if isfile and isfile(WEBHOOK_FILE) then CONFIG.WebhookUrl = readfile(WEBHOOK_FILE) end
end)

local env = getgenv()
if env.TapFarm then env.TapFarm.Stop() end

local Comm = require(ReplicatedStorage.Packages.Comm).ClientComm
local Remotes = ReplicatedStorage:WaitForChild("RemoteServices")
local function service(name: string): any
	return Comm.new(Remotes, false, name):BuildObject()
end

local TapService = service("TapService")
local PetService = service("PetService")
local DataController = require(ReplicatedStorage.Controllers.Core.DataController)
local EggController = require(ReplicatedStorage.Controllers.Pets.EggController)
local LaunchEggConfig = require(ReplicatedStorage.Shared.Pets.LaunchEggConfig)
local EggPricing = require(ReplicatedStorage.Shared.Pets.EggPricing)

local player = Players.LocalPlayer
local running = true
local threads: { thread } = {}
local conns: { RBXScriptConnection } = {}

local function data(): any
	local replica = DataController:GetReplica()
	return replica and replica.Data
end

local function tapBlocked(): boolean
	return player:GetAttribute("ColosseumActive") == true
		or player:GetAttribute("AtDigsite") == true
		or player:GetAttribute("DiggingActive") == true
end

local function loop(flag: string, interval: () -> number, body: () -> ())
	table.insert(threads, task.spawn(function()
		while running do
			if CONFIG[flag] then
				local ok, err = pcall(body)
				if not ok then warn("[TapFarm]", err) end
			end
			task.wait(interval())
		end
	end))
end

local seq = 1e6
loop("Tap", function() return CONFIG.TapInterval end, function()
	if tapBlocked() then return end
	seq += 1
	TapService.TapRequested:Fire({ Auto = false, ClientSequence = seq, Source = "button" })
end)

local function bestEgg(d: any): string?
	local coins = d.Currencies.Coins or 0
	local best, bestPrice = nil, -1
	for name, cfg in LaunchEggConfig do
		local ok, price = pcall(EggPricing.GetUnitPrice, d, name, cfg.Price)
		if ok and type(price) == "number" and price <= coins and price > bestPrice then
			best, bestPrice = name, price
		end
	end
	return best
end

local function stopHatch()
	local egg = EggController:GetAutoHatchEgg()
	if egg ~= nil then EggController:ToggleAutoHatch(egg) end
end

loop("Hatch", function() return 3 end, function()
	local d = data()
	if not d then return end
	local want = CONFIG.Egg or bestEgg(d)
	local cur = EggController:GetAutoHatchEgg()
	if cur ~= nil and cur ~= want and CONFIG.Egg then stopHatch() cur = nil end
	if cur == nil and want and LaunchEggConfig[want] then
		EggController:ToggleAutoHatch(want)
	end
end)

loop("EquipBest", function() return CONFIG.EquipBestInterval end, function()
	PetService.PetActionRequested:Fire({ Action = "EquipBest", Mode = CONFIG.EquipBestMode })
end)

local okVim, VIM = pcall(game.GetService, game, "VirtualInputManager")
local okVu, VirtualUser = pcall(game.GetService, game, "VirtualUser")
table.insert(conns, player.Idled:Connect(function()
	if not CONFIG.AntiAfk then return end
	if okVim and VIM then
		VIM:SendKeyEvent(true, Enum.KeyCode.F15, false, game)
		VIM:SendKeyEvent(false, Enum.KeyCode.F15, false, game)
	elseif okVu and VirtualUser then
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.zero)
	end
end))

local disabledIdled = {}
local function setGameIdleRejoin(enabled: boolean)
	if not getconnections then return end
	for _, c in getconnections(player.Idled) do
		local ok, src = pcall(debug.info, c.Function, "s")
		if ok and type(src) == "string" and src:find("ReconnectController", 1, true) then
			if enabled then c:Enable() else c:Disable() table.insert(disabledIdled, c) end
		end
	end
	if enabled then table.clear(disabledIdled) end
end
if CONFIG.AntiAfk then setGameIdleRejoin(false) end

local HttpService = game:GetService("HttpService")
local httpRequest = request or http_request or (syn and syn.request)
local EggService = service("EggService")

local function fmt(n: number): string
	for _, s in { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } } do
		if n >= s[1] then return string.format("%.2f%s", n / s[1], s[2]) end
	end
	return tostring(math.floor(n))
end

local function validWebhook(url: string): boolean
	return url:match("^https://discord%.com/api/webhooks/") ~= nil
		or url:match("^https://discordapp%.com/api/webhooks/") ~= nil
end

local function sendWebhook(egg: string, pet: any)
	if not httpRequest or not validWebhook(CONFIG.WebhookUrl) then return end
	local body = HttpService:JSONEncode({
		username = "TapFarm",
		embeds = { {
			title = string.format("%s %s", pet.Tier ~= "Normal" and pet.Tier or "", pet.Name or "?"),
			description = string.format("**%s** đã ấp được từ trứng **%s**", player.Name, egg),
			color = 0xFFC83C,
			fields = {
				{ name = "Rarity", value = tostring(pet.Rarity), inline = true },
				{ name = "Odds", value = "1 in " .. fmt(pet.OneIn or 0), inline = true },
				{ name = "Power", value = fmt(pet.Power or 0), inline = true },
				{ name = "Auto-deleted", value = pet.AutoDeleted and "yes" or "no", inline = true },
			},
			timestamp = DateTime.now():ToIsoDate(),
		} },
	})
	task.spawn(pcall, httpRequest, {
		Url = CONFIG.WebhookUrl, Method = "POST",
		Headers = { ["Content-Type"] = "application/json" }, Body = body,
	})
end

table.insert(conns, EggService.EggHatchResult:Connect(function(r)
	if not CONFIG.Webhook or type(r) ~= "table" or r.Success ~= true or type(r.Pets) ~= "table" then return end
	for _, pet in r.Pets do
		if type(pet) == "table" and (tonumber(pet.OneIn) or 0) >= CONFIG.RareOneIn then
			sendWebhook(tostring(r.Egg), pet)
		end
	end
end))

local C = {
	bg = Color3.fromRGB(22, 24, 30),
	panel = Color3.fromRGB(32, 35, 44),
	text = Color3.fromRGB(235, 237, 242),
	dim = Color3.fromRGB(150, 155, 170),
	on = Color3.fromRGB(70, 200, 120),
	off = Color3.fromRGB(85, 90, 105),
	accent = Color3.fromRGB(110, 140, 255),
}

local function make(class: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(class)
	for k, v in props do inst[k] = v end
	for _, c in children or {} do c.Parent = inst end
	return inst
end
local function corner(r: number) return make("UICorner", { CornerRadius = UDim.new(0, r) }) end

local gui = make("ScreenGui", { Name = "TapFarmUI", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
local okHui, hui = pcall(function() return gethui and gethui() end)
local okCore, core = pcall(game.GetService, game, "CoreGui")
gui.Parent = (okHui and hui) or (okCore and core) or player:WaitForChild("PlayerGui")

local main = make("Frame", {
	Size = UDim2.fromOffset(260, 0), AutomaticSize = Enum.AutomaticSize.Y,
	Position = UDim2.new(0, 20, 0.5, -150), BackgroundColor3 = C.bg, BorderSizePixel = 0, Parent = gui,
}, { corner(10), make("UIStroke", { Color = C.panel, Thickness = 1 }) })

local header = make("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, Parent = main })
make("TextLabel", {
	Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1,
	Text = "TapFarm", TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left, Parent = header,
})
local closeBtn = make("TextButton", {
	Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -32, 0, 4), BackgroundColor3 = C.panel,
	Text = "X", TextColor3 = C.dim, Font = Enum.Font.GothamBold, TextSize = 13, Parent = header,
}, { corner(6) })
local minBtn = make("TextButton", {
	Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -62, 0, 4), BackgroundColor3 = C.panel,
	Text = "–", TextColor3 = C.dim, Font = Enum.Font.GothamBold, TextSize = 13, Parent = header,
}, { corner(6) })

local body = make("Frame", {
	Size = UDim2.new(1, 0, 0, 0), Position = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1, Parent = main,
}, {
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }),
})

local order = 0
local function row(height: number?): Frame
	order += 1
	return make("Frame", {
		Size = UDim2.new(1, 0, 0, height or 32), BackgroundColor3 = C.panel, LayoutOrder = order, Parent = body,
	}, { corner(8) })
end
local function label(parent: Instance, text: string, color: Color3?): TextLabel
	return make("TextLabel", {
		Size = UDim2.new(0.55, 0, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1,
		Text = text, TextColor3 = color or C.text, Font = Enum.Font.Gotham, TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = parent,
	})
end

local function toggle(text: string, flag: string)
	local r = row()
	label(r, text)
	local track = make("TextButton", {
		Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -50, 0.5, -10), Text = "",
		AutoButtonColor = false, Parent = r,
	}, { corner(10) })
	local knob = make("Frame", { Size = UDim2.fromOffset(16, 16), BackgroundColor3 = C.text, Parent = track }, { corner(8) })
	local function paint()
		track.BackgroundColor3 = CONFIG[flag] and C.on or C.off
		knob.Position = CONFIG[flag] and UDim2.fromOffset(22, 2) or UDim2.fromOffset(2, 2)
	end
	track.MouseButton1Click:Connect(function()
		CONFIG[flag] = not CONFIG[flag]
		if flag == "Hatch" and not CONFIG.Hatch then stopHatch() end
		if flag == "AntiAfk" then setGameIdleRejoin(not CONFIG.AntiAfk) end
		paint()
	end)
	paint()
end

local function input(text: string, initial: string, placeholder: string, onCommit: (string) -> string)
	local r = row()
	label(r, text)
	local box = make("TextBox", {
		Size = UDim2.new(0.42, 0, 0, 22), Position = UDim2.new(0.58, -10, 0.5, -11), BackgroundColor3 = C.bg,
		Text = initial, PlaceholderText = placeholder, PlaceholderColor3 = C.dim, TextColor3 = C.text,
		Font = Enum.Font.Gotham, TextSize = 12, ClearTextOnFocus = false, Parent = r,
	}, { corner(6) })
	box.FocusLost:Connect(function() box.Text = onCommit(box.Text) end)
end

local function cycle(text: string, options: { string }, flag: string)
	local r = row()
	label(r, text)
	local btn = make("TextButton", {
		Size = UDim2.new(0.42, 0, 0, 22), Position = UDim2.new(0.58, -10, 0.5, -11), BackgroundColor3 = C.accent,
		Text = CONFIG[flag], TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 12, Parent = r,
	}, { corner(6) })
	btn.MouseButton1Click:Connect(function()
		local i = (table.find(options, CONFIG[flag]) or 0) % #options + 1
		CONFIG[flag] = options[i]
		btn.Text = options[i]
	end)
end

toggle("Auto Tap", "Tap")
input("Tap interval (s)", tostring(CONFIG.TapInterval), "0.12", function(s)
	local n = tonumber(s)
	if n and n == n then CONFIG.TapInterval = math.clamp(n, 0.11, 5) end
	return tostring(CONFIG.TapInterval)
end)
toggle("Auto Hatch", "Hatch")
input("Egg", CONFIG.Egg or "", "auto (best)", function(s)
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then CONFIG.Egg = nil return "" end
	for name in LaunchEggConfig do
		if name:lower() == s:lower() then CONFIG.Egg = name return name end
	end
	return CONFIG.Egg or ""
end)
toggle("Auto Equip Best", "EquipBest")
cycle("Equip mode", { "Clicks", "Gems", "Luck" }, "EquipBestMode")
toggle("Anti-AFK", "AntiAfk")
toggle("Rare pet webhook", "Webhook")
input("Webhook URL", CONFIG.WebhookUrl ~= "" and "(saved)" or "", "discord webhook", function(s)
	s = s:gsub("%s", "")
	if s == "(saved)" then return s end
	if s == "" or validWebhook(s) then
		CONFIG.WebhookUrl = s
		pcall(writefile, WEBHOOK_FILE, s)
	end
	return CONFIG.WebhookUrl ~= "" and "(saved)" or ""
end)
input("Rare if 1 in ≥", tostring(CONFIG.RareOneIn), "1000", function(s)
	local n = tonumber(s)
	if n and n == n and n >= 1 then CONFIG.RareOneIn = math.floor(n) end
	return tostring(CONFIG.RareOneIn)
end)

local statsRow = row(54)
local stats = label(statsRow, "", C.dim)
stats.Size = UDim2.new(1, -20, 1, 0)
stats.TextYAlignment = Enum.TextYAlignment.Center
stats.TextWrapped = true
stats.Font = Enum.Font.Code
stats.TextSize = 12

do
	local dragging, startPos, startMouse
	table.insert(conns, header.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			dragging, startPos, startMouse = true, main.Position, io.Position
		end
	end))
	table.insert(conns, UserInputService.InputChanged:Connect(function(io)
		if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
			local d = io.Position - startMouse
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

minBtn.MouseButton1Click:Connect(function()
	body.Visible = not body.Visible
	minBtn.Text = body.Visible and "–" or "+"
end)

table.insert(threads, task.spawn(function()
	local samples = {}
	while running do
		local d = data()
		if d then
			local now = os.clock()
			table.insert(samples, { t = now, taps = d.Statistics.ActualTaps or 0, eggs = d.Statistics.EggsOpened or 0 })
			while #samples > 1 and now - samples[1].t > 10 do table.remove(samples, 1) end
			local a, b = samples[1], samples[#samples]
			local dt = math.max(b.t - a.t, 1e-3)
			stats.Text = string.format("Taps/s: %.1f\nEggs/min: %.0f\nHatching: %s",
				(b.taps - a.taps) / dt, (b.eggs - a.eggs) / dt * 60, tostring(EggController:GetAutoHatchEgg() or "-"))
		end
		task.wait(1)
	end
end))

local function stop()
	running = false
	for _, t in threads do pcall(task.cancel, t) end
	for _, c in conns do c:Disconnect() end
	table.clear(threads)
	table.clear(conns)
	stopHatch()
	setGameIdleRejoin(true)
	gui:Destroy()
	env.TapFarm = nil
end
closeBtn.MouseButton1Click:Connect(stop)

env.TapFarm = { Config = CONFIG, Stop = stop }
print("[TapFarm] started")
