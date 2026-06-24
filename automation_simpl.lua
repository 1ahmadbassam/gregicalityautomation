-- Preamble
local version = 0.1
local xnet_controller_pos = {x = -1080.0, y = 86.0, z = -1044.0}
local gtce_tiers = {"ulv", "lv", "mv", "hv", "ev", "iv", "luv", "zpm", "uv", "uhv", "uev"}

--- Libraries
local component = require("component")
local sides = require("sides")
local os = require("os")
local serialization = require("serialization")

--- Utility
local function split(str, sep)
    local result = {}
    local regex = ("([^%s]+)"):format(sep)
    for match in str:gmatch(regex) do
        table.insert(result, match)
    end
    return result
end

local function tocsv(tab)
    local res = ""
    local b = false
    for _, v in pairs(tab) do
        if not b then
            res = v
            b = true
        else
            res = res .. "," .. v
        end
    end
    return res
end

local function getTableLength(tab)
    local count = 0
    for _ in pairs(tab) do
        count = count + 1
    end
    return count
end

local function findInTable(tab, item)
    for i=1,#tab do
        if tab[i] == item then
            return i
        end
    end
    return nil
end

local function capitalize(s, delim)
    s = s:gsub("^%l", string.upper)
    s = s:gsub("([" .. delim:gsub("([^%w])", "%%%1") .. "])(%l)", function(d, c)
        return d .. string.upper(c)
    end)
    return s
end

local function printTable(t, indent)
    indent = indent or ""
    for key, value in pairs(t) do
        if type(value) == "table" then
            print(indent .. key .. ":")
            printTable(value, indent .. "  ")
        else
            print(indent .. key .. ": " .. tostring(value))
        end
    end
end

--- Components
local xnet = component.xnet
local inv = component.inventory_controller
local gtce = component.gtce_bridge

--- Interfaces
local allsides = {sides.up, sides.down, sides.north, sides.south, sides.east, sides.west}

local function toabspos(base, rel)
    return {x = base.x + rel.x, y = base.y + rel.y, z = base.z + rel.z}
end

local function todoublepos(pos)
    return {x = pos.x+0.0, y = pos.y+0.0, z = pos.z+0.0}
end

local function comparepos(pos1, pos2)
    return pos1.x == pos2.x and pos1.y == pos2.y and pos1.z == pos2.z
end

local function findTaggedXNetInterface(tag)
    for _, interface in ipairs(xnet.getConnectedBlocks()) do
        if interface.connector and interface.connector == tag then
            return {xnet_pos=todoublepos(interface.pos), xnet_side=sides[tostring(interface.side)]}
        end
    end
    return nil
end

local function findGTMachines()
    local machines = {}
    local gt_machines = gtce.getMachines()
    local xnet_interfaces = xnet.getConnectedBlocks()
    for _, machine in ipairs(gt_machines) do
        local abs_pos_x, abs_pos_y, abs_pos_z = machine.getPosition()
        local abs_pos = todoublepos({x = abs_pos_x, y=abs_pos_y, z=abs_pos_z})
        local found_interface = false
        for _, interface in ipairs(xnet_interfaces) do
            if comparepos(toabspos(xnet_controller_pos, interface.pos), abs_pos) then
                local name, tier = machine.getMachineName():match("^([^%.]+)%.([^%.]+)$")
                if not machines[name] then
                    machines[name] = {}
                end
                table.insert(machines[name], {
                    xnet_pos = todoublepos(interface.pos),
                    xnet_side = sides[tostring(interface.side)],
                    instance = machine,
                    tier = tier
                })
                found_interface = true
                break
            end
        end
        if not found_interface then
            error("Could not find XNet interface for GTCE machine at x="..abs_pos.x..", y="..abs_pos.y..", z="..abs_pos.z..".")
        end
    end
    return machines
end

local storage = findTaggedXNetInterface("storage")
if not storage then
    error("Storage interface missing.")
end
for _, side in ipairs(allsides) do
    if inv.getInventoryName(side) == "storagedrawers:controllerslave" then
        storage.inv = side
        storage.size = inv.getInventorySize(side)
    end
