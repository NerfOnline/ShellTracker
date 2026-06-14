local data = require('data');
local roster = require('roster');
local settings = require('settings');

local linkshell = {};

linkshell.failure = {
    empty = 'empty',
    emptyZone = 'emptyZone',
    solo = 'solo',
    bufferEmpty = 'bufferEmpty',
};

linkshell.source = {
    roster = 'roster',
    sea = 'sea',
};

local failureReasons = linkshell.failure;
local readSources = linkshell.source;
local memoryLayout = settings.rosterMemory;
local managerOffsets = memoryLayout.manager;
local menuPattern = '8B480C85C974??8B510885D274??3B05';
local menuAnchor = nil;
local rosterMenuTags = {
    link3 = true,
    link5 = true,
    link12 = true,
    link13 = true,
};
local searchResultMenuTag = 'scresult';
local searchResultMaxRows = 40;

local function byteAt(address)
    return ashita.memory.read_uint8(address);
end

local function dwordAt(address)
    return ashita.memory.read_uint32(address);
end

local function intAt(address)
    return ashita.memory.read_int32(address);
end

local function textAt(address, length)
    return ashita.memory.read_string(address, length);
end

local function trimMemoryText(value)
    if value == nil then
        return '';
    end
    return tostring(value):gsub('%z+$', ''):gsub('[\r\n]+', ''):gsub('^%s+', ''):gsub('%s+$', '');
end

local function isUiCountToken(value)
    return tostring(value or ''):match('^%[%d+%]$') ~= nil;
end

local function isCharacterName(value)
    value = tostring(value or '');
    if #value < 2 or #value > 15 or isUiCountToken(value) then
        return false;
    end
    if value:find('[%z\001-\008\011\012\014-\031\127-\255]') then
        return false;
    end
    return value:match('^[%a_][%a%d_]*$') ~= nil;
end

local function normalizeMenuTag(rawName)
    if rawName == nil or rawName == '' then
        return '';
    end
    local trimmed = rawName:gsub('\0', ''):gsub('%s+$', '');
    if #trimmed <= 8 then
        return trimmed:gsub(' ', '');
    end
    return trimmed:sub(9):gsub(' ', '');
end

local function activeMenuTag()
    if menuAnchor == nil then
        menuAnchor = ashita.memory.find('FFXiMain.dll', 0, menuPattern, 16, 0);
    end
    if menuAnchor == nil or menuAnchor == 0 then
        menuAnchor = nil;
        return '';
    end

    local root = ashita.memory.read_uint32(menuAnchor);
    if root == 0 then
        return '';
    end

    local chain = ashita.memory.read_uint32(root);
    if chain == 0 then
        return '';
    end

    local header = ashita.memory.read_uint32(chain + 4);
    if header == 0 then
        return '';
    end

    return normalizeMenuTag(ashita.memory.read_string(header + 0x46, 16));
end

local function isLinkshellRosterMenu()
    local tag = activeMenuTag();
    if tag == '' then
        return false;
    end
    if rosterMenuTags[tag] then
        return true;
    end
    return tag:match('^link') ~= nil;
end

local function isSearchResultMenu()
    return activeMenuTag() == searchResultMenuTag;
end

function linkshell.isRosterMenuOpen()
    return isLinkshellRosterMenu();
end

function linkshell.leaderZoneName()
    return data.zoneName(roster.leaderZoneId());
end

function linkshell.scopeLabel(allZones)
    return allZones and 'full roster' or linkshell.leaderZoneName();
end

function linkshell.seaCommand(shellKey, allZones)
    return allZones and ('/sea all ' .. shellKey) or ('/sea ' .. shellKey);
end

function linkshell.pollTiming()
    return {
        delay = settings.rosterPollDelay,
        rosterTimeout = settings.rosterPollTimeout,
        seaTimeout = settings.seaPollTimeout,
    };
end

