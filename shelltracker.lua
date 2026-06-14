addon.name      = 'ShellTracker';
addon.author    = 'NerfOnline';
addon.version   = '1.0';
addon.desc      = 'Creates a log file to track linkshell attendance and copies the list to clipboard';
addon.link      = 'https://github.com/NerfOnline/ShellTracker';

require('common');

local chat = require('chat');
local linkshell = require('linkshell');
local output = require('output');
local roster = require('roster');
local settings = require('settings');

settings.loadPersisted();

local activePoll = nil;
local pollPhaseDetect = 'detect';
local failureReasons = linkshell.failure;
local readSources = linkshell.source;

local messages = {
    menuClosed = 'Linkshell menu is closed. Now using `/sea` mode.',
    rosterFailed = 'Linkshell mode failed. Now using `/sea` mode.',
    searchFailed = 'Search mode failed. Please try again.',
    noPartyMembers = 'No party or alliance members found.',
};

local function buildNoLinkshellMembersMessage(shellKey, allZones, areaName)
    if allZones then
        return 'No `' .. shellKey .. '` member found in ' .. output.wrapAreaName('any zone') .. '.';
    end
    return 'No `' .. shellKey .. '` member found in ' .. output.wrapAreaName(areaName) .. '.';
end

local commandHelp = T{
    { '/st format', 'Toggle detailed log format (csv or txt).' },
    { '/st pt [detailed]', 'Log party and alliance members to file and clipboard.' },
    { '/st ls | ls2 [detailed] [all]', 'Log linkshell roster to file and clipboard.' },
    { 'detailed', 'Include job, time, and zone.' },
    { 'all', 'Include members in all zones, omit for current zone only.' },
};

local rateLimitByCommand = {};

output.setHeaderBuilder(function()
    return chat.header(addon.name);
end);

local function cancelActivePoll()
    activePoll = nil;
end

local function commandTextFromArgs(args)
    return table.concat(args, ' ');
end

local function rateLimitState(commandText)
    local state = rateLimitByCommand[commandText];
    if state == nil then
        state = { attempts = 0, blockedUntil = 0 };
        rateLimitByCommand[commandText] = state;
    end
    return state;
end

local function resetRateLimit(commandText)
    rateLimitByCommand[commandText] = nil;
end

local function recordCommandFailure(commandText)
    local state = rateLimitState(commandText);
    state.attempts = state.attempts + 1;
end

local function printRateLimitMessage(commandText, blockedUntil)
    local remainingSeconds = math.max(1, math.ceil(blockedUntil - os.clock()));
    output.printFailure(
        'Entered `' .. commandText .. '` too many times. Please wait '
            .. remainingSeconds
            .. ' seconds before trying again.'
    );
end

local function canStartCommand(commandText)
    local state = rateLimitState(commandText);
    local now = os.clock();

    if now < state.blockedUntil then
        printRateLimitMessage(commandText, state.blockedUntil);
        return false;
    end

    if state.blockedUntil > 0 then
        resetRateLimit(commandText);
        state = rateLimitState(commandText);
    end

    if state.attempts >= settings.commandRateLimitAttempts then
        state.blockedUntil = now + settings.commandRateLimitCooldown;
        state.attempts = 0;
        printRateLimitMessage(commandText, state.blockedUntil);
        return false;
    end

    return true;
end

local function showHelp()
    commandHelp:ieach(function(entry)
        output.printHelpLine(entry[1], entry[2]);
    end);
end

local function publishAttendance(members, detailed, summary)
    output.publishMembers(roster.leaderName(), members, detailed, summary);
end