end
if not storage["inv"] then
    error("Storage scanner interface missing.")
end

local temp_storage = findTaggedXNetInterface("temp_storage")
if not temp_storage then
    error("Temporary storage interface missing.")
end
temp_storage.size=300

local machines = findGTMachines()

print("Automation System v" .. tostring(version) .. " Loaded.")

-- Items Mapping
local function sort_items_mapping(items_mapping, length)
    local items_mapping_sorted = io.open("items.at", "w")
    items_mapping_sorted:write("label,name,slot\n")
    local prev = nil
    local meta = {}
    for i=1,length do
        local cur = nil
        items_mapping:seek("set", 0)
        for line in items_mapping:lines() do
            if (not prev or line > prev) and (not cur or line < cur) then
                cur = line
            end
        end
        if cur then
            local c = cur:sub(1,1):lower()
            if not meta[c] then
                meta[c] = items_mapping_sorted:seek("cur", 0)
            end
            items_mapping_sorted:write(cur .. '\n')
            prev = cur
        end
    end
    items_mapping:close()
    items_mapping_sorted:close()
    local items_meta = io.open("items.descriptor.at", "w")
    items_meta:write(serialization.serialize(meta))
    items_meta:close()
    return meta
end

local function create_items_mapping()
    local items_mapping = io.open("/tmp/items.at", "w")
    local length = 0
    for slot=1,storage.size do
        local item = inv.getStackInSlot(storage.inv, slot)
        if item then
            item = {item.label, "<" .. item.name .. ":" .. item.damage .. ">", slot}
            item = tocsv(item)
            items_mapping:write(item .. "\n")
            length = length + 1
        end
    end
    items_mapping:close()
    local meta = sort_items_mapping(io.open("/tmp/items.at", "r"), length)
    os.remove("/tmp/items.at")
    return io.open("items.at", "r"), meta
end

local items_mapping = io.open("items.at", "r")
local items_mapping_meta = io.open("items.descriptor.at", "r")
local meta
if not items_mapping or not items_mapping_meta then
    print("Warning: items mapping not found. Will be created.")
    io.write("This will take a while... ")
    items_mapping, meta = create_items_mapping()
    storage.meta = meta
    print("Done.")
else
    storage.meta = serialization.unserialize(items_mapping_meta:read("*a"))
    items_mapping_meta:close()
    print("Items mapping loaded successfully.")
end

local function find_item_slot(label)
    label = label:lower()
    local first_char = label:sub(1, 1)
    local offset = storage.meta[first_char]
    if not offset then
        return nil 
    end
    items_mapping:seek("set", offset)
    for line in items_mapping:lines() do
        local line_label, _, slot = line:lower():match("^([^,]+),([^,]+),([^,]+)$")
        if line_label == label then
            return tonumber(slot)
        end
        if line_label:sub(1, 1) > first_char then
            break
        end
    end
    return nil
end

local function getStoredAmount(label)
    local slot = find_item_slot(label)
    if slot then
        local item = inv.getStackInSlot(storage.inv, slot)
        if item then
            return item.size
        end
    end
    return 0
end

-- Recipes
local recipes = {}
local recipes_file = io.open("recipes.at", "r")
if recipes_file then
    local c = recipes_file:read("*a")
    recipes_file:close()
    recipes = serialization.unserialize(c)
    print("Recipes loaded successfully.")
else
    print("Warning: recipes file not found. Will be created.")
end

-- Interface
local function getHighestMachineTier(machine)
    local highest = nil
    for _, inst in ipairs(machines[machine]) do
        if not highest or findInTable(gtce_tiers, highest) <= findInTable(gtce_tiers, inst.tier) then
            highest = inst.tier
        end
    end
    return highest
end

