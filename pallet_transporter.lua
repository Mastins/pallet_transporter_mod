PalletTransporter = {}

-- Kontrola pozadavku (pro placeable vracime true)
function PalletTransporter.prerequisitesPresent(specializations)
    return true
end

-- FS25 PLACEABLE: Zde se registruji funkce pro dany placeable type
function PalletTransporter.registerFunctions(placeableType)

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
    
    -- Overovaci hlaska do vyvojarske konzole
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
    -- Zde bude pozdeji logika pro posun palet
end
