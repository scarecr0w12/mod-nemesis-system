#include "AllCreatureScript.h"
#include "Config.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "GameTime.h"
#include "Group.h"
#include "Map.h"
#include "ObjectGuid.h"
#include "Player.h"
#include "Random.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "UnitScript.h"

#include <algorithm>
#include <array>
#include <bit>
#include <unordered_map>

namespace
{
    enum NemesisAffix : uint32
    {
        NEMESIS_AFFIX_VAMPIRIC   = 1 << 0,
        NEMESIS_AFFIX_SWIFT      = 1 << 1,
        NEMESIS_AFFIX_JUGGERNAUT = 1 << 2,
    };

    struct NemesisState
    {
        uint8 rank = 1;
        uint32 affixMask = 0;
        uint32 baseHealth = 1;
        float baseScale = 1.0f;
        float baseMeleeMinDamage = BASE_MINDAMAGE;
        float baseMeleeMaxDamage = BASE_MAXDAMAGE;
        float baseRangedMinDamage = 0.0f;
        float baseRangedMaxDamage = 0.0f;
        uint32 baseAttackTime = BASE_ATTACK_TIME;
        uint32 baseRangeAttackTime = BASE_ATTACK_TIME;
        float baseRunSpeedRate = 1.0f;
        uint32 targetGuid = 0;
        uint32 createdAt = 0;
    };

    using NemesisStore = std::unordered_map<ObjectGuid::LowType, NemesisState>;

    NemesisStore ActiveNemeses;
    bool CacheLoaded = false;

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

    uint32 GetDecayHours()
    {
        return sConfigMgr->GetOption<uint32>("NemesisSystem.DecayHours", 48);
    }

    uint32 GetRewardItem(bool revenge)
    {
        return sConfigMgr->GetOption<uint32>(revenge ? "NemesisSystem.RevengeRewardItem" : "NemesisSystem.BountyRewardItem", 0);
    }

    uint32 GetRewardCount(bool revenge)
    {
        return std::max<uint32>(1, sConfigMgr->GetOption<uint32>(revenge ? "NemesisSystem.RevengeRewardCount" : "NemesisSystem.BountyRewardCount", 1));
    }

    uint32 GetRewardGold(bool revenge)
    {
        return sConfigMgr->GetOption<uint32>(revenge ? "NemesisSystem.RevengeRewardGold" : "NemesisSystem.BountyRewardGold", revenge ? 10000 : 2500);
    }

    uint32 GetVisualAuraSpell()
    {
        return sConfigMgr->GetOption<uint32>("NemesisSystem.VisualAuraSpell", 0);
    }

