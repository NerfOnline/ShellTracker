local ffi = require('ffi');
local chat = require('chat');
local settings = require('settings');

local output = {};

local headerBuilder = nil;
local clipboardFormatText = 1;
local clipboardMemoryMoveable = 0x0042;
local highlightKeywords = { 'linkshell2', 'linkshell', 'alliance', 'search', 'party' };

ffi.cdef[[
    void* GlobalAlloc(unsigned uFlags, size_t dwBytes);
    void* GlobalLock(void* hMem);
    bool GlobalUnlock(void* hMem);
    void* GlobalFree(void* hMem);
    bool OpenClipboard(void* hwnd);
    bool EmptyClipboard();
    void* SetClipboardData(unsigned format, void* handle);
    bool CloseClipboard();
]];

local function findEarliestHighlight(text, pos)
    local bestStart, bestFinish, bestText, bestKind = nil, nil, nil, nil;
    local backtickStart, backtickFinish, backtickText = text:find('`([^`]+)`', pos);

    if backtickStart ~= nil then
        bestStart, bestFinish, bestText, bestKind = backtickStart, backtickFinish, backtickText, 'success';
    end

    local areaStart, areaFinish, areaText = text:find('{([^}]+)}', pos);
    if areaStart ~= nil and (bestStart == nil or areaStart < bestStart) then
        bestStart, bestFinish, bestText, bestKind = areaStart, areaFinish, areaText, 'area';
    end

    local lowerText = text:lower();
    for _, keyword in ipairs(highlightKeywords) do
        local keywordStart = lowerText:find(keyword, pos, true);
        if keywordStart ~= nil then
            local keywordFinish = keywordStart + #keyword - 1;
            if bestStart == nil or keywordStart < bestStart then
                bestStart = keywordStart;
                bestFinish = keywordFinish;
                bestText = text:sub(keywordStart, keywordFinish);
                bestKind = 'success';
            end
        end
    end

    return bestStart, bestFinish, bestText, bestKind;
end

local function appendHighlightSegment(line, kind, text)
    if kind == 'area' then
        return line:append(chat.color1(6, text));
    end
    return line:append(chat.success(text));
end

local function appendHighlightedText(header, text, useErrorColor)
    local line = header;
    local pos = 1;
    local plainColor = useErrorColor and chat.error or chat.message;

    while pos <= #text do
        local highlightStart, highlightFinish, highlightText, highlightKind = findEarliestHighlight(text, pos);
        if highlightStart == nil then
            line = line:append(plainColor(text:sub(pos)));
            break;
        end
        if highlightStart > pos then
            line = line:append(plainColor(text:sub(pos, highlightStart - 1)));
        end
        line = appendHighlightSegment(line, highlightKind, highlightText);
        pos = highlightFinish + 1;
    end

    return line;
end

local function notify(text, isError)
    print(appendHighlightedText(headerBuilder(), text, isError));
end

local function timestamp()
    return {
        date = os.date('%Y-%m-%d'),
        time = os.date('%H:%M:%S'),
        fileTime = os.date('%H-%M-%S'),
        utc = os.date('%z'),
    };
end

local function detailedFormatFor(detailed)
    return detailed and settings.detailedFormat or 'csv';
end

local function formatLine(member, detailed, times)
    if not detailed then
        return member.name;
    end

    local main = member.mainJob .. member.mainJobLevel;
    local sub = member.subJob .. member.subJobLevel;

    return table.concat({
        member.name,
        main .. '/' .. sub,
        times.date,
        times.time,
        'UTC' .. times.utc,
        member.zone,
    }, ',') .. ',';
end

local function buildLogFileName(owner, times, fileFormat, detailed)
    local prefix = owner .. '_';
    if detailed then
        prefix = prefix .. 'Detailed_';
    end
    return prefix .. times.date .. '_' .. times.fileTime .. '.' .. fileFormat;
end

local function logDirectory()
    return AshitaCore:GetInstallPath() .. '\\' .. settings.logDirectory .. '\\';
end

function output.setHeaderBuilder(builder)
    headerBuilder = builder;
end

function output.wrapAreaName(name)
    return '{' .. name .. '}';
end

function output.printInfo(text)
    notify(text, false);
end

function output.printFailure(text)
    notify(text, true);
end

function output.printStyled(buildMessage)
    print(buildMessage(headerBuilder()));
end

function output.printInvalidCommand()
    output.printStyled(function(header)
        return header
            :append(chat.error('Unknown command. For a list of commands use: '))
            :append(chat.success('/st help'));
    end);
end

function output.appendFlaggedCommand(header, commandText)
    local line = header;
    local pos = 1;

    while pos <= #commandText do
        local start, finish, word = commandText:find('(detailed|all)', pos);
        if start == nil then
            return line:append(chat.success(commandText:sub(pos)));
        end
        if start > pos then
            line = line:append(chat.success(commandText:sub(pos, start - 1)));
        end
        line = line:append(chat.color1(6, word));
        pos = finish + 1;
    end

    return line;
end

function output.printHelpLine(commandText, description)
    output.printStyled(function(header)
        return output.appendFlaggedCommand(header, commandText)
            :append(chat.message(' - '))
            :append(chat.message(description));
    end);
end

function output.copyText(text)
    local byteCount = #text + 1;
    local block = ffi.C.GlobalAlloc(clipboardMemoryMoveable, byteCount);
    if block == nil then
        output.printFailure('Clipboard memory allocation failed.');
        return false;
    end

    local view = ffi.C.GlobalLock(block);
    ffi.copy(view, text, byteCount);
    ffi.C.GlobalUnlock(block);

    if not ffi.C.OpenClipboard(nil) then
        ffi.C.GlobalFree(block);
        output.printFailure('Could not open the clipboard.');
        return false;
    end

    ffi.C.EmptyClipboard();
    if ffi.C.SetClipboardData(clipboardFormatText, block) == nil then
        ffi.C.GlobalFree(block);
        ffi.C.CloseClipboard();
        output.printFailure('Could not copy data to clipboard.');
        return false;
    end

    ffi.C.CloseClipboard();
    return true;
end

function output.toggleDetailedFormat()
    if settings.detailedFormat == 'csv' then
        settings.detailedFormat = 'txt';
        output.printInfo('Detailed logs will now use txt format.');
    else
        settings.detailedFormat = 'csv';
        output.printInfo('Detailed logs will now use csv format.');
    end
    settings.savePersisted();
end

function output.publishMembers(owner, members, detailed, footer)
    local times = timestamp();
    local fileFormat = detailedFormatFor(detailed);
    local directory = logDirectory();
    local fileName = buildLogFileName(owner, times, fileFormat, detailed);
    local fence = settings.clipboardFence;
    local clipboardParts = { fence, '\n' };

    ashita.fs.create_dir(directory);

    local logFile = io.open(directory .. fileName, 'a');
    if logFile == nil then
        output.printFailure('Could not write log file: ' .. directory .. fileName);
    end

    for _, member in ipairs(members) do
        local line = formatLine(member, detailed, times);
        clipboardParts[#clipboardParts + 1] = line;
        clipboardParts[#clipboardParts + 1] = '\n';
        if logFile ~= nil then
            logFile:write(line .. '\n');
        end
    end

    if logFile ~= nil then
        logFile:close();
    end

    if footer ~= nil then
        clipboardParts[#clipboardParts + 1] = footer;
        clipboardParts[#clipboardParts + 1] = '\n';
    end

    clipboardParts[#clipboardParts + 1] = fence;
    local copied = output.copyText(table.concat(clipboardParts));

    if footer ~= nil and copied then
        output.printInfo(footer);
    end
end

return output;
