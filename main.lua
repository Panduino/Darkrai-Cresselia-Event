return function(mod)
  if mod.generation ~= 3 then return end

  local installed = false
  local function install()
    if installed then return true end
    local okUntamed, untamed = pcall(function() return mod:find("untamed_advanced") end)
    local engine = okUntamed and untamed and untamed.exports and untamed.exports.engine
    if type(engine) ~= "table" then
      mod.log:error("Darkrai + Cresselia Events requires Untamed Advanced")
      return false
    end

    local Dex = require("src.core.game3.dex")
    local Roamer = require("src.core.game3.roamer")
    local Objects = require("src.core.game3.objects")

    local function eventState(session)
      session.modData = session.modData or {}
      session.modData[mod.id] = session.modData[mod.id] or {}
      local state = session.modData[mod.id]

      -- One-time migration from the original compatibility mod so existing
      -- saves retain Darkrai/Cresselia progress after installing this split mod.
      if not state._legacyMigrated then
        local legacy = session.modData.rtc_untamed_nationaldex_compat
        if type(legacy) == "table" then
          if legacy.darkraiTowerTriggered == true then state.darkraiTowerTriggered = true end
          if legacy.cresseliaAttemptedThisVisit == true then state.cresseliaAttemptedThisVisit = true end
        end
        state._legacyMigrated = true
      end
      return state
    end

    -- Darkrai and Cresselia are stationary EventObjects rather than Untamed
    -- OWEs. Animate them with Untamed's down-facing walk frames in place.
    if not Objects._darkraiCresseliaIdleAnim then
      Objects._darkraiCresseliaIdleAnim = true
      local rawObjectsUpdate = Objects.update
      Objects.update = function(game, ...)
        local result = rawObjectsUpdate(game, ...)
        for _, lid in ipairs({126, 127}) do
          local actor = Objects._byId and Objects._byId[lid]
          if actor and actor._uadvIdleSheet and actor._uadvIdleRow then
            actor._uadvIdleTick = ((actor._uadvIdleTick or 0) + 1) % 32
            local frame = actor._uadvIdleTick >= 20 and actor._uadvIdleTick < 28 and 1 or 0
            local gid = string.format("uadv:%d:%d:0:%d:0",
              actor._uadvIdleSheet, frame, actor._uadvIdleRow)
            actor.graphicsId, actor.sprite = gid, gid
          end
        end
        return result
      end
    end

    -- Cresselia: after witnessing the Pokemon Tower Darkrai event, it can be
    -- found at night in Mt. Moon's old fossil chamber. Defeating it does not
    -- consume the encounter; only catching it completes the event.
    local CRESSELIA_NAT = 488
    local CRESSELIA_SPECIES = CRESSELIA_NAT + 64
    local CRESSELIA_MAP = "FR_MT_MOON_B2F"
    local CRESSELIA_NPC_ID = 127
    local cresseliaActor = nil
    local cresseliaBusy = false

    local function cresseliaNight()
      local hour = tonumber(os.date("*t").hour) or 0
      return hour >= 18 or hour < 4
    end

    local function cresseliaUnlocked(session)
      if not session then return false end
      local state = eventState(session)
      return state.darkraiTowerTriggered == true
    end

    local function cresseliaCaught(session)
      return session and session.dex and Dex.isCaught(session.dex, CRESSELIA_SPECIES) == true
    end

    local function clearCresseliaActor()
      if Objects._byId and Objects._byId[CRESSELIA_NPC_ID] then
        Objects._byId[CRESSELIA_NPC_ID] = nil
        for i = #(Objects._order or {}), 1, -1 do
          if Objects._order[i] == CRESSELIA_NPC_ID then table.remove(Objects._order, i) end
        end
      end
      cresseliaActor = nil
    end

    local function showCresselia()
      local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
      local shouldShow = session and session.map == CRESSELIA_MAP
        and cresseliaUnlocked(session) and cresseliaNight()
        and not cresseliaCaught(session) and not cresseliaBusy
        and eventState(session).cresseliaAttemptedThisVisit ~= true
      if not shouldShow then clearCresseliaActor(); return end
      if cresseliaActor and Objects._byId and Objects._byId[CRESSELIA_NPC_ID] == cresseliaActor then return end
      clearCresseliaActor()
      if not Objects._byId or not Objects._order then return end

      local personality = engine.random32 and engine.random32() or 0
      local atlasSpecies = engine.expansionSpecies(CRESSELIA_SPECIES, personality)
      if not atlasSpecies then return end
      local female = engine.femaleFor and engine.femaleFor(CRESSELIA_SPECIES, personality) or false
      local sheet, row = engine.Gfx.sheetFor(atlasSpecies, female, false)
      if not sheet then return end
      local graphicsId = string.format("uadv:%d:0:0:%d:0", sheet, row)

      -- This is the original fossil alcove; the vanilla fossils occupied
      -- (13,7) and (14,7). Cresselia waits deeper in the open area behind them.
      local x, y = 13, 5
      local elevation = engine.elevationAt and engine.elevationAt(x, y) or 3
      local actor = {
        active=true, localId=CRESSELIA_NPC_ID, originLocalId=CRESSELIA_NPC_ID,
        originMapId=session.map, cellX=x, cellY=y, px=x*16, py=y*16,
        homeX=x, homeY=y, targetX=x, targetY=y,
        facing="down", sprite=graphicsId, graphicsId=graphicsId,
        elevation=elevation, currentElevation=elevation,
        movementType=0x09, movement="STAY", range="DOWN",
        radius={x=0,y=0}, rangeX=0, rangeY=0,
        visible=true, hidden=false, invisible=false, frozen=true,
        passable=false, moving=false, progress=0, stepFrames=16,
        scriptBusy=false, _uadvIdleSheet=sheet, _uadvIdleRow=row, _uadvIdleTick=8,
        def={ localId=CRESSELIA_NPC_ID, x=x, y=y, graphicsId=graphicsId,
          movementType=0x09, facing="down" },
      }
      Objects._byId[CRESSELIA_NPC_ID] = actor
      Objects._order[#Objects._order + 1] = CRESSELIA_NPC_ID
      cresseliaActor = actor
    end

    local function triggerCresseliaScene()
      if not cresseliaActor or not cresseliaActor.active or cresseliaBusy then return false end
      local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
      if not session or session.map ~= CRESSELIA_MAP then return false end
      local P = engine.Player
      local distance = math.abs(P.cellX - cresseliaActor.cellX) + math.abs(P.cellY - cresseliaActor.cellY)
      if distance ~= 1 then return false end

      local Fade = require("src.ui.game3.fade")
      cresseliaBusy = true
      engine.Field.locked = true
      if P.cellX < cresseliaActor.cellX then P.facing = "right"
      elseif P.cellX > cresseliaActor.cellX then P.facing = "left"
      elseif P.cellY < cresseliaActor.cellY then P.facing = "down"
      else P.facing = "up" end

      -- Use a brief pale flash when the fade module exposes white modes;
      -- otherwise begin the battle directly rather than substituting a dark fade.
      local toWhite = Fade.MODE and (Fade.MODE.TO_WHITE or Fade.MODE.WHITE)
      local fromWhite = Fade.MODE and (Fade.MODE.FROM_WHITE or Fade.MODE.WHITE_IN)
      local function battle()
        clearCresseliaActor()
        mod.world:startWildBattle(CRESSELIA_SPECIES, 50, function()
          engine.Field.locked = false
          cresseliaBusy = false
          -- If it was defeated or escaped from, showCresselia() can restore it
          -- on a later nighttime visit. A caught Cresselia never returns.
          if not cresseliaCaught(session) then
            eventState(session).cresseliaAttemptedThisVisit = true
            clearCresseliaActor()
          end
        end)
      end
      if toWhite and fromWhite then
        Fade.begin(toWhite, 1, function()
          Fade.begin(fromWhite, 1, battle)
        end)
      else
        battle()
      end
      return true
    end

    local DARKRAI_NAT = 491
    local DARKRAI_SPECIES = DARKRAI_NAT + 64
    local TOWER_7F = "FR_POKEMON_TOWER_7F"
    local towerActor = nil
    local darkraiSceneBusy = false

    local function darkraiState(session)
      session.modData = session.modData or {}
      session.modData[mod.id] = session.modData[mod.id] or {}
      return session.modData[mod.id]
    end

    local function darkraiTowerTime()
      local hour = tonumber(os.date("*t").hour) or 0
      return hour >= 18 or hour < 4
    end

    local function addDarkraiRoamer(session)
      -- Navel/Birth owns grouped-roamer processing, but never block the
      -- stationary event from installing just because callback order differs.
      local group = session.roamer
      if type(group) ~= "table" or type(group.beasts) ~= "table" then
        group = { active = true, beasts = {} }
        session.roamer = group
      end
      for _, beast in ipairs(group.beasts) do
        if beast.darkrai then return beast end
      end

      local mon = Roamer.generateMon(DARKRAI_SPECIES, 50)
      local beast = {
        active = true,
        darkrai = true,
        species = DARKRAI_SPECIES,
        level = 50,
        hp = mon.hp or mon.maxHp,
        maxHp = mon.maxHp or mon.hp,
        status = 0,
        statusNum = 0,
        pid = mon.pid,
        ivs = mon.ivs,
        moves = mon.moves,
        pp = mon.pp,
        map = Roamer.LOCATIONS[(math.random(#Roamer.LOCATIONS))],
      }
      group.beasts[#group.beasts + 1] = beast
      return beast
    end

    local DARKRAI_NPC_ID = 126
    local UntamedEngine = engine

    local function clearTowerActor()
      if Objects._byId and Objects._byId[DARKRAI_NPC_ID] then
        Objects._byId[DARKRAI_NPC_ID] = nil
        for i = #(Objects._order or {}), 1, -1 do
          if Objects._order[i] == DARKRAI_NPC_ID then table.remove(Objects._order, i) end
        end
      end
      towerActor = nil
    end

    local function showTowerDarkrai()
      local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
      local mapId = session and session.map
      local state = session and darkraiState(session)
      local shouldShow = session and state and session.game_cleared == true
        and state.darkraiTowerTriggered ~= true and darkraiTowerTime()
        and mapId == TOWER_7F and not darkraiSceneBusy

      if not shouldShow then clearTowerActor(); return end
      if towerActor and Objects._byId and Objects._byId[DARKRAI_NPC_ID] == towerActor then return end
      clearTowerActor()
      if not Objects._byId or not Objects._order then return end

      -- This is a regular field NPC.  The graphics id uses Untamed Advanced's
      -- own serialized sprite format, so its OwSprites.draw hook renders
      -- Darkrai from the exact same atlas and palette as Untamed followers.
      local personality = engine.random32 and engine.random32() or 0
      local atlasSpecies = engine.expansionSpecies(DARKRAI_SPECIES, personality)
      if not atlasSpecies then return end
      local female = engine.femaleFor and engine.femaleFor(DARKRAI_SPECIES, personality) or false
      local sheet, row = engine.Gfx.sheetFor(atlasSpecies, female, false)
      if not sheet then return end

      -- Untamed follower face-down frame is frame 0.
      local graphicsId = string.format("uadv:%d:0:0:%d:0", sheet, row)
      local x, y = 11, 4
      local actor = {
        active=true, localId=DARKRAI_NPC_ID, originLocalId=DARKRAI_NPC_ID,
        originMapId=session.map, cellX=x, cellY=y, px=x*16, py=y*16,
        homeX=x, homeY=y, targetX=x, targetY=y,
        facing="down", sprite=graphicsId, graphicsId=graphicsId,
        elevation=engine.elevationAt and engine.elevationAt(x, y) or 3,
        currentElevation=engine.elevationAt and engine.elevationAt(x, y) or 3,
        movementType=0x09, movement="STAY", range="DOWN",
        radius={x=0,y=0}, rangeX=0, rangeY=0,
        visible=true, hidden=false, invisible=false, frozen=true,
        passable=false, moving=false, progress=0, stepFrames=16,
        scriptBusy=false, _uadvIdleSheet=sheet, _uadvIdleRow=row, _uadvIdleTick=0,
        def={ localId=DARKRAI_NPC_ID, x=x, y=y, graphicsId=graphicsId,
          movementType=0x09, facing="down" },
      }
      Objects._byId[DARKRAI_NPC_ID] = actor
      Objects._order[#Objects._order + 1] = DARKRAI_NPC_ID
      towerActor = actor
    end

    local function triggerDarkraiScene()
      if not towerActor or not towerActor.active or darkraiSceneBusy then return false end
      local session = engine.Runtime.getSession()
      if not session or session.map ~= TOWER_7F then return false end
      local P = engine.Player
      -- Trigger one tile before Darkrai instead of requiring interaction/collision.
      if P.cellX ~= 11 or P.cellY ~= 5 then return false end

      local Message = require("src.ui.game3.message")
      local Fade = require("src.ui.game3.fade")
      darkraiSceneBusy = true
      engine.Field.locked = true
      P.facing = "up"

      Message.show("A cold presence hangs in the air...", function()
        Message.show("You suddenly feel very tired...", function()
          Fade.begin(Fade.MODE.TO_BLACK, 1, function()
            clearTowerActor()
            local state = darkraiState(session)
            state.darkraiTowerTriggered = true
            addDarkraiRoamer(session)
            Fade.begin(Fade.MODE.FROM_BLACK, 1, function()
              Message.show("The POKEMON vanished!", function()
                engine.Field.locked = false
                darkraiSceneBusy = false
              end)
            end)
          end)
        end)
      end)
      return true
    end


    mod.events:on("map.entered", function()
      local session = engine.Runtime and engine.Runtime.getSession and engine.Runtime.getSession()
      if session and session.map == CRESSELIA_MAP then
        eventState(session).cresseliaAttemptedThisVisit = false
      end
      showTowerDarkrai()
      showCresselia()
    end)

    mod.events:on("world.stepped", function()
      showTowerDarkrai()
      triggerDarkraiScene()
      showCresselia()
      triggerCresseliaScene()
    end)

    installed = true
    mod.log:info("Darkrai + Cresselia Events installed")
    return true
  end

  mod.events:on("game.ready", install, -40)
end
