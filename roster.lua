local data = require('data');

local roster = {};

local function partyApi()
    return AshitaCore:GetMemoryManager():GetParty();
end

local function memberFromSlot(partyMemory, slot)
    return data.buildMember(
        partyMemory:GetMemberName(slot),
        partyMemory:GetMemberZone(slot),
        partyMemory:GetMemberMainJob(slot),
        partyMemory:GetMemberSubJob(slot),
        partyMemory:GetMemberMainJobLevel(slot),
        partyMemory:GetMemberSubJobLevel(slot)
    );
end

function roster.leaderName()
    return partyApi():GetMemberName(0);
end

function roster.leaderZoneId()
    return partyApi():GetMemberZone(0);
end

function roster.hasOtherMembers()
    local partyMemory = partyApi();
    for slot = 1, 17 do
        if partyMemory:GetMemberIsActive(slot) ~= 0 then
            return true;
        end
    end
    return false;
end

function roster.fromAlliance()
    local partyMemory = partyApi();
    local members = T{};

    for slot = 0, 17 do
        if partyMemory:GetMemberIsActive(slot) ~= 0 then
            members:append(memberFromSlot(partyMemory, slot));
        end
    end

    return members;
end

return roster;