local function addRecipe()
    local recipe = {}
    print("Adding a new recipe... Recipes in database: " .. tostring(#recipes) .. ".")
    -- machine
    print("Available machines:")
    local i = 1
    local j = 0
    local machines_arr = {}
    for k, _ in pairs(machines) do
        table.insert(machines_arr, k)
        io.write(tostring(i)..". "..capitalize(tostring(k):gsub("_"," ")," ").."\t")
        i = i + 1
        j = j + 1
        if j % 3 == 0 then
            j = 0
            print("")
        end
    end
    if j ~= 0 then
        print("")
    end
    io.write("Please select machine: ")
    recipe.machine = machines_arr[tonumber(io.read())]
    -- tier
    print("Available Tiers:")
    local j = 0
    local max_tier = getHighestMachineTier(recipe.machine)
    local max_tier_idx = nil
    for i=1, #gtce_tiers do
        io.write(tostring(i)..". "..gtce_tiers[i]:upper().."\t")
        j = j + 1
        if j % 3 == 0 then
            j = 0
            print("")
        end
        if max_tier == gtce_tiers[i] then
            max_tier_idx = i
            break
        end
    end
    if j ~= 0 then
        print("")
    end
    io.write("Please select tier (default: "..max_tier_idx..") : ")
    local user = io.read()
    if not user or user == "" then
        user = max_tier_idx
    end
    recipe.tier = gtce_tiers[tonumber(user)]
    -- items
    recipe.inputs={}
    recipe.outputs={}
    recipe.chancedoutputs={}
    local hasInputs = false
    local hasOutputs = false
    if findInTable(xnet.getSupportedCapabilities(machines[recipe.machine][1].xnet_pos), "items") then
        io.write("Item Input (Y/N)? ")
        local input = io.read():lower() == "y"
        io.write("Item Output (Y/N)? ")
        local output = io.read():lower() == "y"
        if input then
            hasInputs = true
            local more = true
            while more do
                io.write("Enter Item Input Label: ")
                local label = io.read()
                io.write("Enter Item Input Amount: ")
                local amount = tonumber(io.read())
                io.write("Input Consumed (Y/N) (default: Y)? ")
                local consumed = io.read()
                table.insert(recipe.inputs, {label=label, amount=amount, consumed=(consumed == "" or consumed:lower() == "y")})
                io.write("More Inputs (Y/N)? ")
                more = io.read():lower() == "y"
            end
        end
        if output then
            hasOutputs = true
            local more = true
            while more do
                io.write("Enter Item Output Label: ")
                local label = io.read()
                io.write("Enter Item Output Amount: ")
                local amount = tonumber(io.read())
                io.write("Output Chance (0-100%) (default: 100%): ")
                local chance = io.read()
                if tonumber(chance) then
                    table.insert(recipe.chancedoutputs, {label=label, amount=amount, chance=tonumber(chance)})
                else
                    table.insert(recipe.outputs, {label=label, amount=amount})
                end
                io.write("More Outputs (Y/N)? ")
                more = io.read():lower() == "y"
            end
        end
    end
    -- fluid
    if findInTable(xnet.getSupportedCapabilities(machines[recipe.machine][1].xnet_pos), "fluid") then
        -- placeholder
    end
    if not hasInputs and not hasOutputs then
        print("Recipe does not contain inputs or outputs and cannot be added.")
    else
        table.insert(recipes, recipe)
        print("Recipe added successfully.")
    end
end

--- resource planner
local function combineInputs(recipe)
    local rep = ""
    local b = false
    for _, item in ipairs(recipe.inputs) do
        if b then
            rep = rep .. " + "
        else
            b = true
        end
        rep = rep .. item.label .. "x" .. tostring(item.amount)
    end
    return rep
end

local function resolveItem(label, amount, intermediates)
    local found_recipes = {}
    local selected_recipe = nil
    local steps = {}
    for _, recipe in ipairs(recipes) do
        for _, output in ipairs(recipe.outputs) do
            if output.label == label then
                table.insert(found_recipes, recipe)
            end
        end
        for _, chancedoutput in ipairs(recipe.chancedoutputs) do
            if chancedoutput.label == label then
                table.insert(found_recipes, recipe)
            end
        end
    end
    if #found_recipes > 1 then
        print("Found multiple recipes for product with label: " .. label .. ".")
        print("Select recipe:")
        for i=1,#found_recipe do
            if found_recipes[i].chance then
                print(tostring(i)..". " .. combineInputs(found_recipes[i]) .. " (chanced:" .. tostring(found_recipes[i].chance) "%).")
            else
                print(tostring(i)..". " .. combineInputs(found_recipes[i]) .. ".")
            end
        end
        local selected_recipe = found_recipes[tonumber(io.read())]
    elseif #found_recipes == 1 then
        selected_recipe = found_recipes[1]
    end
    if selected_recipe then
        for _, input in ipairs(selected_recipe.inputs) do
            local needed_amount = nil
            if input.consumed then
                needed_amount = math.ceil(amount / input.amount)
            else
                needed_amount = 1
            end
            for _, step in ipairs(resolveItem(input.label, needed_amount, intermediates)) do
                table.insert(steps, step)
            end
        end
        table.insert({
            label=label,
            amount=amount,
            machine=selected_recipe.machine,
            tier=selected_recipe.tier
        })
    end
    return steps
end

local function produceOutput()
    print("Production initiated.")
    io.write("Enter item label: ")
    local label = io.read()
    io.write("Enter item amount: ")
    local amount = tonumber(io.read())
    io.write("Use intermediates in storage (Y/N) (default: Y) ? ")
    local intermediates = io.read():lower() == "y"
    local tree = resolveItem(label, amount, intermediates)
    printTable(tree)
end

-- local function produceOutput()
    -- to be implmented
    -- ask for amount and item
    -- ask for crafting or existing for intermediates (if recipe not found, assume base item)
    -- if existing, after constructing dependency tree + confirming existence of machines, ask which items to be produced and which used (also check count to ensure that existing can be used) for base items, need to calculate how much needed . if chanced output, must use probabilistic calculation based on expected value and monitor output until desired target is met
    -- need to think of how to handle multiple recipes with existing + reserve base items
    -- need to think of how to reserve machines on multi dependency recipe + priority: which recipe to stall
    -- coroutines would be used to drive the machine until recipe completion: monitor input to determine when to pull in new stacks, monitor output to determine progress
    -- optionally we should be able to specify a destination system other than the storage drawers, but storage drawers is good enough for now. if exists in drawers, need to check max size as well to check if we can output or amount too large
    -- before crafting, check if needed machines are available and not busy with other recipe otherwise stall as needed.
    -- if machine contains existing items or fluids, error
    -- need to also consider GT programmed circuits as recipe affectors.
    -- need to consider byproducts that are not related to output, what to do with them. prompt user. e.g. trash them or put them in other destination system or put them in drawers etc.
    -- need to consider: system could have more than 1 machine, so rather than reserving 1 of each machine for recipe and it sitting idle during which it isn't used, can instead use more than 1 machine to speed up (configurable) and only reserve when needed 
-- end

while true do
    print("Choose an option:")
    print("1. Add Recipe")
    print("2. Produce Output")
    print("3. Update Item Mapping")
    print("4. Exit")
    io.write("Enter your choice: ")
    local user = tonumber(io.read())
    if user and user >= 1 and user <= 4 then
        if user == 1 then
            addRecipe()
        elseif user == 2 then
            produceOutput()
        elseif user == 3 then
            io.write("Updating items mapping, this will take a while... ")
            if items_mapping then
                items_mapping:close()
            end
            items_mapping, meta = create_items_mapping()
            if not items_mapping or not meta then
                error("Unexpected error: items mapping not found.")
            end
            storage.meta = meta
            print("Done.")
        else
            break
        end
    else
        print("Invalid selection entered.")
    end
end

-- Exit
items_mapping:close()
if recipes then
    local recipes_file, err = io.open("recipes.at", "w")
    if recipes_file then
        recipes_file:write(serialization.serialize(recipes))
        recipes_file:close()
        print("Recipes saved successfully.")
    else
        error("Failed to open recipes file for writing: " .. tostring(err) .. ".")
    end
end