    bool HasAffix(NemesisState const& state, NemesisAffix affix)
    {
        return (state.affixMask & affix) != 0;
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

    float GetDamageMultiplier(uint8 rank)
    {
        return GetHealthMultiplier(rank);
    }

    float GetVampiricHealPct()
    {
        return 0.50f;
    }

    float GetSwiftSpeedMultiplier()
    {
        return 1.50f;
    }

    float GetSwiftAttackTimeMultiplier()
    {
        return 0.70f;
    }

    bool IsExpired(NemesisState const& state)
    {
        uint32 const decayHours = GetDecayHours();
        if (!decayHours || !state.createdAt)
            return false;

        return state.createdAt + (decayHours * 60u * 60u) < uint32(GameTime::GetGameTime().count());
    }

    void EnsureCacheLoaded()
    {
        if (CacheLoaded)
            return;

        CacheLoaded = true;

        QueryResult result = CharacterDatabase.Query(
            "SELECT `guid`, `rank`, `affix_mask`, `base_health`, `base_scale`, `base_melee_min_damage`, "
            "`base_melee_max_damage`, `base_ranged_min_damage`, `base_ranged_max_damage`, `base_attack_time`, `base_range_attack_time`, `base_run_speed_rate`, `nemesis_target_guid`, "
            "UNIX_TIMESTAMP(`creation_date`) FROM `character_nemesis`");
        if (!result)
            return;

        do
        {
            Field* fields = result->Fetch();

            ObjectGuid::LowType const spawnId = fields[0].Get<uint64>();

            NemesisState state;
            state.rank = fields[1].Get<uint8>();
            state.affixMask = fields[2].Get<uint32>();
            state.baseHealth = fields[3].Get<uint32>();
            state.baseScale = fields[4].Get<float>();
            state.baseMeleeMinDamage = fields[5].Get<float>();
            state.baseMeleeMaxDamage = fields[6].Get<float>();
            state.baseRangedMinDamage = fields[7].Get<float>();
            state.baseRangedMaxDamage = fields[8].Get<float>();
            state.baseAttackTime = fields[9].Get<uint32>();
            state.baseRangeAttackTime = fields[10].Get<uint32>();
            state.baseRunSpeedRate = fields[11].Get<float>();
            state.targetGuid = fields[12].Get<uint32>();
            state.createdAt = fields[13].Get<uint32>();

            if (IsExpired(state))
            {
                CharacterDatabase.Execute("DELETE FROM `character_nemesis` WHERE `guid` = {}", uint64(spawnId));
                continue;
            }

            ActiveNemeses[spawnId] = state;
        }
        while (result->NextRow());
    }

    bool TryGetNemesisState(ObjectGuid::LowType spawnId, NemesisState& state)
    {
        if (!spawnId)
            return false;

        EnsureCacheLoaded();

        NemesisStore::iterator itr = ActiveNemeses.find(spawnId);
        if (itr == ActiveNemeses.end())
            return false;

        if (IsExpired(itr->second))
        {
            CharacterDatabase.Execute("DELETE FROM `character_nemesis` WHERE `guid` = {}", uint64(spawnId));
            ActiveNemeses.erase(itr);
            return false;
        }

        state = itr->second;
        return true;
    }

    void SaveNemesisState(Creature* creature, NemesisState const& state)
    {
        EnsureCacheLoaded();

        float homeX = 0.0f;
        float homeY = 0.0f;
        float homeZ = 0.0f;
        float orientation = 0.0f;
        creature->GetHomePosition(homeX, homeY, homeZ, orientation);

        CharacterDatabase.Execute(
            "REPLACE INTO `character_nemesis` "
            "(`guid`, `creature_entry`, `map_id`, `pos_x`, `pos_y`, `pos_z`, `rank`, `affix_mask`, `base_health`, `base_scale`, "
            "`base_melee_min_damage`, `base_melee_max_damage`, `base_ranged_min_damage`, `base_ranged_max_damage`, `base_attack_time`, `base_range_attack_time`, `base_run_speed_rate`, `nemesis_target_guid`, `creation_date`) "
            "VALUES ({}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}, FROM_UNIXTIME({}))",
            uint64(creature->GetSpawnId()),
            creature->GetEntry(),
            creature->GetMapId(),
            homeX,
            homeY,
            homeZ,
            state.rank,
            state.affixMask,
            state.baseHealth,
            state.baseScale,
            state.baseMeleeMinDamage,
            state.baseMeleeMaxDamage,
            state.baseRangedMinDamage,
            state.baseRangedMaxDamage,
            state.baseAttackTime,
            state.baseRangeAttackTime,
            state.baseRunSpeedRate,
            state.targetGuid,
            state.createdAt ? state.createdAt : uint32(GameTime::GetGameTime().count()));

        ActiveNemeses[creature->GetSpawnId()] = state;
    }

    void DeleteNemesisState(ObjectGuid::LowType spawnId)
    {
        if (!spawnId)
            return;

        EnsureCacheLoaded();

        ActiveNemeses.erase(spawnId);
        CharacterDatabase.Execute("DELETE FROM `character_nemesis` WHERE `guid` = {}", uint64(spawnId));
    }

    NemesisState BuildInitialNemesisState(Creature* killer, Player* killed)
    {
        NemesisState state;
        state.rank = 1;
        state.affixMask = 0;
        state.baseHealth = std::max<uint32>(1, killer->GetCreateHealth());
        state.baseScale = killer->GetNativeObjectScale();
        state.baseMeleeMinDamage = std::max<float>(BASE_MINDAMAGE, killer->GetWeaponDamageRange(BASE_ATTACK, MINDAMAGE, 0));
        state.baseMeleeMaxDamage = std::max<float>(BASE_MAXDAMAGE, killer->GetWeaponDamageRange(BASE_ATTACK, MAXDAMAGE, 0));
        state.baseRangedMinDamage = std::max<float>(0.0f, killer->GetWeaponDamageRange(RANGED_ATTACK, MINDAMAGE, 0));
        state.baseRangedMaxDamage = std::max<float>(0.0f, killer->GetWeaponDamageRange(RANGED_ATTACK, MAXDAMAGE, 0));
        state.baseAttackTime = killer->GetCreatureTemplate()->BaseAttackTime;
        state.baseRangeAttackTime = killer->GetCreatureTemplate()->RangeAttackTime;
        state.baseRunSpeedRate = killer->GetSpeedRate(MOVE_RUN);
        state.targetGuid = killed->GetGUID().GetCounter();
        state.createdAt = uint32(GameTime::GetGameTime().count());
        return state;
    }

    void RollAffixes(NemesisState& state)
    {
        std::array<uint32, 3> const affixes = { NEMESIS_AFFIX_VAMPIRIC, NEMESIS_AFFIX_SWIFT, NEMESIS_AFFIX_JUGGERNAUT };
        uint32 affixMask = state.affixMask;
        uint32 const desiredAffixCount = state.rank >= 3 ? 2u : 1u;

        while (std::popcount(affixMask) < desiredAffixCount)
            affixMask |= affixes[urand(0, affixes.size() - 1)];

        state.affixMask = affixMask;
    }

    void ApplyJuggernautImmunity(Creature* creature)
    {
        uint32 const placeholderId = 0;

        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_SNARE, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_ROOT, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_FEAR, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_STUN, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_SLEEP, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_CHARM, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_SAPPED, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_POLYMORPH, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_DISORIENTED, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_FREEZE, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_HORROR, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_MECHANIC, MECHANIC_BANISH, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_EFFECT, SPELL_EFFECT_KNOCK_BACK, true);
        creature->ApplySpellImmune(placeholderId, IMMUNITY_EFFECT, SPELL_EFFECT_KNOCK_BACK_DEST, true);
    }

