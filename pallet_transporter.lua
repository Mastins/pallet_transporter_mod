PalletTransporter = {}

-- Vzdálenost (v metrech), ve které se konec jednoho dopravníku považuje za navázaný na začátek dalšího
PalletTransporter.HANDOFF_DISTANCE = 0.1

-- Pokud dopravník nemá navazující pokračování, posuneme paletu o tolik metrů za endNode navíc,
-- ať celá "vyjede" mimo konstrukci a spadne rovně na zem, místo aby se naklápěla přesně na hraně
PalletTransporter.DEAD_END_OVERSHOOT = 0

-- Doba (v ms) plynulého najetí palety na startNode - vyrovnání rotace + "výtah" na plošinu
PalletTransporter.PICKUP_DURATION = 10

-- Pomocná funkce: lineární interpolace úhlu nejkratší cestou (ošetří přechod přes -pi/pi)
local function angleLerp(fromAngle, toAngle, t)
    local diff = toAngle - fromAngle
    while diff > math.pi do
        diff = diff - 2 * math.pi
    end
    while diff < -math.pi do
        diff = diff + 2 * math.pi
    end
    return fromAngle + diff * t
end

-- Globální seznam všech položených instancí tohoto placeable typu - potřebujeme ho pro navazování dopravníků na sebe
PalletTransporter.transporters = PalletTransporter.transporters or {}

-- Kontrola pozadavku (pro placeable vracime true)
function PalletTransporter.prerequisitesPresent(specializations)
    return true
end

-- NOVÉ: registrace vlastních XML cest, jinak schema validace selže
function PalletTransporter.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("PalletTransporter")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".palletTransporter.objectTrigger#node", "Trigger node pro detekci palet")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".palletTransporter.transporterStart#node", "Startovní bod posunu palety")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".palletTransporter.transporterEnd#node", "Koncový bod posunu palety")
    schema:register(XMLValueType.FLOAT, basePath .. ".palletTransporter.transporterEnd#speed", "Rychlost posunu palety (m/s)", 1.5)
    schema:setXMLSpecializationType()
end

-- FS25 PLACEABLE: Zde se registruji funkce pro dany placeable type
function PalletTransporter.registerFunctions(placeableType)
    -- Tímto enginu řekneme, že tato funkce existuje a může být volána z triggeru
    SpecializationUtil.registerFunction(placeableType, "transporterTriggerCallback", PalletTransporter.transporterTriggerCallback)
    SpecializationUtil.registerFunction(placeableType, "findNextTransporter", PalletTransporter.findNextTransporter)
end

-- FS25 PLACEABLE: Prihlaseni k udalostem
function PalletTransporter.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PalletTransporter)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PalletTransporter)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate", PalletTransporter)
end


-- Zavola se pri koupi nebo nacteni ulozene hry
function PalletTransporter:onLoad(savegame)
    self.spec_palletTransporter = {}
    local spec = self.spec_palletTransporter

    -- Oprava: Přidán XMLValueType.NODE, aby engine věděl, že hledá index z i3d
    spec.pickupTriggerNode = self.xmlFile:getValue("placeable.palletTransporter.objectTrigger#node", XMLValueType.NODE_INDEX, self.components, self.i3dMappings)
    spec.startNode = self.xmlFile:getValue("placeable.palletTransporter.transporterStart#node", XMLValueType.NODE_INDEX, self.components, self.i3dMappings)
    spec.endNode = self.xmlFile:getValue("placeable.palletTransporter.transporterEnd#node", XMLValueType.NODE_INDEX, self.components, self.i3dMappings)
    spec.moveSpeed = self.xmlFile:getValue("placeable.palletTransporter.transporterEnd#speed", 1.5)

    spec.activePallets = {}

    if spec.pickupTriggerNode ~= nil then
        addTrigger(spec.pickupTriggerNode, "transporterTriggerCallback", self)
        print("[palletTransporter] Trigger zaregistrován, dopravník je aktivní (node " .. tostring(spec.pickupTriggerNode) .. ").")
    else
        print("[palletTransporter] ERROR: Nepodarilo se nacist objectTrigger z XML!")
    end

    -- Spočítáme si dráhu posunu jednou dopředu (start je statický placeable, netřeba přepočítávat každý snímek)
    if spec.startNode ~= nil and spec.endNode ~= nil then
        local sx, sy, sz = getWorldTranslation(spec.startNode)
        local ex, ey, ez = getWorldTranslation(spec.endNode)

        spec.startPos = { x = sx, y = sy, z = sz }
        spec.endPos = { x = ex, y = ey, z = ez }
        spec.dir = { x = ex - sx, y = ey - sy, z = ez - sz }
        spec.totalDistance = MathUtil.vector3Length(spec.dir.x, spec.dir.y, spec.dir.z)

        local srx, sry, srz = getWorldRotation(spec.startNode)
        spec.startRot = { x = srx, y = sry, z = srz }

        if spec.totalDistance > 0.0001 then
            spec.dir.x = spec.dir.x / spec.totalDistance
            spec.dir.y = spec.dir.y / spec.totalDistance
            spec.dir.z = spec.dir.z / spec.totalDistance
        end

        print(string.format("[palletTransporter] Dráha posunu nastavena, délka = %.2f m, rychlost = %.2f m/s.", spec.totalDistance, spec.moveSpeed))
    else
        print("[palletTransporter] ERROR: Nepodarilo se nacist transporterStart/transporterEnd z XML!")
    end

    -- DŮLEŽITÉ: placeable objekty se defaultně needují per-frame - bez tohoto se onUpdate nikdy nezavolá
    self:raiseActive()

    -- Zaregistrujeme se do globálního seznamu, ať nás případný předchozí dopravník najde jako navazující
    table.insert(PalletTransporter.transporters, self)
