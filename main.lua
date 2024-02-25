-- Example of native Windows GetOpenFileNameW() and
-- GetSaveFileNameW() with LuaJIT FFI and Löve.
-- By Rafael Navega (2024).
--
-- Improves on the work by SiENcE:
-- https://love2d.org/forums/viewtopic.php?p=199862#p199862

io.stdout:setvbuf('no')


local ffi = require('ffi')
local bit = require('bit')
local utf8 = require('utf8')


local function customErrhand(msg)
    --print(debug.traceback())
    print(msg)
    os.execute('pause')
    -- Or also 'io.read()', but it only continues after the Enter key.
end
-- Overwrite the default Löve error handler so it doesn't popup (except
-- on syntax errors).
love.errorhandler = customErrhand


if ffi.arch == 'x86' then
    ffi.cdef([[
        typedef int32_t INT_PTR; //Integer
        typedef uint32_t UINT_PTR; //Integer
    ]])
elseif ffi.arch == 'x64' then
    ffi.cdef([[
        typedef int64_t INT_PTR; //Integer
        typedef uint64_t UINT_PTR; //Integer
    ]])
end

ffi.cdef[[
// Declarations humbly taken from ChatGPT and malkia's:
// https://github.com/malkia/luajit-winapi

typedef int32_t BOOL; //Integer
typedef uint16_t UINT16; //Integer
typedef UINT16 WORD; //Alias
typedef uint32_t DWORD; //Integer

typedef wchar_t WCHAR;
typedef WCHAR *LPWSTR; //Pointer
typedef LPWSTR PWSTR; //Alias
typedef PWSTR LPCWSTR; //Alias

typedef char CHAR;
typedef CHAR *LPSTR; //Pointer
typedef LPSTR LPCSTR; //Alias

typedef UINT_PTR HANDLE; //Alias
typedef HANDLE HWND; //Alias
typedef void *HMODULE; //ModuleHandle
typedef HMODULE HINSTANCE; //Alias
typedef INT_PTR LONG_PTR; //Alias
typedef LONG_PTR LPARAM; //Alias
typedef void* LPOFNHOOKPROC;

// Used in Flags.
static const DWORD OFN_DONTADDTORECENT = 0x02000000;
static const DWORD OFN_FILEMUSTEXIST   = 0x00001000;
static const DWORD OFN_PATHMUSTEXIST   = 0x00000800;
static const DWORD OFN_OVERWRITEPROMPT = 0x00000002;
static const DWORD OFN_HIDEREADONLY    = 0x00000004;

// Used in FlagsEx.
static const DWORD OFN_EX_NOPLACESBAR  = 0x00000001;

typedef struct tagOFNW {
    DWORD         lStructSize;
    HWND          hwndOwner;
    HINSTANCE     hInstance;
    LPCWSTR       lpstrFilter;
    LPWSTR        lpstrCustomFilter;
    DWORD         nMaxCustFilter;
    DWORD         nFilterIndex;
    LPWSTR        lpstrFile;
    DWORD         nMaxFile;
    LPWSTR        lpstrFileTitle;
    DWORD         nMaxFileTitle;
    LPCWSTR       lpstrInitialDir;
    LPCWSTR       lpstrTitle;
    DWORD         Flags;
    WORD          nFileOffset;
    WORD          nFileExtension;
    LPCWSTR       lpstrDefExt;
    LPARAM        lCustData;
    LPOFNHOOKPROC lpfnHook;
    LPCWSTR       lpTemplateName;
    // For _MAC systems.
    //LPEDITMENU    lpEditInfo;
    //LPCSTR        lpstrPrompt;
    void          *pvReserved;
    DWORD         dwReserved;
    DWORD         FlagsEx;
} OPENFILENAMEW, *LPOPENFILENAMEW;

  BOOL GetOpenFileNameW(LPOPENFILENAMEW lpofn);
  BOOL GetSaveFileNameW(LPOPENFILENAMEW lpofn);
]]
local COMDLG = ffi.load('comdlg32')