local function readRowName(rowAddress)
    for _, offset in ipairs(memoryLayout.fields.name.offsets) do
        for _, length in ipairs(memoryLayout.fields.name.lengths) do
            local candidate = trimMemoryText(textAt(rowAddress + offset, length));
            if candidate ~= '' then
                return candidate;
            end
        end
    end
    return '';
end

local function strideFieldLayout(spacing)
    return memoryLayout.strideFields[spacing] or memoryLayout.strideFields[memoryLayout.rowSpacings[1]];
end

local function skipUiRow(name, zoneId, mainJobId, subJobId)
    if isUiCountToken(name) then
        return true;
    end
    return name == '' and zoneId == 0 and mainJobId == 0 and subJobId == 0;
end

local function parseStrideRow(rowAddress, spacing)
    local fields = strideFieldLayout(spacing);
    local name = readRowName(rowAddress);
    local zoneId = byteAt(rowAddress + fields.zone);
    local mainJobId = byteAt(rowAddress + fields.mainJob);
    local subJobId = byteAt(rowAddress + fields.subJob);

    if skipUiRow(name, zoneId, mainJobId, subJobId) or not isCharacterName(name) then
        return nil;
    end

    return data.buildMember(
        name,
        zoneId,
        mainJobId,
        subJobId,
        byteAt(rowAddress + fields.mainLevel),
        byteAt(rowAddress + fields.subLevel)
    );
end

local function mainModuleBase()
    local base = ashita.memory.find('FFXiMain.dll', 0, memoryLayout.modulePattern, 0, 0);
    return base ~= 0 and base or 0x400000;
end

local function locateResultTable()
    local base = mainModuleBase();

    for _, pointerOffset in ipairs(memoryLayout.serverPointers) do
        local manager = dwordAt(base + pointerOffset);
        if manager ~= 0 then
            local rowCount = dwordAt(manager + managerOffsets.count);
            local rows = dwordAt(manager + managerOffsets.rows);
            if rows ~= 0 and rowCount > 0 and rowCount <= memoryLayout.maxRows then
                return rows, rowCount;
            end
        end
    end

    return 0, 0;
end

local function pickRowSpacing(rowCount, rows)
    local spacing = memoryLayout.rowSpacings[1];
    local bestScore = -1;

    for _, candidate in ipairs(memoryLayout.rowSpacings) do
        local seen = {};
        local score = 0;

        for index = 0, math.max(rowCount - 1, 0) do
            local name = readRowName(rows + (index * candidate));
            if isCharacterName(name) and seen[name] == nil then
                seen[name] = true;
                score = score + 1;
            end
        end

        if score > bestScore then
            bestScore = score;
            spacing = candidate;
        end
    end

    return spacing;
end

local function appendUnique(players, seen, player)
    if player == nil or seen[player.name] then
        return;
    end
    seen[player.name] = true;
    players:append(player);
end

local function gatherStrideRows(rows, rowCount, spacing)
    local players = T{};
    local seen = {};

    for index = 0, rowCount + 1 do
        appendUnique(players, seen, parseStrideRow(rows + (index * spacing), spacing));
    end

    return #players > 0 and players or nil;
end

local function parseRetailRow(rowAddress)
    local rowLayout = memoryLayout.retailRow;
    local payload = rowAddress + rowLayout.headerSkip;
    local name = trimMemoryText(textAt(payload + rowLayout.name, rowLayout.nameLength));
    if not isCharacterName(name) then
        return nil;
    end

    return data.buildMember(
        name,
        byteAt(payload + rowLayout.zone),
        byteAt(payload + rowLayout.mainJob),
        byteAt(payload + rowLayout.subJob),
        byteAt(payload + rowLayout.mainLevel),
        byteAt(payload + rowLayout.subLevel)
    );
end