local function saveAlliance(detailed, commandText)
    if not roster.hasOtherMembers() then
        recordCommandFailure(commandText);
        output.printFailure(messages.noPartyMembers);
        return;
    end
    local members = roster.fromAlliance();
    resetRateLimit(commandText);
    publishAttendance(members, detailed, 'Logged ' .. #members .. ' alliance members.');
end

local function buildLinkshellSummary(shellKey, memberCount, scopeLabel)
    local scopeText = scopeLabel == 'full roster' and scopeLabel or output.wrapAreaName(scopeLabel);
    return 'Logged ' .. memberCount .. ' ' .. shellKey .. ' members in ' .. scopeText .. '.';
end

local function completeLinkshellPoll(poll, members, scopeLabel, failureReason)
    if members ~= nil then
        resetRateLimit(poll.commandText);
        publishAttendance(members, poll.detailed, buildLinkshellSummary(poll.shell, #members, scopeLabel));
        cancelActivePoll();
        return true;
    end
    if failureReason == failureReasons.solo or failureReason == failureReasons.emptyZone then
        recordCommandFailure(poll.commandText);
        output.printFailure(buildNoLinkshellMembersMessage(poll.shell, poll.allZones, scopeLabel));
        cancelActivePoll();
        return true;
    end
    return false;
end

local function parseShellArgs(args)
    if #args < 2 then
        return nil;
    end

    local shellKey, detailed, allZones = nil, false, false;

    for index = 2, #args do
        local token = args[index];
        if token:any('ls2') then
            if shellKey ~= nil then return nil; end
            shellKey = 'linkshell2';
        elseif token:any('ls') then
            if shellKey ~= nil then return nil; end
            shellKey = 'linkshell';
        elseif token:any('detailed') then
            if detailed then return nil; end
            detailed = true;
        elseif token:any('all') then
            if allZones then return nil; end
            allZones = true;
        else
            return nil;
        end
    end

    if shellKey == nil then
        return nil;
    end

    return { shell = shellKey, detailed = detailed, allZones = allZones };
end

local function tryQueueSeaSearch(poll, infoMessage)
    if poll.seaSearchQueued then
        return true;
    end
    if linkshell.isRosterMenuOpen() then
        poll.pendingSeaMessage = infoMessage or messages.menuClosed;
        return false;
    end

    linkshell.queueSeaSearch(poll.shell, poll.allZones);
    poll.seaSearchQueued = true;
    poll.pendingSeaMessage = nil;
    output.printInfo(infoMessage or messages.menuClosed);
    return true;
end

local function beginSeaPoll(poll, infoMessage)
    local timing = linkshell.pollTiming();
    poll.phase = nil;
    poll.source = readSources.sea;
    poll.rosterPathActive = false;
    poll.expiresAt = os.clock() + timing.seaTimeout;
    tryQueueSeaSearch(poll, infoMessage);
end

local function beginRosterPoll(poll)
    local timing = linkshell.pollTiming();
    poll.phase = nil;
    poll.source = readSources.roster;
    poll.rosterPathActive = true;
    poll.rosterEmptyAfter = os.clock() + timing.delay;
    poll.expiresAt = os.clock() + timing.rosterTimeout;
end

local function finishLinkshellFailure(poll)
    recordCommandFailure(poll.commandText);
    cancelActivePoll();
    output.printFailure(messages.searchFailed);
end

local function startLinkshellRead(options, commandText)
    local timing = linkshell.pollTiming();
    activePoll = {
        shell = options.shell,
        detailed = options.detailed,
        allZones = options.allZones,
        commandText = commandText,
        phase = pollPhaseDetect,
        readyAt = os.clock() + timing.delay,
        rosterPathActive = false,
        seaSearchQueued = false,
        pendingSeaMessage = nil,
    };
end

local function tickLinkshellPoll()
    if activePoll == nil or os.clock() < activePoll.readyAt then
        return;
    end

    local poll = activePoll;

    if poll.phase == pollPhaseDetect then
        if linkshell.isRosterMenuOpen() then
            beginRosterPoll(poll);
        else
            beginSeaPoll(poll);
            return;
        end
    end

    if poll.source == readSources.sea and not poll.seaSearchQueued then
        if not tryQueueSeaSearch(poll, poll.pendingSeaMessage or messages.menuClosed) then
            return;
        end
    end

    local members, scopeLabel, failureReason = linkshell.readMembers(poll.allZones, poll.source);

    if failureReason == failureReasons.bufferEmpty
        and poll.rosterPathActive
        and os.clock() >= poll.rosterEmptyAfter
    then
        beginSeaPoll(poll, messages.rosterFailed);
        return;
    end

    if completeLinkshellPoll(poll, members, scopeLabel, failureReason) then
        return;
    end

    if os.clock() >= poll.expiresAt then
        if poll.source == readSources.roster and poll.rosterPathActive then
            beginSeaPoll(poll, messages.rosterFailed);
            return;
        end
        finishLinkshellFailure(poll);
    end
end

local function saveParty(args)
    if not args[2]:any('pt') then
        return false;
    end

    local detailed = false;
    if #args == 2 then
        detailed = false;
    elseif #args == 3 and args[3]:any('detailed') then
        detailed = true;
    else
        return false;
    end

    local commandText = commandTextFromArgs(args);
    if not canStartCommand(commandText) then
        return true;
    end

    saveAlliance(detailed, commandText);
    return true;
end

local function onCommand(args)
    if #args == 2 and args[2]:any('help') then
        cancelActivePoll();
        showHelp();
        return;
    end

    if #args == 2 and args[2]:any('format') then
        cancelActivePoll();
        output.toggleDetailedFormat();
        return;
    end

    local shellOptions = parseShellArgs(args);
    if shellOptions ~= nil then
        local commandText = commandTextFromArgs(args);
        if not canStartCommand(commandText) then
            return;
        end
        startLinkshellRead(shellOptions, commandText);
        return;
    end

    if saveParty(args) then
        cancelActivePoll();
        return;
    end

    cancelActivePoll();
    output.printInvalidCommand();
end

ashita.events.register('unload', 'shelltrackerUnload', cancelActivePoll);
ashita.events.register('d3d_present', 'shelltrackerPresent', tickLinkshellPoll);
ashita.events.register('command', 'shelltrackerCommand', function(event)
    local args = event.command:args();
    if #args == 0 or args[1] ~= '/st' then
        return;
    end
    event.blocked = true;
    onCommand(args);
end);