end

function PalletTransporter:transporterTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    local spec = self.spec_palletTransporter

    -- Ověříme, zda objekt vůbec existuje
    if otherId ~= nil and otherId ~= 0 then
        -- Získáme herní objekt (instanci) z ID uzlu
        local object = g_currentMission:getNodeObject(otherId)

        -- Kontrola, zda objekt patří pod třídu Pallet (Farming Simulator 25 standard)
        if object ~= nil and (object.isPallet or (object.isa ~= nil and object:isa(Pallet))) then
            if onEnter then
                -- Paleta vjela do zóny -> uložíme do tabulky a spustíme plynulé najetí na start (fáze "pickup")
                if spec.activePallets[otherId] == nil then
                    -- DŮLEŽITÉ: pokud paletu drží vidle (dynamický mount), musíme ji nejdřív odpojit.
                    -- Jinak fyzikální joint mezi vidlemi a paletou bojuje s naším ručním posunem a vozidlo se zasekne.
                    if object.unmountDynamic ~= nil and object.dynamicMountJointIndex ~= nil then
                        object:unmountDynamic()
                        -- 3. Změna kolizní masky: Paleta bude ignorovat vozidla (Merlo/vidle), 
                        -- ale zachová si kolizi s terénem, budovami a dopravníkem (maska 0x00200001)
                        setCollisionMask(object.rootNode, 0x00200001)
                     end

                    -- Zapamatujeme si aktuální pozici a rotaci - z ní paletu plynule "narovnáme" a přisuneme na start
                    local ex, ey, ez = getWorldTranslation(otherId)
                    local erx, ery, erz = getWorldRotation(otherId)

                    spec.activePallets[otherId] = {
                        object = object,
                        phase = "pickup",
                        pickupFromPos = { x = ex, y = ey, z = ez },
                        pickupFromRot = { x = erx, y = ery, z = erz },
                        pickupElapsed = 0,
                        distance = 0,
                        arrived = false
                    }
                    -- Přepneme na kinematické tělo, ať s naším posunem nebojuje fyzikální simulace
                    setRigidBodyType(otherId, RigidBodyType.KINEMATIC)
                    print("[palletTransporter] DETEKCE: Paleta (ID: " .. tostring(otherId) .. ") vstoupila na dopravník!")
                end

            elseif onLeave then
                -- DŮLEŽITÉ: pokud je paleta ještě v pohybu (nedojela na konec), IGNORUJEME.
                -- Trigger zóna je malá a paleta z ní při posunu vyjede dřív, než dojede na konec dopravníku.
                -- Dokončení (obnovení fyziky, odebrání ze sledování) řeší až onUpdate, jakmile paleta skutečně dorazí na konec.
                local data = spec.activePallets[otherId]
                if data ~= nil and data.arrived then
                    spec.activePallets[otherId] = nil
                    setRigidBodyType(otherId, RigidBodyType.DYNAMIC)
                    print("[palletTransporter] DETEKCE: Paleta (ID: " .. tostring(otherId) .. ") opustila dopravník.")
                end
            end
        end
    end
end

function PalletTransporter:onDelete()
    local spec = self.spec_palletTransporter
    if spec ~= nil and spec.pickupTriggerNode ~= nil then
        removeTrigger(spec.pickupTriggerNode)
    end

    -- Odregistrujeme se ze seznamu dopravníků, ať na nás nikdo neukazuje jako na navazující
    for i, transporter in ipairs(PalletTransporter.transporters) do
        if transporter == self then
            table.remove(PalletTransporter.transporters, i)
            break
        end
    end
end

