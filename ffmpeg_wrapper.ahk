; ==============================================================================
; ffmpeg_wrapper.ahk
;
; VERSION:   1.3.1
; UPDATED:   2026-06-20
; CHANGELOG:
;   1.3.1 (2026-06-20) - Fixed EncodingArgs truncation: the value regex used
;                        [^"]+ which halted at the first escaped quote (\"), so
;                        any -metadata key="..." in EncodingArgs cut the command
;                        off mid-string. Capture is now escape-aware
;                        ((?:\\.|[^"\\])*) and the value is JSON-unescaped
;                        (JsonUnescape) so ffmpeg receives real quotes.
;   1.3.0 (2026-06-17) - Codec guard widened from hevc_qsv-only to an allow-list
;                        (hevc_qsv, hevc_nvenc, h264_nvenc, av1_nvenc) so NVENC
;                        works on Nvidia machines. PixelFormat injection already
;                        parameterized (set yuv444p16le/p010le for NVENC).
;   <=1.2.x           - QSV-only override, framerate strip, tmix blending,
;                        JSONC config, config-conflict hard aborts.
;   (Bump VERSION on every functional edit.)
;
; Intercepts FlowFrames FFmpeg calls and optionally overrides H.265 encoding
; or applies framerate downsampling with temporal blending (tmix).
;
; Deployment:
;   1. Rename original ffmpeg.exe -> ffmpeg_real.exe  (same pkgs\av folder)
;   2. Compile THIS script as ffmpeg.exe (64-bit, see below)
;   3. Place ffmpeg_wrapper_config.json alongside ffmpeg.exe
;
; Config file: ffmpeg_wrapper_config.json
;   {
;     "LogEnable": "True",
;     "DebugLogEnable": "False",
;     "OverrideH265Encoding": {
;       "Enable": "True",
;       "PixelFormat": "nv12",
;       "EncodingArgs": "-c:v hevc_qsv -global_quality 12 -preset slow ..."
;     },
;     "tmixBlending": {
;       "Enable": "False",
;       "TargetFps": "60",
;       "BlendWeights": "1,1,1,1,1",
;       "PixelFormat": "nv12",
;       "EncodingArgs": "-c:v hevc_qsv -global_quality 17 -preset slow -g 60 ..."
;     },
;     "VspipeConfigPath": ""
;   }
;   OverrideH265Encoding.PixelFormat: pixel format injected as format=<X> into the
;     filter_complex. nv12 = 8-bit hevc_qsv input; p010le = 10-bit (pair with
;     -profile:v main10 in EncodingArgs). Default nv12.
;   tmixBlending (formerly DownsampleFramerate): blends sourceFps frames down to
;     TargetFps using ffmpeg tmix on the encode command. BlendWeights count must
;     equal sourceFps/TargetFps. SourceFps is auto-detected from -r N/1 in args.
;     PixelFormat as above. Triggers on FlowFrames libx265 encode commands —
;     both the vspipe-piped first pass and any file-input second pass.
;   tmixBlending and OverrideH265Encoding are mutually exclusive;
;     tmixBlending takes priority if both are enabled simultaneously.
;   VspipeConfigPath (top-level): path to the sibling vspipe_wrapper_config.json, used
;     for conflict detection. Auto-resolves to ..\rife-ncnn-vs\vspipe_wrapper_config.json
;     when empty. If tmixBlending.Enable=True and the config is missing or unreadable,
;     the encode is aborted (blend state of the incoming stream cannot be determined).
;     Dangerous combinations that trigger MsgBox + non-zero exit:
;       tmixBlending + AverageFrames.Enable (vspipe config) → double-blend
;       tmixBlending + OverrideVspipeScript.Enable (vspipe config) → custom script blend state unknown
;
; Compilation requirement:
;   Ahk2Exe -> Base File MUST be AutoHotkey64.exe (64-bit)
;   64-bit is mandatory: ReadProcessMemory of parent cmd.exe (64-bit) requires
;   a 64-bit caller. 32-bit callers get STATUS_INFO_LENGTH_MISMATCH from NtQIP.
; ==============================================================================

#Requires AutoHotkey v2.0 64-bit   ; Runtime guard: aborts with error if run as 32-bit
;@Ahk2Exe-ConsoleApp               ; Compile-time: sets PE subsystem to CONSOLE (3)
                                   ; Without this, stdin/stdout/stderr are not inherited
                                   ; from cmd.exe and FlowFrames cannot read ffmpeg output


; ==============================================================================
; GLOBAL PATHS
; ==============================================================================

; ffmpeg_real.exe must be in the same directory as this wrapper
RealFfmpeg := A_ScriptDir . "\ffmpeg_real.exe"

; Config and log files sit alongside the wrapper exe
ConfigFile := A_ScriptDir . "\ffmpeg_wrapper_config.json"
LogFile    := A_ScriptDir . "\ffmpeg_wrapper.log"


; ==============================================================================
; GUARD: verify ffmpeg_real.exe exists before proceeding
; ==============================================================================
if !FileExist(RealFfmpeg) {
    MsgBox(
        "ffmpeg_real.exe not found at:`n" . RealFfmpeg .
        "`n`nRename the original ffmpeg.exe to ffmpeg_real.exe.",
        "ffmpeg_wrapper error", 16)
    DllCall("ExitProcess", "UInt", 1)
}


; ==============================================================================
; FUNCTION: Log
; Appends a timestamped line to the log file.
; Only writes when LogEnable = True (passed via cfg object).
; ==============================================================================
Log(msg, cfg) {
    global LogFile
    if cfg.logEnable
        FileAppend(A_Now . "  " . msg . "`n", LogFile)
}

; ==============================================================================
; FUNCTION: LogDebug
; Appends a timestamped line only when DebugLogEnable = True.
; Used for low-level diagnostic data: PIDs, handles, memory addresses, etc.
; ==============================================================================
LogDebug(msg, cfg) {
    global LogFile
    if cfg.debugLogEnable
        FileAppend(A_Now . "  [DBG] " . msg . "`n", LogFile)
}


; ==============================================================================
; FUNCTION: ParseConfig
; Reads ffmpeg_wrapper_config.json and returns a Map with all settings.
; Uses regex extraction - tolerant of missing commas (common JSON authoring
; mistake) since we only match key:"value" patterns, not full JSON structure.
;
; Returns object with fields:
;   .logEnable          (bool) - LogEnable
;   .debugLogEnable     (bool) - DebugLogEnable
;   .h265Enable         (bool) - OverrideH265Encoding.Enable
;   .h265PixelFormat    (str)  - OverrideH265Encoding.PixelFormat (default nv12)
;   .h265Args           (str)  - OverrideH265Encoding.EncodingArgs
;   .tmixEnable         (bool) - tmixBlending.Enable
;   .tmixTargetFps      (str)  - tmixBlending.TargetFps
;   .tmixBlendWeights   (str)  - tmixBlending.BlendWeights
;   .tmixPixelFormat    (str)  - tmixBlending.PixelFormat (default nv12)
;   .tmixArgs           (str)  - tmixBlending.EncodingArgs
;   .pipeFixEnable      (bool) - removed; -r is now unconditionally stripped for pipe input
;   .vspipeConfigPath   (str)  - VspipeConfigPath top-level key ("" = auto)
; ==============================================================================
ParseConfig() {
    global ConfigFile

    ; Defaults - overrides off, pipe framerate fix ON (it only acts when the
    ; sibling vspipe config actually has AverageFrames enabled)
    cfg := {
        logEnable:          false,
        debugLogEnable:     false,
        h265Enable:         false,
        h265PixelFormat:    "nv12",
        h265Args:           "",
        tmixEnable:         false,
        tmixTargetFps:      "60",
        tmixBlendWeights:   "1,1,1,1,1",
        tmixPixelFormat:    "nv12",
        tmixArgs:           "",
        vspipeConfigPath:   ""
    }

    if !FileExist(ConfigFile)
        return cfg

    ; Read entire file as UTF-8 text
    json := FileRead(ConfigFile, "UTF-8")
    json := StripJsonComments(json)   ; JSONC: tolerate // and /* */ comments

    ; --- LogEnable (top-level) ---
    if RegExMatch(json, '"LogEnable"\s*:\s*"([^"]+)"', &m)
        cfg.logEnable := (m[1] = "True")

    ; --- DebugLogEnable (top-level) ---
    if RegExMatch(json, '"DebugLogEnable"\s*:\s*"([^"]+)"', &m)
        cfg.debugLogEnable := (m[1] = "True")

    ; --- OverrideH265Encoding block ---
    if RegExMatch(json, '"OverrideH265Encoding"\s*:\s*\{[^}]*?"Enable"\s*:\s*"([^"]+)"', &m)
        cfg.h265Enable := (m[1] = "True")
    if RegExMatch(json, '"OverrideH265Encoding"\s*:\s*\{[^}]*?"PixelFormat"\s*:\s*"([^"]+)"', &m)
        cfg.h265PixelFormat := Trim(m[1])
    if RegExMatch(json, '"OverrideH265Encoding"\s*:\s*\{[^}]*?"EncodingArgs"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        cfg.h265Args := JsonUnescape(Trim(m[1]))

    ; --- tmixBlending block (accept legacy "DownsampleFramerate" name too) ---
    blockName := InStr(json, '"tmixBlending"') ? "tmixBlending" : "DownsampleFramerate"
    if RegExMatch(json, '"' . blockName . '"\s*:\s*\{[^}]*?"Enable"\s*:\s*"([^"]+)"', &m)
        cfg.tmixEnable := (m[1] = "True")
    if RegExMatch(json, '"' . blockName . '"\s*:\s*\{[^}]*?"TargetFps"\s*:\s*"([^"]+)"', &m)
        cfg.tmixTargetFps := Trim(m[1])
    if RegExMatch(json, '"' . blockName . '"\s*:\s*\{[^}]*?"BlendWeights"\s*:\s*"([^"]+)"', &m)
        cfg.tmixBlendWeights := Trim(m[1])
    if RegExMatch(json, '"' . blockName . '"\s*:\s*\{[^}]*?"PixelFormat"\s*:\s*"([^"]+)"', &m)
        cfg.tmixPixelFormat := Trim(m[1])
    if RegExMatch(json, '"' . blockName . '"\s*:\s*\{[^}]*?"EncodingArgs"\s*:\s*"((?:\\.|[^"\\])*)"', &m)
        cfg.tmixArgs := JsonUnescape(Trim(m[1]))

    ; --- VspipeConfigPath (top-level) ---
    ; Path to the sibling vspipe_wrapper_config.json used for conflict detection.
    ; Empty string = auto-resolve to ..\rife-ncnn-vs\vspipe_wrapper_config.json
    if RegExMatch(json, '"VspipeConfigPath"\s*:\s*"([^"]*)"', &m)
        cfg.vspipeConfigPath := Trim(m[1])

    return cfg
}


; ==============================================================================
; FUNCTION: GetVspipeAvgInfo
; Reads the SIBLING vspipe_wrapper_config.json for conflict detection:
;   - AverageFrames.Enable + Cycle (double-blend guard with tmixBlending)
;   - OverrideVspipeScript.Enable (unknown blend state guard with tmixBlending)
;
; Path resolution:
;   cfg.vspipeConfigPath if non-empty, else A_ScriptDir\..\rife-ncnn-vs\
;   vspipe_wrapper_config.json (standard FlowFrames pkgs layout).
;
; Returns object: { found: bool, path: str, avgEnabled: bool, cycle: int, overrideEnabled: bool }
;   found=false means the file was absent/unreadable.
;   When tmixBlending.Enable=True and found=false, the caller aborts.
; ==============================================================================
GetVspipeAvgInfo(cfg) {
    info := { found: false, path: "", avgEnabled: false, cycle: 1, overrideEnabled: false }

    path := cfg.vspipeConfigPath
    if path = ""
        path := A_ScriptDir . "\..\rife-ncnn-vs\vspipe_wrapper_config.json"
    else
        path := ResolvePath(path)   ; abs / relative-to-wrapper / %EnvVar%
    info.path := path

    if !FileExist(path) {
        LogDebug("GetVspipeAvgInfo: config not found at " . path, cfg)
        return info
    }

    try {
        raw := FileRead(path, "UTF-8")
    } catch {
        LogDebug("GetVspipeAvgInfo: config unreadable at " . path, cfg)
        return info
    }
    raw := StripJsonComments(raw)   ; JSONC: tolerate // and /* */ comments

    info.found := true

    if RegExMatch(raw, '"AverageFrames"\s*:\s*\{[\s\S]{0,500}?"Enable"\s*:\s*"([^"]*)"', &m)
        info.avgEnabled := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"SelectEvery"\s*:\s*\{[^}]*"Cycle"\s*:\s*"([^"]*)"', &m) {
        try info.cycle := Integer(Trim(m[1]))
        catch
            info.cycle := 1
    }
    if RegExMatch(raw, '"OverrideVspipeScript"\s*:\s*\{[^}]*"Enable"\s*:\s*"([^"]*)"', &m)
        info.overrideEnabled := (m[1] = "True" || m[1] = "true")

    LogDebug("GetVspipeAvgInfo: path=" . path
        . " avgEnabled=" . (info.avgEnabled ? "True" : "False")
        . " cycle=" . info.cycle
        . " overrideEnabled=" . (info.overrideEnabled ? "True" : "False"), cfg)
    return info
}




; ==============================================================================
; FUNCTION: GetParentCurrentDir
; Returns the current working directory of the parent process (cmd.exe).
;
; FlowFrames spawns:  cmd.exe /C cd /D "workDir" & ffmpeg.exe args
; cmd.exe changes its own CWD to workDir before spawning ffmpeg.exe.
; AHK overwrites our CWD to A_ScriptDir at startup, so we cannot use
; GetCurrentDirectory() or A_WorkingDir - they always return pkgs\av.
; Instead we read the parent's PEB.ProcessParameters.CurrentDirectory.
;
; Steps:
;   1. NtQueryInformationProcess(self) -> InheritedFromUniqueProcessId = parent PID
;   2. OpenProcess(parent PID)
;   3. NtQueryInformationProcess(parent) -> parent PEB base address
;   4. ReadProcessMemory(parent PEB + 0x20) -> ProcessParameters pointer
;   5. ReadProcessMemory(PP + 0x38/0x40)   -> CurrentDirectory UNICODE_STRING
;
; RTL_USER_PROCESS_PARAMETERS layout (64-bit Windows 10/11):
;   +0x38  CurrentDirectory.DosPath.Length     (USHORT, 2 bytes)
;   +0x3A  CurrentDirectory.DosPath.MaxLength  (USHORT, 2 bytes)
;   +0x3C  (4 bytes padding for 8-byte pointer alignment)
;   +0x40  CurrentDirectory.DosPath.Buffer     (PWSTR pointer, 8 bytes)
;
; Returns A_WorkingDir (pkgs\av) as fallback if any step fails.
; ==============================================================================
GetParentCurrentDir(cfg) {

    ; ------------------------------------------------------------------
    ; STEP 1: Get parent PID via NtQueryInformationProcess on ourselves
    ; ProcessBasicInformation (class 0) fills PROCESS_BASIC_INFORMATION:
    ;   64-bit layout (48 bytes total):
    ;   +0   ExitStatus              (LONG, 4 bytes)
    ;   +4   padding                 (4 bytes for pointer alignment)
    ;   +8   PebBaseAddress          (PTR, 8 bytes)
    ;   +16  AffinityMask            (PTR, 8 bytes)
    ;   +24  BasePriority            (LONG, 4 bytes)
    ;   +28  padding                 (4 bytes)
    ;   +32  UniqueProcessId         (PTR, 8 bytes)
    ;   +40  InheritedFromUniqueProcessId (PTR, 8 bytes)  <- parent PID
    ; ------------------------------------------------------------------
    pbiSelf := Buffer(48, 0)
    ; GetCurrentProcess() returns pseudo-handle -1 (always valid for self)
    ; ProcessBasicInformation = 0
    ; Buffer size 48 = sizeof(PROCESS_BASIC_INFORMATION) on 64-bit
    ; ReturnLength = NULL (optional, we don't need it)
    ntRetSelf := DllCall("ntdll\NtQueryInformationProcess",
        "Ptr",  DllCall("Kernel32\GetCurrentProcess", "Ptr"),
        "UInt", 0,
        "Ptr",  pbiSelf,
        "UInt", 48,
        "Ptr",  0,
        "Int")  ; return type Int = NTSTATUS (0 = STATUS_SUCCESS)

    ; InheritedFromUniqueProcessId is ULONG_PTR (8 bytes) at offset 40
    ; PIDs are always 32-bit values - read as UInt to avoid garbage in upper bytes
    parentPID := NumGet(pbiSelf, 40, "UInt")
    LogDebug("NtQIP(self): ret=" . ntRetSelf . "  parentPID=" . parentPID, cfg)

    if !parentPID
        return A_WorkingDir

    ; ------------------------------------------------------------------
    ; STEP 2: Open parent process
    ; PROCESS_QUERY_INFORMATION (0x400) = read process info via NtQIP
    ; PROCESS_VM_READ           (0x010) = required for ReadProcessMemory
    ; Combined access mask = 0x410
    ; bInheritHandle = FALSE (0) - we don't need child processes to inherit this
    ; dwProcessId = parentPID
    ; Returns HANDLE or NULL on failure
    ; ------------------------------------------------------------------
    hParent := DllCall("Kernel32\OpenProcess",
        "UInt", 0x410,   ; dwDesiredAccess: PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
        "Int",  0,       ; bInheritHandle: FALSE
        "UInt", parentPID,
        "Ptr")           ; return type: HANDLE (pointer-sized)
    LogDebug("OpenProcess: " . (hParent ? "ok handle=0x" . Format("{:X}", hParent) : "FAILED err=" . A_LastError), cfg)

    if !hParent
        return A_WorkingDir

    result := A_WorkingDir  ; fallback until we successfully read the path

    ; ------------------------------------------------------------------
    ; STEP 3: Get parent PEB base address via NtQueryInformationProcess
    ; Same structure as Step 1. PebBaseAddress is at offset 8.
    ; ------------------------------------------------------------------
    pbiParent := Buffer(48, 0)
    ntRetParent := DllCall("ntdll\NtQueryInformationProcess",
        "Ptr",  hParent,
        "UInt", 0,      ; ProcessBasicInformation
        "Ptr",  pbiParent,
        "UInt", 48,
        "Ptr",  0,
        "Int")
    peb := NumGet(pbiParent, 8, "Ptr")  ; PebBaseAddress at offset 8, type PTR (8 bytes)
    LogDebug("parent NtQIP: ret=" . ntRetParent . "  PEB=0x" . Format("{:X}", peb), cfg)

    if peb {
        ; ------------------------------------------------------------------
        ; STEP 4: Read ProcessParameters pointer from PEB
        ; PEB.ProcessParameters is at PEB base + 0x20 on 64-bit Windows 10/11
        ; It points to an RTL_USER_PROCESS_PARAMETERS structure
        ; ------------------------------------------------------------------
        ppBuf := Buffer(8, 0)
        ; ReadProcessMemory args:
        ;   hProcess       = hParent        (handle to parent process)
        ;   lpBaseAddress  = peb + 0x20     (address in parent's virtual memory)
        ;   lpBuffer       = ppBuf          (our local buffer to receive data)
        ;   nSize          = 8              (size of a pointer on 64-bit)
        ;   lpBytesRead    = NULL (optional)
        rmRet := DllCall("Kernel32\ReadProcessMemory",
            "Ptr",  hParent,
            "Ptr",  peb + 0x20,
            "Ptr",  ppBuf,
            "UPtr", 8,    ; UPtr = SIZE_T (pointer-sized unsigned integer)
            "Ptr",  0)
        pp := NumGet(ppBuf, 0, "Ptr")  ; RTL_USER_PROCESS_PARAMETERS*
        LogDebug("ProcessParameters: rmRet=" . rmRet . "  pp=0x" . Format("{:X}", pp), cfg)

        if pp {
            ; ------------------------------------------------------------------
            ; STEP 5: Read CurrentDirectory UNICODE_STRING
            ; CurrentDirectory.DosPath.Length at PP + 0x38  (USHORT, 2 bytes)
            ; CurrentDirectory.DosPath.Buffer  at PP + 0x40  (PWSTR, 8 bytes)
            ;   (offset 0x40 = 0x38 base + 8 byte skip: 2+2 USHORT + 4 padding)
            ; Length is in BYTES (UTF-16), so char count = Length / 2
            ; ------------------------------------------------------------------
            lBuf := Buffer(2, 0)
            pBuf := Buffer(8, 0)
            DllCall("Kernel32\ReadProcessMemory", "Ptr", hParent, "Ptr", pp + 0x38, "Ptr", lBuf, "UPtr", 2, "Ptr", 0)
            DllCall("Kernel32\ReadProcessMemory", "Ptr", hParent, "Ptr", pp + 0x40, "Ptr", pBuf, "UPtr", 8, "Ptr", 0)
            dirLen := NumGet(lBuf, 0, "UShort")  ; UShort = 16-bit unsigned
            dirPtr := NumGet(pBuf, 0, "Ptr")     ; Ptr    = 64-bit address
            LogDebug("CurDir: len=" . dirLen . " ptr=0x" . Format("{:X}", dirPtr), cfg)

            if dirLen > 0 && dirPtr {
                dirBuf := Buffer(dirLen + 2, 0)  ; +2 for null terminator
                DllCall("Kernel32\ReadProcessMemory", "Ptr", hParent, "Ptr", dirPtr, "Ptr", dirBuf, "UPtr", dirLen, "Ptr", 0)
                parentDir := RTrim(StrGet(dirBuf, dirLen // 2, "UTF-16"), "\")
                LogDebug("parent CurDir: " . parentDir, cfg)
                if parentDir != ""
                    result := parentDir
            }

            ; ------------------------------------------------------------------
            ; Also read parent CommandLine for debug logging
            ; CommandLine UNICODE_STRING at PP + 0x70 (Length) / PP + 0x78 (Buffer)
            ; ------------------------------------------------------------------
            if cfg.debugLogEnable {
                lBuf2 := Buffer(2, 0)
                pBuf2 := Buffer(8, 0)
                DllCall("Kernel32\ReadProcessMemory", "Ptr", hParent, "Ptr", pp + 0x70, "Ptr", lBuf2, "UPtr", 2, "Ptr", 0)
                DllCall("Kernel32\ReadProcessMemory", "Ptr", hParent, "Ptr", pp + 0x78, "Ptr", pBuf2, "UPtr", 8, "Ptr", 0)
                cmdLen := NumGet(lBuf2, 0, "UShort")
                cmdPtr := NumGet(pBuf2, 0, "Ptr")
                if cmdLen > 0 && cmdPtr {
                    cmdBuf := Buffer(cmdLen + 2, 0)
                    DllCall("Kernel32\ReadProcessMemory", "Ptr", hParent, "Ptr", cmdPtr, "Ptr", cmdBuf, "UPtr", cmdLen, "Ptr", 0)
                    LogDebug("parent CmdLine: " . StrGet(cmdBuf, cmdLen // 2, "UTF-16"), cfg)
                }
            }
        }
    }

    ; Release the handle - always close what you open
    DllCall("Kernel32\CloseHandle", "Ptr", hParent)
    return result
}


; ==============================================================================
; FUNCTION: BuildOverriddenArgs
; Given original FlowFrames args (libx265 encoding command), strips everything
; between "-map [vf]" and the output file path, replaces with OverrideEncodingArgs,
; and injects format=nv12 into the filter_complex for hevc_qsv compatibility.
;
; Why format=nv12:
;   VapourSynth (rife-ncnn-vs) outputs yuv444p 16le via yuv4mpegpipe.
;   hevc_qsv accepts nv12 (8-bit 4:2:0) or p010 (10-bit). Software conversion
;   via format=nv12 in the filter chain bridges the pixel format mismatch.
;
; Why -init_hw_device qsv=qsv0:
;   hevc_qsv needs an initialized QSV device context. When no hwaccel decode
;   is used (pipe input = software decode), the device must be explicitly
;   initialized via -init_hw_device. Prepended automatically if absent.
;
; Returns the fully constructed args string for ffmpeg_real.exe.
; ==============================================================================
BuildOverriddenArgs(args, overrideArgs, cfg) {

    ; ------------------------------------------------------------------
    ; Find the "-map [vf]" marker - everything before it (inclusive) is
    ; kept as-is (input setup, filter_complex, map). Everything after it
    ; up to the output path is discarded and replaced with OverrideEncodingArgs.
    ; ------------------------------------------------------------------
    ; Find "-map [<label>]" - capture the actual output label used by FlowFrames.
    ; Using a capture group instead of hardcoding [vf] means both this detection
    ; and the format=nv12 injection below stay in sync if FlowFrames ever changes
    ; the output label (e.g. [out], [v], [video]).
    mapMatchPos := RegExMatch(args, "-map \[([^\]]+)\]", &mapObj)
    LogDebug("BuildOverriddenArgs: mapMatchPos=" . mapMatchPos, cfg)
    if !mapMatchPos
        return ""

    mapLabel := mapObj[1]   ; e.g. "vf" - reused in nv12 injection below
    LogDebug("BuildOverriddenArgs: mapLabel=" . mapLabel, cfg)

    ; preamble = everything up to and including "-map [<label>]"
    preamble := SubStr(args, 1, mapMatchPos + mapObj.Len - 1)
    LogDebug("BuildOverriddenArgs: preamble=" . preamble, cfg)

    ; ------------------------------------------------------------------
    ; Inject format=<PixelFormat> into the existing filter_complex pad chain.
    ; Pattern:  [<any>]pad=<params>[<mapLabel>]
    ; Becomes:  [<any>]pad=<params>,format=<PixelFormat>[<mapLabel>]
    ;
    ; Uses the captured mapLabel so the match target and replacement label
    ; are always consistent regardless of what label FlowFrames uses.
    ; The pad operation produces yuv444p 16le from the VapourSynth pipe.
    ; Appending ,format=<PixelFormat> converts inline within the existing
    ; filter graph - avoids needing a separate -vf which would conflict
    ; with the already-present -filter_complex.
    ; nv12 = 8-bit hevc_qsv input (default); p010le = 10-bit input for
    ; main10 encodes (configure OverrideH265Encoding.PixelFormat).
    ; ------------------------------------------------------------------
    preamble := RegExReplace(preamble, "(\[[^\]]+\]pad=[^\[]+)\[" . mapLabel . "\]", "$1,format=" . cfg.h265PixelFormat . "[" . mapLabel . "]")

    ; ------------------------------------------------------------------
    ; Strip encoder-specific options that may appear in the preamble.
    ; In RIFE commands, encoder options (-c:v libx265, -pix_fmt, -crf etc.)
    ; appear AFTER -map [vf] and are cleanly replaced. In DAIN commands,
    ; FlowFrames places them BEFORE -filter_complex, so they land inside
    ; the preamble and must be stripped before assembly.
    ;
    ; -pix_fmt is critical: if yuv420p survives, ffmpeg converts the filter
    ; chain nv12 back to yuv420p before hevc_qsv, which then fails because
    ; hevc_qsv requires nv12. Must be removed so format=nv12 from the
    ; filter injection is the only pixel format directive.
    ;
    ; -c:v libx265 is harmless (later -c:v hevc_qsv in overrideArgs wins)
    ; but strip for a clean assembled command.
    ; ------------------------------------------------------------------
    preamble := RegExReplace(preamble, "\s*-pix_fmt\s+\S+", "")
    preamble := RegExReplace(preamble, "\s*-c:v\s+libx265", "")
    LogDebug("BuildOverriddenArgs: preamble after strip=" . preamble, cfg)

    ; ------------------------------------------------------------------
    ; Extract output path = last quoted argument (the .mp4 output file).
    ; InStr with negative StartingPos searches backward from end.
    ; Occurrence 1 from end  = closing quote of output path.
    ; Occurrence 2 from end  = opening quote of output path.
    ; ------------------------------------------------------------------
    ; Find last quoted output path anchored to end of string
    if !RegExMatch(args, '"[^"]+"\s*$', &mOutPath) {
        LogDebug("BuildOverriddenArgs: output path not found", cfg)
        return ""
    }
    outPath := Trim(mOutPath[0])
    LogDebug("BuildOverriddenArgs: outPath=" . outPath, cfg)

    ; -init_hw_device is NOT prepended:
    ; With --enable-libvpl (oneVPL SDK), explicit qsv=qsv0 D3D11 device creation
    ; fails with E_INVALIDARG (80070057) on Intel Iris Xe.
    ; libvpl auto-discovers the Intel device when hevc_qsv encoder initializes.
    ; Explicit init is only needed for hwaccel decode paths, not pipe (software) input.

    ; Assemble: preamble_with_format_nv12 + override_encoding_args + "output.mp4"
    return RTrim(preamble) . " " . RTrim(overrideArgs) . " " . outPath
}


; ==============================================================================
; FUNCTION: BuildTmixArgs
; Given original FlowFrames args (libx265 encoding command), builds a new
; command that blends sourceFps frames down to TargetFps using ffmpeg tmix,
; then encodes with tmixBlending.EncodingArgs.
;
; Source fps is auto-detected from -r N/1 in the incoming args (always present
; in FlowFrames pipe commands). Target fps and blend weights come from config.
; Blend frame count = sourceFps / TargetFps  (must be integer; warns if not).
;
; tmix filter is injected into the existing filter_complex chain, appended
; after format=<PixelFormat>. fps= filter follows tmix to set output rate.
; NOTE: tmix output frame n is the average of input frames (n-frames+1)..n,
; and fps=T then samples that sliding average down to the target rate.
;
; Returns the fully constructed args string, or "" on failure.
; ==============================================================================
BuildTmixArgs(args, cfg) {

    ; --- Extract mapLabel and preamble (same logic as BuildOverriddenArgs) ---
    mapMatchPos := RegExMatch(args, "-map \[([^\]]+)\]", &mapObj)
    LogDebug("BuildTmixArgs: mapMatchPos=" . mapMatchPos, cfg)
    if !mapMatchPos
        return ""

    mapLabel := mapObj[1]
    LogDebug("BuildTmixArgs: mapLabel=" . mapLabel, cfg)

    preamble := SubStr(args, 1, mapMatchPos + mapObj.Len - 1)
    LogDebug("BuildTmixArgs: preamble=" . preamble, cfg)

    ; --- Detect source fps from -r N or -r N/1 in incoming args ---
    sourceFps := 0
    if RegExMatch(args, "-r\s+(\d+)(?:/\d+)?", &mFps)
        sourceFps := Integer(mFps[1])
    LogDebug("BuildTmixArgs: sourceFps=" . sourceFps, cfg)

    targetFps := Integer(cfg.tmixTargetFps)

    if sourceFps = 0 {
        Log("ERROR: BuildTmixArgs: could not detect source fps from -r in args", cfg)
        return ""
    }
    if targetFps = 0 {
        Log("ERROR: BuildTmixArgs: TargetFps is 0 or missing in config", cfg)
        return ""
    }
    if sourceFps < targetFps {
        Log("ERROR: BuildTmixArgs: sourceFps (" . sourceFps . ") < targetFps (" . targetFps . ") - cannot downsample", cfg)
        return ""
    }

    blendFrames := sourceFps // targetFps
    if Mod(sourceFps, targetFps) != 0
        Log("WARNING: BuildTmixArgs: " . sourceFps . "/" . targetFps . " is not an integer ratio"
            . " - using floor " . blendFrames . " (actual output fps will be " . (sourceFps // blendFrames) . ")", cfg)

    ; --- Validate blend weight count matches blendFrames ---
    weightCount := StrSplit(cfg.tmixBlendWeights, ",").Length
    if weightCount != blendFrames
        Log("WARNING: BuildTmixArgs: BlendWeights count (" . weightCount . ") != sourceFps/TargetFps ("
            . blendFrames . ") - tmix will error or blend unexpectedly", cfg)

    ; --- Build the tmix filter string ---
    ; CRITICAL (Windows): weights with spaces (e.g. weights='1 1 1 1 1') get
    ; shattered by CreateProcess/CommandLineToArgvW tokenisation, so ffmpeg sees
    ; stray "1" tokens and aborts ("Unable to find a suitable output format for
    ; '1'"). Two defences:
    ;   1) When all weights are "1", emit NO weights= option at all. tmix with no
    ;      weights averages frames equally, which is identical to all-ones - and
    ;      the filtergraph then contains no spaces. This is the common case.
    ;   2) For non-uniform weights, emit space-separated weights AND double-quote
    ;      the whole -filter_complex value below so the spaces survive.
    weightsList := StrSplit(cfg.tmixBlendWeights, ",")
    allOnes := true
    Loop weightsList.Length {
        if Trim(weightsList[A_Index]) != "1" {
            allOnes := false
            break
        }
    }
    if allOnes
        tmixFilter := "tmix=frames=" . blendFrames
    else
        tmixFilter := "tmix=frames=" . blendFrames . ":weights='" . StrReplace(cfg.tmixBlendWeights, ",", " ") . "'"

    ; --- Inject tmix + fps + format into the filter_complex pad= chain ---
    ; Order matters for quality: blend (tmix) and decimate (fps) in the source
    ; bit depth (the pipe is yuv444p16 from RIFE), THEN convert to the 8-bit
    ; encoder format LAST. Full sequence:
    ;   ...[x]pad=<params>,tmix=frames=N[:weights='..'],fps=T,format=<pf>[mapLabel]
    preamble := RegExReplace(preamble,
        "(\[[^\]]+\]pad=[^\[]+)\[" . mapLabel . "\]",
        "$1," . tmixFilter . ",fps=" . targetFps . ",format=" . cfg.tmixPixelFormat . "[" . mapLabel . "]")

    ; --- Double-quote the -filter_complex VALUE so any spaces (non-uniform
    ;     weights) survive Windows command-line tokenisation by ffmpeg_real.exe.
    ;     Harmless when there are no spaces. ---
    preamble := RegExReplace(preamble, '-filter_complex\s+(\S.*?)\s+-map\s', '-filter_complex "$1" -map ')

    ; --- Strip encoder options that may land in preamble (DAIN-style commands) ---
    preamble := RegExReplace(preamble, "\s*-pix_fmt\s+\S+", "")
    preamble := RegExReplace(preamble, "\s*-c:v\s+libx265", "")
    ; NOTE: any -r in the preamble is an INPUT option describing the true rate
    ; of the incoming pipe (e.g. 300fps RIFE stream) and must stay untouched;
    ; the fps=<TargetFps> filter governs the output rate, and encoder-side
    ; options between -map and the output path are discarded anyway.
    LogDebug("BuildTmixArgs: preamble after inject=" . preamble, cfg)

    ; --- Extract output path = last quoted argument ---
    if !RegExMatch(args, '"[^"]+"\s*$', &mOutPath) {
        LogDebug("BuildTmixArgs: output path not found", cfg)
        return ""
    }
    outPath := Trim(mOutPath[0])
    LogDebug("BuildTmixArgs: outPath=" . outPath, cfg)

    Log("BuildTmixArgs: " . sourceFps . "fps -> " . tmixFilter . ",fps=" . targetFps
        . ",format=" . cfg.tmixPixelFormat . " -> " . targetFps . "fps", cfg)

    return RTrim(preamble) . " " . RTrim(cfg.tmixArgs) . " " . outPath
}


; ==============================================================================
; MAIN SCRIPT
; ==============================================================================

; --- Load configuration ---
cfg := ParseConfig()

; --- Parse our own command line, strip exe path to get raw args ---
rawCmdLine := StrGet(DllCall("GetCommandLineW", "Ptr"), "UTF-16")
if SubStr(rawCmdLine, 1, 1) = '"' {
    closeQuote := InStr(rawCmdLine, '"', , 2)
    args := LTrim(SubStr(rawCmdLine, closeQuote + 1))
} else {
    args := LTrim(SubStr(rawCmdLine, InStr(rawCmdLine, " ")))
}

; --- Log rotation: overwrite log at start of each new video session ---
; The very first FlowFrames call for any video is a bare probe:
;   ffmpeg -hide_banner -y -i "file.mp4"   (nothing after the quoted input)
; All subsequent calls carry additional flags (-stats, -vf, pipe:, etc.)
if RegExMatch(args, "^-hide_banner\b") && InStr(args, "-y") && RegExMatch(args, "-i\s+\x22[^\x22]+\x22\s*$")
    if FileExist(LogFile)
        FileDelete(LogFile)

; --- Log startup ---
Log("==== ffmpeg wrapper start ====", cfg)
Log("our PID:      " . DllCall("Kernel32\GetCurrentProcessId", "UInt"), cfg)
LogDebug("A_ScriptDir:  " . A_ScriptDir, cfg)
LogDebug("A_WorkingDir: " . A_WorkingDir, cfg)
Log("args:         " . args, cfg)

; Save original args for logging before any modification
originalArgs := args

; ==============================================================================
; MAIN DECISION: is this a FlowFrames H.265 (libx265) encoding command?
; FlowFrames encodes interpolated frames using libx265 by default.
; We detect this by the presence of "-c:v libx265" in the args.
; ==============================================================================
if InStr(args, "-c:v libx265") {

    ; ==========================================================================
    ; BRANCH: H.265 (libx265) encoding command detected
    ; ==========================================================================
    Log("H.265 encoding command detected (-c:v libx265).", cfg)

    ; --- Step 1: defer to the y4m header for framerate (replaces PipeFramerateFix) ---
    ; vspipe writes the TRUE output fps into the y4m header from the clip's fps
    ; property (set by the script's AssumeFPS / decimation). FlowFrames prepends a
    ; stale "-r <rife_rate>/1" that OVERRIDES that header and mis-tags the output
    ; whenever the script downsampled. Rather than guess the script's behaviour from
    ; the sibling config - impossible for a custom OverrideVspipeScript - we strip the
    ; stale INPUT -r and let ffmpeg read the header. Source-agnostic: injected
    ; averaging, custom scripts, tmix and plain RIFE all tag correctly. (avgInfo is
    ; still read below, now only for double-blend CONFLICT detection, not for rate.)
    avgInfo := GetVspipeAvgInfo(cfg)
    isPipeInput := RegExMatch(args, "i)-i\s+(\x22?-\x22?|pipe:)") ? true : false
    LogDebug("pipe input detected: " . (isPipeInput ? "yes" : "no"), cfg)

    if isPipeInput {
        ; Only strip the stale input -r when NOT doing tmix.
        ; BuildTmixArgs reads -r to compute blendFrames = sourceFps/targetFps;
        ; when tmix is active the input stream is at the raw RIFE rate so -r is correct.
        ; When tmix is not active, the vpy may have already downsampled and the y4m
        ; header carries the true rate — the stale FlowFrames -r must be dropped.
        if !cfg.tmixEnable {
            nStripped := 0
            args := RegExReplace(args, "i)-r\s+\d+(?:/\d+)?\s+(-i\s+(?:pipe:|-|\x22))", "$1", &nStripped)
            if nStripped > 0
                Log("Framerate: stripped stale FlowFrames input -r; deferring to vspipe's y4m header.", cfg)
        } else {
            LogDebug("Framerate: input -r retained (tmixBlending active - needed for blendFrames calc).", cfg)
        }
    }

    ; --- Step 2: conflict checks for tmixBlending ---
    ; tmixBlending operates on the incoming stream's blend state. If we cannot
    ; determine whether the stream is already blended (config unreadable) or know
    ; it is (AverageFrames or OverrideVspipeScript active), we abort loudly rather
    ; than silently ship a double-blended or incorrectly rated file.
    if cfg.tmixEnable {
        if !avgInfo.found {
            msg := "ffmpeg_wrapper CONFIG CONFLICT:`n`n"
                 . "  tmixBlending.Enable = True`n"
                 . "  vspipe config NOT FOUND at:`n"
                 . "  " . avgInfo.path . "`n`n"
                 . "Blend state of the incoming stream cannot be verified."
                 . " Disable tmixBlending, or set VspipeConfigPath to the correct"
                 . " vspipe_wrapper_config.json location."
            Log("ABORT: " . msg, cfg)
            MsgBox(msg, "ffmpeg_wrapper conflict", 16)
            DllCall("ExitProcess", "UInt", 1)
        }
        if avgInfo.overrideEnabled {
            msg := "ffmpeg_wrapper CONFIG CONFLICT:`n`n"
                 . "  tmixBlending.Enable             = True`n"
                 . "  OverrideVspipeScript.Enable     = True  (vspipe config)`n`n"
                 . "The custom script's blend state is unknown; applying tmix on top"
                 . " may double-blend.`n`n"
                 . "Disable tmixBlending or OverrideVspipeScript."
            Log("ABORT: " . msg, cfg)
            MsgBox(msg, "ffmpeg_wrapper conflict", 16)
            DllCall("ExitProcess", "UInt", 1)
        }
        if avgInfo.avgEnabled {
            msg := "ffmpeg_wrapper CONFIG CONFLICT:`n`n"
                 . "  tmixBlending.Enable         = True`n"
                 . "  AverageFrames.Enable        = True  (vspipe config)`n`n"
                 . "The stream is already motion-blended by VapourSynth AverageFrames."
                 . " Applying tmix on top would double-blend.`n`n"
                 . "Disable one of the two blend methods."
            Log("ABORT: " . msg, cfg)
            MsgBox(msg, "ffmpeg_wrapper conflict", 16)
            DllCall("ExitProcess", "UInt", 1)
        }
    }

    ; --- tmixBlending takes priority over OverrideH265Encoding ---
    tmixActive := cfg.tmixEnable
    if tmixActive {

        ; ----------------------------------------------------------------------
        ; tmixBlending.Enable = True
        ; ----------------------------------------------------------------------
        if cfg.h265Enable
            Log("NOTE: Both tmixBlending and OverrideH265Encoding are enabled - tmixBlending takes priority.", cfg)

        newArgs := BuildTmixArgs(args, cfg)

        if newArgs != "" {
            Log("Applying tmix blend+downsample (tmixBlending.Enable = True).", cfg)
            Log("Received FFmpeg command:", cfg)
            Log("  '" . originalArgs . "'", cfg)
            Log("Replaced FFmpeg command:", cfg)
            Log("  '" . newArgs . "'", cfg)
            args := newArgs
        } else {
            Log("WARNING: Could not build tmix command. Proceeding with original Flowframes command:", cfg)
            Log("  '" . originalArgs . "'", cfg)
        }
        goto ExecuteReal

    } else if cfg.h265Enable {

        ; ----------------------------------------------------------------------
        ; OverrideH265Encoding.Enable = True
        ; ----------------------------------------------------------------------

        ; --- Check if EncodingArgs is non-empty ---
        if cfg.h265Args != "" {

            ; --- Determine what codec EncodingArgs specifies ---
            ; Find the LAST occurrence of -c:v in EncodingArgs
            ; (last wins in ffmpeg, consistent with how FlowFrames stacks args)
            configuredCodec := ""
            pos := 1
            while (found := RegExMatch(cfg.h265Args, "-c:v\s+(\S+)", &m, pos)) {
                configuredCodec := m[1]
                pos := found + 1
            }

            if configuredCodec = "" {
                ; ---------------------------------------------------------------
                ; No -c:v found in EncodingArgs at all
                ; ---------------------------------------------------------------
                Log("ERROR: 'EncodingArgs' in OverrideH265Encoding does not contain '-c:v <CodecName>'.", cfg)
                Log("       FFmpeg wrapper will proceed with original Flowframes command:", cfg)
                Log("       '" . originalArgs . "'", cfg)

                ; Fall through to pass-through execution below

            } else if (configuredCodec != "hevc_qsv"
                    && configuredCodec != "hevc_nvenc"
                    && configuredCodec != "h264_nvenc"
                    && configuredCodec != "av1_nvenc") {
                ; ---------------------------------------------------------------
                ; -c:v present but not a supported hardware encoder.
                ; Allow-list (not allow-anything) so config typos are still caught.
                ; QSV = Intel machines; NVENC = Nvidia machines. BuildOverriddenArgs
                ; is codec-agnostic (substitutes EncodingArgs verbatim + injects
                ; format=<PixelFormat>), so any of these route the same proven path.
                ; For NVENC set PixelFormat to a format NVENC accepts directly
                ; (e.g. yuv444p16le / p010le) — the injection is NOT skipped, it
                ; just emits your configured format instead of nv12.
                ; ---------------------------------------------------------------
                Log("ERROR: Configured codec '" . configuredCodec . "' in OverrideH265Encoding is not supported.", cfg)
                Log("       Supported: hevc_qsv, hevc_nvenc, h264_nvenc, av1_nvenc.", cfg)
                Log("       FFmpeg wrapper will proceed with original Flowframes command:", cfg)
                Log("       '" . originalArgs . "'", cfg)

            } else {
                ; ---------------------------------------------------------------
                ; hevc_qsv confirmed - build overridden args and execute
                ; ---------------------------------------------------------------
                newArgs := BuildOverriddenArgs(args, cfg.h265Args, cfg)

                if newArgs != "" {
                    ; Override built successfully - log and apply
                    Log("Overriding Flowframes FFmpeg command (OverrideH265Encoding.Enable = True).", cfg)
                    Log("Received FFmpeg command:", cfg)
                    Log("  '" . originalArgs . "'", cfg)
                    Log("Replaced FFmpeg command:", cfg)
                    Log("  '" . newArgs . "'", cfg)
                    args := newArgs
                } else {
                    ; BuildOverriddenArgs failed to parse the command structure
                    Log("WARNING: Could not parse command structure for override. Proceeding with original Flowframes command:", cfg)
                    Log("  '" . originalArgs . "'", cfg)
                    ; args stays unchanged - ffmpeg_real gets original FlowFrames command
                }
                goto ExecuteReal
            }

        } else {
            ; ------------------------------------------------------------------
            ; EncodingArgs is empty
            ; ------------------------------------------------------------------
            Log("WARNING: 'EncodingArgs' in OverrideH265Encoding is empty.", cfg)
            Log("         FFmpeg wrapper will proceed with original Flowframes command:", cfg)
            Log("         '" . originalArgs . "'", cfg)
        }

    } else {
        ; ----------------------------------------------------------------------
        ; Both overrides disabled
        ; ----------------------------------------------------------------------
        Log("Override disabled (OverrideH265Encoding.Enable = False, tmixBlending inactive).", cfg)
        Log("Received FFmpeg command:", cfg)
        Log("  '" . originalArgs . "'", cfg)
        Log("FFmpeg wrapper will proceed with original Flowframes command.", cfg)
    }

} else {
    ; ==========================================================================
    ; BRANCH: Not an H.265 encoding command (probe, thumbnail, mux, etc.)
    ; Pass through to ffmpeg_real unchanged.
    ; ==========================================================================
    Log("Non-encoding FFmpeg command (no -c:v libx265).", cfg)
    Log("Received FFmpeg command:", cfg)
    Log("  '" . originalArgs . "'", cfg)
    Log("FFmpeg wrapper will proceed with original Flowframes command:", cfg)
    Log("  '" . args . "'", cfg)
}

; ==============================================================================
; ExecuteReal:
; Run ffmpeg_real.exe with the (possibly modified) args and correct workDir.
; This label is jumped to from the hevc_qsv success branch above.
; ==============================================================================
ExecuteReal:

; --- Resolve correct working directory ---
; AHK compiled exes change CWD to A_ScriptDir (pkgs\av) on startup.
; FlowFrames sets the working dir per-command via cmd.exe's cd /D.
; We must read the parent's actual CWD - see GetParentCurrentDir() header.
workDir := GetParentCurrentDir(cfg)
LogDebug("workDir: " . workDir, cfg)
Log("launching ffmpeg_real.exe ...", cfg)

; RunWait:
;   Param 1: command line - full path quoted + args
;   Param 2: workDir     - working directory for the child process
;   Param 3: (empty)     - window mode; omitted = inherit console (no Hide flag,
;                          FlowFrames owns the console and handles visibility)
;   Param 4: &ExitCode   - receives child process exit code (passed by reference)
ExitCode := 0
RunWait('"' . RealFfmpeg . '" ' . args, workDir,, &ExitCode)

Log("exit code: " . ExitCode, cfg)
Log("", cfg)  ; blank separator line between sessions in the log

; Exit with the same code ffmpeg_real returned - FlowFrames checks exit codes
DllCall("ExitProcess", "UInt", ExitCode)


; ==============================================================================
; FUNCTION: StripJsonComments
; Removes // line comments and /* */ block comments so the config can be JSONC.
; STRING-AWARE: // or /* inside a quoted value is left untouched, and a
; commented-out line like  // "Enable": "False"  cannot be mis-matched by the
; key regexes. Backslash escapes inside strings are honored so "C:\\x" is safe.
; ==============================================================================
StripJsonComments(text) {
    result := ""
    len := StrLen(text)
    i := 1
    inString := false
    while (i <= len) {
        c  := SubStr(text, i, 1)
        c2 := (i < len) ? SubStr(text, i + 1, 1) : ""
        if (inString) {
            result .= c
            if (c = Chr(92)) {
                result .= c2
                i += 2
                continue
            }
            if (c = '"')
                inString := false
            i += 1
            continue
        }
        if (c = '"') {
            inString := true
            result .= c
            i += 1
            continue
        }
        if (c = "/" && c2 = "/") {
            while (i <= len && SubStr(text, i, 1) != "`n")
                i += 1
            continue
        }
        if (c = "/" && c2 = "*") {
            i += 2
            while (i <= len && !(SubStr(text, i, 1) = "*" && SubStr(text, i + 1, 1) = "/"))
                i += 1
            i += 2
            continue
        }
        result .= c
        i += 1
    }
    return result
}


; ==============================================================================
; FUNCTION: JsonUnescape
; Converts JSON string-body escapes to literal characters. Required for
; EncodingArgs values that embed quotes - e.g. -metadata key="a b c" - which are
; written as \" in the JSON source. The escape-aware capture in ParseConfig keeps
; the \" sequences intact; this turns them back into real quotes so ffmpeg's
; argument parser sees quote-delimited values instead of literal backslash-quotes.
; Handles \\ and \" (the only escapes EncodingArgs uses); the placeholder ordering
; prevents a restored backslash from being re-read as the start of an escape.
; ==============================================================================
JsonUnescape(s) {
    s := StrReplace(s, '\\', Chr(1))   ; protect literal backslashes
    s := StrReplace(s, '\"', '"')       ; \" -> "
    s := StrReplace(s, Chr(1), '\')     ; restore backslashes
    return s
}


; ==============================================================================
; FUNCTION: ResolvePath
; Resolves VspipeConfigPath to an absolute filesystem path.
;   absolute:  C:\full\path\config.json        -> used as-is
;   %env%:     %LocalAppData%\...\config.json   -> ExpandEnvironmentStringsW
;   relative:  subdir\config.json               -> A_ScriptDir + "\" + raw
; ==============================================================================
ResolvePath(raw) {
    expanded := Buffer(2048, 0)
    DllCall("Kernel32\ExpandEnvironmentStringsW", "Str", raw, "Ptr", expanded, "UInt", 1024, "UInt")
    result := StrGet(expanded, "UTF-16")
    if !RegExMatch(result, "^[A-Za-z]:\\|^\\\\")
        result := A_ScriptDir . "\" . result
    return result
}