    bool IsRevengeKill(Player* killer, NemesisState const& state)
    {
        if (!killer)
            return false;

        if (killer->GetGUID().GetCounter() == state.targetGuid)
            return true;

        Group* group = killer->GetGroup();
        if (!group)
            return false;

        return group->IsMember(ObjectGuid::Create<HighGuid::Player>(state.targetGuid));
    }

    void GrantReward(Player* player, bool revenge)
    {
        if (!player)
            return;

        if (uint32 itemId = GetRewardItem(revenge))
            player->AddItem(itemId, GetRewardCount(revenge));

        if (uint32 gold = GetRewardGold(revenge))
            player->ModifyMoney(int32(gold), true);
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

        if (killed->IsInSanctuary())
            return false;

        if (killer->IsPet() || killer->IsCritter())
            return false;

        if (killer->isWorldBoss() || killer->IsDungeonBoss())
            return false;

        if (killer->GetCreatureTemplate()->rank == CREATURE_ELITE_WORLDBOSS)
            return false;

        if ((killer->GetLevel() + GetTrivialKillLevelDelta()) < killed->GetLevel())
            return false;

        return true;
    }

    void ApplyNemesisState(Creature* creature, NemesisState const& state)
    {
        if (!creature)
            return;

        uint32 const scaledHealth = std::max<uint32>(1, uint32(float(state.baseHealth) * GetHealthMultiplier(state.rank)));
        float const meleeMinDamage = std::max<float>(BASE_MINDAMAGE, state.baseMeleeMinDamage * GetDamageMultiplier(state.rank));
        float const meleeMaxDamage = std::max<float>(BASE_MAXDAMAGE, state.baseMeleeMaxDamage * GetDamageMultiplier(state.rank));
        float const rangedMinDamage = std::max<float>(0.0f, state.baseRangedMinDamage * GetDamageMultiplier(state.rank));
        float const rangedMaxDamage = std::max<float>(0.0f, state.baseRangedMaxDamage * GetDamageMultiplier(state.rank));

        creature->SetObjectScale(state.baseScale * GetScaleMultiplier(state.rank));
        creature->SetCreateHealth(scaledHealth);
        creature->SetStatFlatModifier(UNIT_MOD_HEALTH, BASE_VALUE, float(scaledHealth));
        creature->SetMaxHealth(scaledHealth);
        creature->SetBaseWeaponDamage(BASE_ATTACK, MINDAMAGE, meleeMinDamage, 0);
        creature->SetBaseWeaponDamage(BASE_ATTACK, MAXDAMAGE, meleeMaxDamage, 0);
        creature->SetBaseWeaponDamage(OFF_ATTACK, MINDAMAGE, meleeMinDamage, 0);
        creature->SetBaseWeaponDamage(OFF_ATTACK, MAXDAMAGE, meleeMaxDamage, 0);
        creature->SetAttackTime(BASE_ATTACK, state.baseAttackTime);
        creature->SetAttackTime(OFF_ATTACK, state.baseAttackTime);
        creature->SetAttackTime(RANGED_ATTACK, state.baseRangeAttackTime);

        if (state.baseRangedMinDamage > 0.0f || state.baseRangedMaxDamage > 0.0f)
        {
            creature->SetBaseWeaponDamage(RANGED_ATTACK, MINDAMAGE, rangedMinDamage, 0);
            creature->SetBaseWeaponDamage(RANGED_ATTACK, MAXDAMAGE, rangedMaxDamage, 0);
        }

        creature->SetSpeedRate(MOVE_RUN, state.baseRunSpeedRate);
        creature->UpdateSpeed(MOVE_RUN, true);

        if (HasAffix(state, NEMESIS_AFFIX_SWIFT))
        {
            creature->SetSpeedRate(MOVE_RUN, state.baseRunSpeedRate * GetSwiftSpeedMultiplier());
            creature->UpdateSpeed(MOVE_RUN, true);
            creature->SetAttackTime(BASE_ATTACK, uint32(float(state.baseAttackTime) * GetSwiftAttackTimeMultiplier()));
            creature->SetAttackTime(OFF_ATTACK, uint32(float(state.baseAttackTime) * GetSwiftAttackTimeMultiplier()));
            creature->SetAttackTime(RANGED_ATTACK, uint32(float(state.baseRangeAttackTime) * GetSwiftAttackTimeMultiplier()));
        }

        if (HasAffix(state, NEMESIS_AFFIX_JUGGERNAUT))
            ApplyJuggernautImmunity(creature);

        creature->UpdateAllStats();
        creature->SetMaxHealth(scaledHealth);

        if (creature->IsAlive())
            creature->SetHealth(scaledHealth);
        else
            creature->SetHealth(std::min<uint32>(creature->GetHealth(), scaledHealth));

        if (uint32 auraSpell = GetVisualAuraSpell())
            if (!creature->HasAura(auraSpell))
                creature->AddAura(auraSpell, creature);
    }