-- Najde jiný dopravník, jehož startNode leží blízko dané pozice (typicky konec tohoto dopravníku)
function PalletTransporter:findNextTransporter(pos)
    for _, transporter in ipairs(PalletTransporter.transporters) do
        if transporter ~= self then
            local otherSpec = transporter.spec_palletTransporter
            if otherSpec ~= nil and otherSpec.startPos ~= nil then
                local dx = pos.x - otherSpec.startPos.x
                local dy = pos.y - otherSpec.startPos.y
                local dz = pos.z - otherSpec.startPos.z
                local dist = MathUtil.vector3Length(dx, dy, dz)

                if dist <= PalletTransporter.HANDOFF_DISTANCE then
                    return otherSpec
                end
            end
        end
    end

    return nil
end

function PalletTransporter:onUpdate(dt, isActiveForInput, isActiveForPeriod, isSelected)
    local spec = self.spec_palletTransporter

    -- DŮLEŽITÉ: bez tohoto by se update po prvním snímku "uspal" a přestal by se volat
    self:raiseActive()

    -- Bez platné dráhy (start/end) nemá smysl cokoliv počítat
    if spec.startPos == nil or spec.totalDistance == nil or spec.totalDistance <= 0.0001 then
        return
    end

    for palletId, data in pairs(spec.activePallets) do
        if data.phase == "pickup" then
            -- Fáze 1: plynulé přesunutí z místa vyložení (např. z vidlí) na startNode + narovnání rotace
            data.pickupElapsed = data.pickupElapsed + dt
            local t = math.min(data.pickupElapsed / PalletTransporter.PICKUP_DURATION, 1)

            local x = data.pickupFromPos.x + (spec.startPos.x - data.pickupFromPos.x) * t
            local y = data.pickupFromPos.y + (spec.startPos.y - data.pickupFromPos.y) * t
            local z = data.pickupFromPos.z + (spec.startPos.z - data.pickupFromPos.z) * t
            setWorldTranslation(palletId, x, y, z)

            local rx = angleLerp(data.pickupFromRot.x, spec.startRot.x, t)
            local ry = angleLerp(data.pickupFromRot.y, spec.startRot.y, t)
            local rz = angleLerp(data.pickupFromRot.z, spec.startRot.z, t)
            setRotation(palletId, rx, ry, rz)

            if t >= 1 then
                -- Pickup hotový -> přepneme do fáze běžné jízdy po dráze start -> end
                data.phase = "transport"
                data.distance = 0
            end

        elseif data.phase == "transport" and not data.arrived then
            -- Fáze 2: jízda po dráze start -> end konstantní rychlostí
            -- dt je v ms, převedeme na sekundy
            data.distance = data.distance + spec.moveSpeed * dt * 0.001

            if data.distance >= spec.totalDistance then
                data.distance = spec.totalDistance
                data.arrived = true
            end

            local x = spec.startPos.x + spec.dir.x * data.distance
            local y = spec.startPos.y + spec.dir.y * data.distance
            local z = spec.startPos.z + spec.dir.z * data.distance

            setWorldTranslation(palletId, x, y, z)

            if data.arrived then
                -- Zkusíme najít navazující dopravník (jeho startNode blízko našeho endNode)
                local nextSpec = self:findNextTransporter(spec.endPos)

                if nextSpec ~= nil then
                    -- Předáme paletu navazujícímu dopravníku - znovu přes plynulou "pickup" fázi,
                    -- ať to nesekne, i kdyby startNode dalšího dopravníku nebyl na milimetr přesně napojený
                    nextSpec.activePallets[palletId] = {
                        object = data.object,
                        phase = "pickup",
                        pickupFromPos = { x = x, y = y, z = z },
                        pickupFromRot = { x = spec.startRot.x, y = spec.startRot.y, z = spec.startRot.z },
                        pickupElapsed = 0,
                        distance = 0,
                        arrived = false
                    }
                    spec.activePallets[palletId] = nil
                    print("[palletTransporter] Paleta (ID: " .. tostring(palletId) .. ") predana navazujicimu dopravniku.")
                else
                    -- Konec řady bez navazujícího dopravníku -> posuneme paletu ještě kousek za hranu,
                    -- ať celá "vyjede" z konstrukce a spadne rovně, místo aby se naklápěla přesně na okraji
                    local ox = x + spec.dir.x * PalletTransporter.DEAD_END_OVERSHOOT
                    local oy = y + spec.dir.y * PalletTransporter.DEAD_END_OVERSHOOT
                    local oz = z + spec.dir.z * PalletTransporter.DEAD_END_OVERSHOOT
                    setWorldTranslation(palletId, ox, oy, oz)

                    -- Vrátíme paletě normální fyziku a přestaneme ji sledovat
                    setRigidBodyType(palletId, RigidBodyType.DYNAMIC)
                    spec.activePallets[palletId] = nil
                    print("[palletTransporter] Paleta (ID: " .. tostring(palletId) .. ") dojela na konec dopravníku.")
                end
            end
        end
    end
end