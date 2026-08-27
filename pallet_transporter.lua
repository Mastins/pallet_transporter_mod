PalletTransporter = {}

-- Kontrola požadavků (pro placeable vracíme true)
function PalletTransporter.prerequisitesPresent(specializations)
    return true
end

-- FS25 PLACEABLE: Zde se registrují funkce pro daný placeable type
function PalletTransporter.registerFunctions(placeableType)

end

-- FS25 PLACEABLE: Přihlášení k událostem
function PalletTransporter.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PalletTransporter)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PalletTransporter)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate", PalletTransporter)
end


-- Zavolá se při koupi nebo načtení uložené hry
function PalletTransporter:onLoad(savegame)
    self.spec_palletTransporter = {}
    
    -- Ověřovací hláška do vývojářské konzole
    print("----------------------------------------------------------------------------")
    print("[palletTransporter] SKRIPT ZDE: Dopravnik byl uspesne polozen a inicializovan!")
    print("----------------------------------------------------------------------------")
end

function PalletTransporter:onDelete()
    local spec = self.spec_palletTransporter
    if spec ~= nil and spec.pickupTriggerNode ~= nil then
        removeTrigger(spec.pickupTriggerNode)
    end
end

function PalletTransporter:onUpdate(dt, isActiveForInput, isActiveForPeriod, isSelected)
    -- Zde bude později logika pro posun palet
end