    void PromoteNemesis(Creature* killer, Player* killed)
    {
        NemesisState state;
        if (TryGetNemesisState(killer->GetSpawnId(), state))
        {
            if (state.rank < GetMaxRank())
                ++state.rank;
        }
        else
            state = BuildInitialNemesisState(killer, killed);

        RollAffixes(state);

        SaveNemesisState(killer, state);
        ApplyNemesisState(killer, state);
        killer->SetFullHealth();
    }
}

class NemesisSystemPlayerScript : public PlayerScript
{
public:
    NemesisSystemPlayerScript() : PlayerScript("NemesisSystemPlayerScript", { PLAYERHOOK_ON_PLAYER_KILLED_BY_CREATURE, PLAYERHOOK_ON_CREATURE_KILL, PLAYERHOOK_ON_CREATURE_KILLED_BY_PET }) { }

    void OnPlayerKilledByCreature(Creature* killer, Player* killed) override
    {
        if (!IsEligibleNemesisKill(killer, killed))
            return;

        PromoteNemesis(killer, killed);
    }

    void OnPlayerCreatureKill(Player* killer, Creature* killed) override
    {
        if (!killer || !killed)
            return;

        NemesisState state;
        if (!TryGetNemesisState(killed->GetSpawnId(), state))
            return;

        GrantReward(killer, IsRevengeKill(killer, state));
    }

    void OnPlayerCreatureKilledByPet(Player* owner, Creature* killed) override
    {
        OnPlayerCreatureKill(owner, killed);
    }
};

class NemesisSystemAllCreatureScript : public AllCreatureScript
{
public:
    NemesisSystemAllCreatureScript() : AllCreatureScript("NemesisSystemAllCreatureScript") { }

    void OnCreatureAddWorld(Creature* creature) override
    {
        NemesisState state;
        if (!TryGetNemesisState(creature->GetSpawnId(), state))
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

class NemesisSystemUnitScript : public UnitScript
{
public:
    NemesisSystemUnitScript() : UnitScript("NemesisSystemUnitScript", true, { UNITHOOK_ON_DAMAGE }) { }

    void OnDamage(Unit* attacker, Unit* /*victim*/, uint32& damage) override
    {
        if (!attacker || !damage || !attacker->IsCreature())
            return;

        Creature* creature = attacker->ToCreature();

        NemesisState state;
        if (!TryGetNemesisState(creature->GetSpawnId(), state))
            return;

        if (!HasAffix(state, NEMESIS_AFFIX_VAMPIRIC))
            return;

        uint32 healAmount = std::max<uint32>(1, uint32(float(damage) * GetVampiricHealPct()));
        creature->ModifyHealth(int32(healAmount));
    }
};

void AddSC_mod_nemesis_system()
{
    new NemesisSystemPlayerScript();
    new NemesisSystemAllCreatureScript();
    new NemesisSystemUnitScript();
}