; ==============================================================================
; ffmpeg_wrapper.ahk
; Intercepts FlowFrames FFmpeg calls and optionally overrides H.265 encoding
; with configurable parameters (e.g. hevc_qsv for Intel Quick Sync Video).
;
; Deployment:
;   1. Rename original ffmpeg.exe -> ffmpeg_real.exe  (same pkgs\av folder)
;   2. Compile THIS script as ffmpeg.exe (64-bit, see below)
;   3. Place ffmpeg_wrapper_config.json alongside ffmpeg.exe
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
;   .enable         (bool)  - OverrideH265EncodingEnable
;   .overrideArgs   (str)   - OverrideEncodingArgs
;   .logEnable      (bool)  - LogEnable
;   .debugLogEnable (bool)  - DebugLogEnable
; ==============================================================================
ParseConfig() {
    global ConfigFile

    ; Defaults - all features off if config missing or malformed
    cfg := {
        enable:         false,
        overrideArgs:   "",
        logEnable:      false,
        debugLogEnable: false
    }

    if !FileExist(ConfigFile)
        return cfg

    ; Read entire file as UTF-8 text
    json := FileRead(ConfigFile, "UTF-8")

    ; --- OverrideH265EncodingEnable ---
    ; Matches: "OverrideH265EncodingEnable": "True"  (case-sensitive value)
    if RegExMatch(json, '"OverrideH265EncodingEnable"\s*:\s*"([^"]+)"', &m)
        cfg.enable := (m[1] = "True")

    ; --- OverrideEncodingArgs ---
    ; The value may contain spaces and ffmpeg flags - captured by [^"]+ (no quote chars)
    if RegExMatch(json, '"OverrideEncodingArgs"\s*:\s*"([^"]+)"', &m)
        cfg.overrideArgs := Trim(m[1])

    ; --- LogEnable ---
    if RegExMatch(json, '"LogEnable"\s*:\s*"([^"]+)"', &m)
        cfg.logEnable := (m[1] = "True")

    ; --- DebugLogEnable ---
    if RegExMatch(json, '"DebugLogEnable"\s*:\s*"([^"]+)"', &m)
        cfg.debugLogEnable := (m[1] = "True")

    return cfg
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
    ; Inject format=nv12 into the existing filter_complex pad chain.
    ; Pattern:  [<any>]pad=<params>[<mapLabel>]
    ; Becomes:  [<any>]pad=<params>,format=nv12[<mapLabel>]
    ;
    ; Uses the captured mapLabel so the match target and replacement label
    ; are always consistent regardless of what label FlowFrames uses.
    ; The pad operation produces yuv444p 16le from the VapourSynth pipe.
    ; Appending ,format=nv12 converts to nv12 inline within the existing
    ; filter graph - avoids needing a separate -vf which would conflict
    ; with the already-present -filter_complex.
    ; ------------------------------------------------------------------
    preamble := RegExReplace(preamble, "(\[[^\]]+\]pad=[^\[]+)\[" . mapLabel . "\]", "$1,format=nv12[" . mapLabel . "]")

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

    ; --- Check if override is enabled in config ---
    if cfg.enable {

        ; --- Check if OverrideEncodingArgs is non-empty ---
        if cfg.overrideArgs != "" {

            ; --- Determine what codec OverrideEncodingArgs specifies ---
            ; Find the LAST occurrence of -c:v in OverrideEncodingArgs
            ; (last wins in ffmpeg, consistent with how FlowFrames stacks args)
            configuredCodec := ""
            pos := 1
            while (found := RegExMatch(cfg.overrideArgs, "-c:v\s+(\S+)", &m, pos)) {
                configuredCodec := m[1]
                pos := found + 1
            }

            if configuredCodec = "" {
                ; ---------------------------------------------------------------
                ; No -c:v found in OverrideEncodingArgs at all
                ; ---------------------------------------------------------------
                Log("ERROR: 'OverrideEncodingArgs' in ffmpeg_wrapper_config.json does not contain '-c:v <CodecName>'.", cfg)
                Log("       FFmpeg wrapper will proceed with original Flowframes command:", cfg)
                Log("       '" . originalArgs . "'", cfg)

                ; Fall through to pass-through execution below

            } else if configuredCodec != "hevc_qsv" {
                ; ---------------------------------------------------------------
                ; -c:v is present but not hevc_qsv - unsupported codec
                ; ---------------------------------------------------------------
                Log("ERROR: Configured codec '" . configuredCodec . "' in 'ffmpeg_wrapper_config.json' is not supported.", cfg)
                Log("       FFmpeg wrapper currently supports only 'hevc_qsv' codec.", cfg)
                Log("       FFmpeg wrapper will proceed with original Flowframes command:", cfg)
                Log("       '" . originalArgs . "'", cfg)

            } else {
                ; ---------------------------------------------------------------
                ; hevc_qsv confirmed - build overridden args and execute
                ; ---------------------------------------------------------------
                newArgs := BuildOverriddenArgs(args, cfg.overrideArgs, cfg)

                if newArgs != "" {
                    ; Override built successfully - log and apply
                    Log("Overriding Flowframes FFmpeg command (OverrideH265EncodingEnable = True).", cfg)
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
            ; OverrideEncodingArgs is empty
            ; ------------------------------------------------------------------
            Log("WARNING: 'OverrideEncodingArgs' in ffmpeg_wrapper_config.json is empty.", cfg)
            Log("         FFmpeg wrapper will proceed with original Flowframes command:", cfg)
            Log("         '" . originalArgs . "'", cfg)
        }

    } else {
        ; ----------------------------------------------------------------------
        ; OverrideH265EncodingEnable = False - override disabled in config
        ; ----------------------------------------------------------------------
        Log("Override disabled (OverrideH265EncodingEnable = False).", cfg)
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
