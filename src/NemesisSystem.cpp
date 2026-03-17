#include "AllCreatureScript.h"
#include "Config.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "Map.h"
#include "Player.h"
#include "ScriptMgr.h"

#include <algorithm>
#include <cstdint>
#include <unordered_map>

namespace
{
    struct NemesisState
    {
        uint8 rank = 1;
        uint32 affixMask = 0;
        uint32 targetGuid = 0;
    };

    using NemesisStore = std::unordered_map<ObjectGuid::LowType, NemesisState>;

    NemesisStore ActiveNemeses;

    bool IsEnabled()
    {
        return sConfigMgr->GetOption<bool>("NemesisSystem.Enable", true);
    }

    uint8 GetMaxRank()
    {
        return std::max<uint8>(1, sConfigMgr->GetOption<uint8>("NemesisSystem.MaxRank", 5));
    }

    uint8 GetTrivialKillLevelDelta()
    {
        return sConfigMgr->GetOption<uint8>("NemesisSystem.TrivialKillLevelDelta", 5);
    }

    uint32 GetVisualAuraSpell()
    {
        return sConfigMgr->GetOption<uint32>("NemesisSystem.VisualAuraSpell", 0);
    }

    float GetScaleMultiplier(uint8 rank)
    {
        switch (rank)
        {
            case 1: return 1.20f;
            case 2: return 1.30f;
            case 3: return 1.40f;
            case 4: return 1.50f;
            default: return 1.60f;
        }
    }

    float GetHealthMultiplier(uint8 rank)
    {
        switch (rank)
        {
            case 1: return 1.50f;
            case 2: return 2.00f;
            case 3: return 3.00f;
            case 4: return 4.50f;
            default: return 6.00f;
        }
    }

    bool LoadNemesisState(ObjectGuid::LowType spawnId, NemesisState& state)
    {
        if (!spawnId)
            return false;

        if (NemesisStore::const_iterator itr = ActiveNemeses.find(spawnId); itr != ActiveNemeses.end())
        {
            state = itr->second;
            return true;
        }

        QueryResult result = CharacterDatabase.Query(
            "SELECT `rank`, `affix_mask`, `nemesis_target_guid` FROM `character_nemesis` WHERE `guid` = {}",
            uint64(spawnId));
        if (!result)
            return false;

        Field* fields = result->Fetch();
        state.rank = fields[0].Get<uint8>();
        state.affixMask = fields[1].Get<uint32>();
        state.targetGuid = fields[2].Get<uint32>();
        ActiveNemeses[spawnId] = state;
        return true;
    }

    void SaveNemesisState(Creature* creature, NemesisState const& state)
    {
        float homeX = 0.0f;
        float homeY = 0.0f;
        float homeZ = 0.0f;
        float orientation = 0.0f;
        creature->GetHomePosition(homeX, homeY, homeZ, orientation);

        CharacterDatabase.Execute(
            "REPLACE INTO `character_nemesis` "
            "(`guid`, `creature_entry`, `map_id`, `pos_x`, `pos_y`, `pos_z`, `rank`, `affix_mask`, `nemesis_target_guid`) "
            "VALUES ({}, {}, {}, {}, {}, {}, {}, {}, {})",
            uint64(creature->GetSpawnId()),
            creature->GetEntry(),
            creature->GetMapId(),
            homeX,
            homeY,
            homeZ,
            state.rank,
            state.affixMask,
            state.targetGuid);

        ActiveNemeses[creature->GetSpawnId()] = state;
    }

    void DeleteNemesisState(ObjectGuid::LowType spawnId)
    {
        if (!spawnId)
            return;

        ActiveNemeses.erase(spawnId);
        CharacterDatabase.Execute("DELETE FROM `character_nemesis` WHERE `guid` = {}", uint64(spawnId));
    }

    bool IsEligibleNemesisKill(Creature* killer, Player* killed)
    {
        if (!IsEnabled() || !killer || !killed)
            return false;

        if (!killer->IsInWorld() || !killer->GetSpawnId())
            return false;

        Map* map = killer->GetMap();
        if (!map || map->IsDungeon() || map->IsBattlegroundOrArena() || map->IsRaid())
            return false;

        if (killer->IsPet())
            return false;

        if ((killer->GetLevel() + GetTrivialKillLevelDelta()) < killed->GetLevel())
            return false;

        return true;
    }

    void ApplyNemesisState(Creature* creature, NemesisState const& state)
    {
        if (!creature)
            return;

        uint32 const baseHealth = std::max<uint32>(1, creature->GetCreateHealth());
        uint32 const scaledHealth = uint32(float(baseHealth) * GetHealthMultiplier(state.rank));

        creature->SetObjectScale(creature->GetNativeObjectScale() * GetScaleMultiplier(state.rank));
        creature->SetCreateHealth(scaledHealth);
        creature->SetMaxHealth(scaledHealth);
        creature->SetHealth(std::min<uint32>(creature->GetHealth(), scaledHealth));

        if (creature->IsAlive())
            creature->SetHealth(scaledHealth);

        if (uint32 auraSpell = GetVisualAuraSpell())
            if (!creature->HasAura(auraSpell))
                creature->AddAura(auraSpell, creature);
    }

    void PromoteNemesis(Creature* killer, Player* killed)
    {
        NemesisState state;
        if (LoadNemesisState(killer->GetSpawnId(), state))
        {
            if (state.rank < GetMaxRank())
                ++state.rank;
        }
        else
        {
            state.rank = 1;
            state.affixMask = 0;
            state.targetGuid = killed->GetGUID().GetCounter();
        }

        SaveNemesisState(killer, state);
        ApplyNemesisState(killer, state);
        killer->SetFullHealth();
    }
}

class NemesisSystemPlayerScript : public PlayerScript
{
public:
    NemesisSystemPlayerScript() : PlayerScript("NemesisSystemPlayerScript", { PLAYERHOOK_ON_PLAYER_KILLED_BY_CREATURE }) { }

    void OnPlayerKilledByCreature(Creature* killer, Player* killed) override
    {
        if (!IsEligibleNemesisKill(killer, killed))
            return;

        PromoteNemesis(killer, killed);
    }
};

class NemesisSystemAllCreatureScript : public AllCreatureScript
{
public:
    NemesisSystemAllCreatureScript() : AllCreatureScript("NemesisSystemAllCreatureScript") { }

    void OnCreatureAddWorld(Creature* creature) override
    {
        NemesisState state;
        if (!LoadNemesisState(creature->GetSpawnId(), state))
            return;

        ApplyNemesisState(creature, state);
    }

    void OnAllCreatureUpdate(Creature* creature, uint32 /*diff*/) override
    {
        if (!creature)
            return;

        NemesisStore::const_iterator itr = ActiveNemeses.find(creature->GetSpawnId());
        if (itr == ActiveNemeses.end())
            return;

        if (creature->IsAlive())
            return;

        DeleteNemesisState(creature->GetSpawnId());
    }
};

void AddSC_mod_nemesis_system()
{
    new NemesisSystemPlayerScript();
    new NemesisSystemAllCreatureScript();
}