local function readRetailBuffer()
    local anchor = ashita.memory.find('FFXiMain.dll', 0, '??', memoryLayout.retailAnchor, 0);
    if anchor == 0 then
        return nil;
    end

    local manager = intAt(anchor);
    if manager == 0 then
        return nil;
    end

    local rowCount = intAt(manager + managerOffsets.count);
    if rowCount <= 0 or rowCount > memoryLayout.retailMaxRows then
        return nil;
    end

    local rows = intAt(manager + managerOffsets.rows);
    if rows == 0 then
        return nil;
    end

    return { rows = rows, rowCount = rowCount };
end

local function readRetailResults(retailBuffer)
    if retailBuffer == nil then
        return nil;
    end

    local players = T{};
    local seen = {};

    for index = 0, retailBuffer.rowCount - 1 do
        appendUnique(players, seen, parseRetailRow(retailBuffer.rows + (index * memoryLayout.retailRowSize)));
    end

    return #players > 0 and players or nil;
end

local function readStrideResults(strideRows, strideRowCount)
    if strideRows == 0 then
        return nil;
    end
    return gatherStrideRows(strideRows, strideRowCount, pickRowSpacing(strideRowCount, strideRows));
end

local function buildMemorySnapshot()
    local retailBuffer = readRetailBuffer();
    local strideRows, strideRowCount = locateResultTable();
    local rowCount = retailBuffer ~= nil and retailBuffer.rowCount or strideRowCount;
    local players = readRetailResults(retailBuffer) or readStrideResults(strideRows, strideRowCount);

    return {
        rowCount = rowCount,
        players = players,
        isEmpty = rowCount <= 0 and players == nil,
    };
end

local function looksLikeRosterBuffer(snapshot)
    return snapshot.rowCount > searchResultMaxRows;
end

local function looksLikeSearchBuffer(snapshot)
    if looksLikeRosterBuffer(snapshot) then
        return false;
    end
    return snapshot.players ~= nil and #snapshot.players > 0;
end

local function canAcceptBuffer(source, snapshot)
    if source == readSources.roster then
        if isSearchResultMenu() then
            return false;
        end
        return isLinkshellRosterMenu() or looksLikeRosterBuffer(snapshot);
    end

    if source == readSources.sea then
        if isSearchResultMenu() then
            return true;
        end
        return looksLikeSearchBuffer(snapshot);
    end

    return false;
end

local function isOnlyLeader(members)
    return #members == 1 and members[1].name == roster.leaderName();
end

local function filterByZone(players)
    local zoneId = roster.leaderZoneId();
    local zoneName = data.zoneName(zoneId);
    local filtered = T{};

    for _, player in ipairs(players) do
        if player.zoneId == zoneId then
            filtered:append(player);
        end
    end

    if #filtered == 0 then
        return nil, zoneName, failureReasons.emptyZone;
    end
    if isOnlyLeader(filtered) then
        return nil, zoneName, failureReasons.solo;
    end

    return filtered, zoneName, nil;
end

local function scopeMembers(players, allZones)
    if allZones then
        if #players == 0 or isOnlyLeader(players) then
            return nil, linkshell.scopeLabel(true), failureReasons.solo;
        end
        return players, linkshell.scopeLabel(true), nil;
    end
    return filterByZone(players);
end

function linkshell.readMembers(allZones, source)
    local snapshot = buildMemorySnapshot();
    local zoneName = linkshell.leaderZoneName();

    if source == readSources.roster and isLinkshellRosterMenu() and snapshot.isEmpty then
        return nil, zoneName, failureReasons.bufferEmpty;
    end
    if not canAcceptBuffer(source, snapshot) then
        return nil, zoneName, failureReasons.empty;
    end
    if snapshot.players == nil then
        return nil, zoneName, failureReasons.empty;
    end

    return scopeMembers(snapshot.players, allZones);
end

function linkshell.queueSeaSearch(shellKey, allZones)
    AshitaCore:GetChatManager():QueueCommand(1, linkshell.seaCommand(shellKey, allZones));
end

return linkshell;