ffi.cdef[[
  DWORD GetLastError(void);
]]
local KRNL = ffi.load("kernel32")


ffi.cdef[[
/*
 * TODO: get the HWND of the Löve window so we can use it in the ofn.hwndOwner field.
 * See here for how to do it with SDL: https://gamedev.stackexchange.com/a/109134
 */
/*
typedef uint8_t Uint8;
typedef struct SDL_version
{
    Uint8 major;
    Uint8 minor;
    Uint8 patch;
} SDL_version;
void SDL_GetVersion(SDL_version * ver);
*/

void SDL_free(void *mem);
size_t SDL_wcslen(const wchar_t *wstr);
char *SDL_iconv_string(const char *to_charset, const char *from_charset,
                       const char *inbuf, size_t inbytesleft);
]]
local SDL = ffi.load('SDL2')

local SIZEOF_WCHAR = ffi.sizeof('wchar_t')
local WCHAR_FILENAME_TYPE = ffi.typeof('wchar_t[260]')

-- If succesful, returns:
--     wcharPtr:
--         A "wchar_t*" object that points to the string.
--     wstring:
--         The UTF-16LE cdata object (of WCHAR / wchar_t type). It will be
--         automatically garbage collected.
--     byteLength:
--         The length in bytes (NULL character included).
--     stringLength:
--         The length in WCHAR / wchar_t characters (NULL character included).
function stringToWchar(content)
    local wstring = SDL.SDL_iconv_string("UTF-16LE", "UTF-8", content, #content + 1)
    if wstring ~= nil then
        local wcharPtr = ffi.cast('wchar_t*', wstring)
        local stringLength = SDL.SDL_wcslen(wcharPtr) + 1
        local byteLength = stringLength * SIZEOF_WCHAR
        -- Return the string associated w/ the garbage collection finalizer.
        -- See: https://luajit.org/ext_ffi_api.html#ffi_gc
        return wcharPtr, ffi.gc(wstring, SDL.SDL_free),
               byteLength, stringLength
    end
    return nil, nil, 0, 0
end


-- Converts a UTF-16LE cdata string to a Lua string in UTF-8 encoding.
function wcharToString(utf16Content, byteLength)
    local utf8String = SDL.SDL_iconv_string("UTF-8", "UTF-16LE", utf16Content, byteLength)
    if utf8String ~= nil then
        local result = ffi.string(utf8String)
        SDL.SDL_free(utf8String)
        return result
    end
    return nil
end


function _makeOpenFileName(title, filterString, defaultFilter)
    local ofn = ffi.new('OPENFILENAMEW')
    local sizeof_ofn = ffi.sizeof(ofn)

    ofn.lStructSize = sizeof_ofn
    ofn.hwndOwner   = 0
    ofn.hInstance = nil

    -- File formats.
    local wcharPtr = stringToWchar(filterString)
    ofn.lpstrFilter = wcharPtr
    ofn.lpstrCustomFilter = nil
    ofn.nMaxCustFilter = 0
    ofn.nFilterIndex = defaultFilter or 1

    -- A wchar_t buffer where the path result will be written to.
    local szFile = WCHAR_FILENAME_TYPE()
    ofn.lpstrFile = szFile
    ofn.nMaxFile = ffi.sizeof(szFile)

   -- Unused.
    -- ofn.lpstrFileTitle
    -- ofn.nMaxFileTitle

    -- Doesn't seem to work.
    --local defaultDirectory = 'C:\\Windows'
    --wcharPtr = stringToWchar(defaultDirectory)
    --ofn.lpstrInitialDir = wcharPtr
    ofn.lpstrInitialDir = nil

    -- Dialog title.
    local wcharPtr = stringToWchar(title)
    ofn.lpstrTitle = wcharPtr

    ofn.Flags = bit.bor(COMDLG.OFN_PATHMUSTEXIST, COMDLG.OFN_HIDEREADONLY,
                        COMDLG.OFN_DONTADDTORECENT, COMDLG.OFN_FILEMUSTEXIST,
                        COMDLG.OFN_OVERWRITEPROMPT)
    -- Output values.
    --ofn.nFileOffset
    --ofn.nFileExtension

    -- Default file extension.
    -- Note: as per MSDN docs, "Only the first three characters are used".
    --local defaultExtension = 'love'
    --local wcharPtr = stringToWchar(defaultExtension)
    --ofn.lpstrDefExt = wcharPtr
    ofn.lpstrDefExt = nil

    ofn.lCustData = 0
    ofn.lpfnHook = nil
    ofn.lpTemplateName = nil
    --ofn.pvReserved
    --ofn.dwReserved

    -- This flag causes an ugly old-style dialog:
    --ofn.FlagsEx = COMDLG.OFN_EX_NOPLACESBAR
    ofn.FlagsEx = 0
    return ofn
end


function _parseOpenFileNameResult(ofn)
    local constCharPtr = ffi.cast('const char *', ofn.lpstrFile)
    local fullPath = wcharToString(constCharPtr, ofn.nMaxFile * SIZEOF_WCHAR)

    -- Needs to be handled with LuaJIT's UTF-8 library as the characters
    -- might span more than one byte.
    -- Note: the +1 / -1 offsets is because 'nFileOffset' includes the
    -- opening slash of the filename, and 'nFileExtension' includes the
    -- dot character in the extension.
    local filenameStart  = utf8.offset(fullPath, ofn.nFileOffset + 1)
    local extensionStart = utf8.offset(fullPath, ofn.nFileExtension)
    local fileName = fullPath:sub(filenameStart, extensionStart - 1)
    local fileExtension = fullPath:sub(extensionStart + 1)
    return fullPath, fileName, fileExtension
end


function SaveDialogW(title, filterString, defaultFilter)
    local ofn = _makeOpenFileName(title, filterString, defaultFilter)
    result = COMDLG.GetSaveFileNameW(ofn)
    if result ~= 0 then
        return _parseOpenFileNameResult(ofn)
    else
        -- Error happened
        local lastError = KRNL.GetLastError()
        if lastError == 0 then
            -- Dialog canceled.
        else
            -- Some error.
            --print('Error: ', lastError)
        end
    end
    return nil, nil, nil
end


function OpenDialogW(title, filterString, defaultFilter)
    local ofn = _makeOpenFileName(title, filterString, defaultFilter)
    result = COMDLG.GetOpenFileNameW(ofn)
    if result ~= 0 then
        return _parseOpenFileNameResult(ofn)
    else
        -- Error happened
        local lastError = KRNL.GetLastError()
        if lastError == 0 then
            -- Dialog canceled.
        else
            -- Some error.
            --print('Error: ', lastError)
        end
    end
    return nil, nil, nil
end

-- A string for the acceptable formats.
-- The string is formed by elements separated by null characters ("\0").
-- The elements are sequential:
-- label_a \0 pattern_a \0 label_b \0 pattern_b (...)
local filterString = 'All (*.*)\0*.*\0Löve (*.love)\0*.love'

-- The default filter pair to use from the 'filterString'. It starts from ONE
-- and goes up to the number of filter pairs.
defaultFilter = 2

-- Bring the Save or Open dialogs.
--fullPath, fileName, fileExtension = SaveDialogW('「LOVE」 ファイルを保存する', filterString, defaultFilter)
fullPath, fileName, fileExtension = OpenDialogW('「LOVE」 ファイルを開く', filterString, defaultFilter)
if fullPath then
    print('PATH:\n\t'..fullPath)
    print('\nNAME:\n\t'..fileName)
    print('\nEXT:\n\t'..fileExtension)
else
    print("(Nothing returned)")
end
print()
os.execute('pause')
os.exit()
