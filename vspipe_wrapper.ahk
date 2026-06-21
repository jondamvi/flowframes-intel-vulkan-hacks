;@Ahk2Exe-ConsoleApp
; ==============================================================================
; vspipe_wrapper.ahk  —  VSPipe wrapper for FlowFrames v1.40
; ==============================================================================
;
; PURPOSE:
;   FlowFrames v1.40 generates rife.vpy with the legacy  multiplier=X  parameter.
;   Newer RIFE DLLs (from r9_mod_v33 / v1.42 packages) removed multiplier= and
;   require factor_num=N, factor_den=D  instead. This wrapper intercepts the
;   vspipe call, patches the vpy file in-place, then launches VSPipe_real.exe
;   with the original arguments unchanged.
;
; DEPLOYMENT:
;   1. Rename  VSPipe.exe  ->  VSPipe_real.exe  (in rife-ncnn-vs\)
;   2. Compile this as 64-bit CONSOLE app via Ahk2Exe -> VSPipe.exe
;      Base: AutoHotkey64.exe  (MUST be 64-bit, MUST use @Ahk2Exe-ConsoleApp)
;   3. Place compiled VSPipe.exe in the same rife-ncnn-vs\ folder
;   4. Optionally place vspipe_wrapper_config.json next to VSPipe.exe
;      (if absent, built-in defaults are used — behaviour identical to before)
;
; WHAT IT DOES:
;   - Reads optional vspipe_wrapper_config.json for runtime settings
;   - Finds the .vpy path in the command-line args
;   - If OverrideVspipeScript.Enable=True: passes the override .vpy path to VSPipe_real
;     instead of the FlowFrames-generated rife.vpy (non-destructive path-swap);
;     skips all other patches, launches VSPipe_real.exe and exits
;   - Otherwise applies patches to the FlowFrames-generated vpy:
;       1. cMatrix guard: 'rgb' is never a valid TARGET matrix for the
;          post-RIFE RGB->YUV conversion; remap to '709' (RGB source safety)
;       2. model_path override  (if OverrideModel.Enable=True)
;       3. multiplier=X  ->  factor_num=N, factor_den=D
;       4. AverageFrames + SelectEvery injection AFTER the YUV444P16
;          conversion line (if AverageFrames.Enable=True)
;          NOTE: injection point is deliberately after resize.Bicubic(
;          format=vs.YUV444P16, matrix_s=cMatrix). The R57-era core has a
;          broken float-input path in AverageFrames (fixed upstream in r59:
;          "fixed averageframes weights with float input") which produces
;          horizontal-stripe corruption on RIFE's RGBS output. Averaging in
;          integer YUV444P16 avoids that code path entirely and inherits the
;          correct cMatrix tagging from the vendor's own conversion line.
;          Weights/Scale MUST therefore be integers (validated; injection is
;          skipped with an ERROR log if any weight is fractional).
;       5. Debug stage logging injection (if DebugLogEnable=True):
;          a _dbg() helper + per-stage probes writing resolution, pixel
;          format, color family/bits/subsampling, frame count, fps and
;          frame-0 props (_Matrix/_Primaries/_Transfer/_ColorRange/SAR/
;          scene-change flags) to rife_vpy_debug.log next to the wrapper
;       6. single-quote fix in inputPath
;   - Launches VSPipe_real.exe with all original arguments
;   - Exits with VSPipe_real.exe's exit code
;
; MULTIPLIER CONVERSION EXAMPLES:
;   multiplier=2   -> factor_num=2,  factor_den=1
;   multiplier=2.4 -> factor_num=12, factor_den=5   (12/5 = 2.4)
;   multiplier=2.5 -> factor_num=5,  factor_den=2
;   multiplier=1.5 -> factor_num=3,  factor_den=2
;
; CONFIG FILE: vspipe_wrapper_config.json  (place next to VSPipe.exe)
;   {
;     "LogEnable": "True",
;     "DebugLogEnable": "False",
;     "OverrideModel": {
;       "Enable": "False",
;       "ModelDirName": ""
;     },
;     "AverageFrames": {
;       "Enable": "False",
;       "Weights": "1,1,1,1,1",
;       "Scale": "5",
;       "Scenechange": "False",
;       "SCDetectThreshold": "0.07",
;       "SelectEvery": {
;         "Cycle": "5",
;         "Offsets": "2"
;       }
;     },
;     "OverrideVspipeScript": {
;       "Enable": "False",
;       "Path": ""
;     }
;   }
;   LogEnable                    : "True"/"False" - write vspipe_wrapper.log (default: True)
;   DebugLogEnable               : "True"/"False" - inject per-stage stream logging into
;                                  the vpy; writes rife_vpy_debug.log next to the wrapper.
;                                  Each stage logs: WxH, format name, color family, bit
;                                  depth, sample type, subsampling, frame count, fps, and
;                                  frame-0 props. Costs one rendered frame per probed
;                                  stage at script evaluation (default: False)
;   OverrideModel.Enable         : "True"/"False" - replace model dir in model_path= (default: False)
;   OverrideModel.ModelDirName   : dir name, e.g. "rife-v4.24_ensembleTrue"
;   AverageFrames.Enable         : "True"/"False" - inject blend+downsample after the
;                                  YUV444P16 conversion line (default: False)
;   AverageFrames.Weights        : comma-separated INTEGER weights, e.g. "1,1,1,1,1"
;                                  (integer YUV averaging path; fractional weights are
;                                  rejected and injection is skipped)
;   AverageFrames.Scale          : integer divisor, normally sum of weights, e.g. "5"
;   AverageFrames.Scenechange    : "True"/"False" - re-run misc.SCDetect after the YUV
;                                  conversion and pass scenechange=True to AverageFrames
;                                  so blend windows never cross a cut. CAUTION: upstream
;                                  r58 fixed "averageframes not respecting scenechange
;                                  property" - on an R57-line core this may be a no-op.
;                                  Verify with DebugLogEnable + visual check (default: False)
;   AverageFrames.SCDetectThreshold : threshold for the re-run SCDetect, e.g. "0.07"
;   AverageFrames.PhaseSplit     : "True"/"False" (default False). False = single-clip
;                                  centered AverageFrames + SelectEvery (odd weight count,
;                                  uses Scenechange). True = multi-clip PHASE-SPLIT: the
;                                  stream is split into <Cycle> phase lanes averaged in
;                                  multi-clip mode, so every frame is used exactly once
;                                  (none dropped/overlapped) and EVEN cycles are allowed.
;                                  In phase mode the weight COUNT must equal Cycle (one
;                                  weight per phase; all-ones = uniform full blend, or zero
;                                  out lanes for a partial-window / shutter-angle blend),
;                                  Offsets is ignored, and Scenechange does not apply
;                                  (multi-clip has no scene handling; moot on R57 where
;                                  scenechange is broken until r60 anyway).
;   AverageFrames.SelectEvery.Cycle   : output one frame per N input frames, e.g. "5"
;   AverageFrames.SelectEvery.Offsets : comma-separated frame offsets to keep, e.g. "2".
;                                  With a centered 5-weight window, offset 2 aligns the
;                                  blend windows to clean non-overlapping [0-4][5-9]...
;                                  tiling; offset 0 would blend across tile boundaries
;                                  and clamp at clip edges.
;   OverrideVspipeScript.Enable  : "True"/"False" - point VSPipe_real at an external .vpy instead of the
;                                  FlowFrames-generated rife.vpy. Non-destructive: rife.vpy is left
;                                  intact; only the path argument to VSPipe_real is swapped.
;                                  ALL patches (AverageFrames, model override, etc.) are skipped.
;                                  CONFLICT: Enable=True + AverageFrames.Enable=True → abort (the
;                                  patch would have no effect since patching is skipped; contradictory
;                                  intent — abort loudly rather than silently ignore one setting).
;   OverrideVspipeScript.Path    : path to the override .vpy. Accepts:
;                                    absolute:  C:\full\path\to\script.vpy
;                                    relative:  relative to the wrapper exe dir (A_ScriptDir)
;                                    %env%:     %LocalAppData%\...\script.vpy
;                                  Empty string or file not found → abort with MsgBox (misconfiguration).
;   Missing file or missing keys silently fall back to built-in defaults.
;
; LOG FILE:
;   vspipe_wrapper.log in the same folder as the wrapper exe.
;   Rotated (deleted) at the start of each new session (once per process).
;   Suppressed entirely when LogEnable=False.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off

; --- Built-in defaults (used when config key is missing or file absent) ---
global CFG_LogEnable              := true
global CFG_DebugLogEnable         := false
global CFG_OverrideModelEnable    := false
global CFG_OverrideModelDirName   := ""
global CFG_AvgFramesEnable        := false
global CFG_AvgFramesWeights       := "1,1,1,1,1"
global CFG_AvgFramesScale         := "5"
global CFG_AvgScenechange         := false
global CFG_AvgSCThreshold         := "0.07"
global CFG_AvgPhaseSplit          := false
global CFG_SelectEveryCycle       := "5"
global CFG_SelectEveryOffsets     := "2"
global CFG_OverrideScriptEnable   := false
global CFG_OverrideScriptPath     := ""

; --- Upscaling ---
global CFG_UpscaleEnable          := false
global CFG_UpscalePipelinePos     := "after_rife"   ; after_rife | after_average | before_rife
global CFG_UpscaleOutputWidth     := "1920"
global CFG_UpscaleOutputHeight    := "1080"
global CFG_UpscaleMethod          := "RealESRGAN"   ; RealESRGAN | Spline36 | Waifu2x (TODO)
; TODO: non-standard resolution handling (ScaleMode / PadBars / EncodeBars / PadColor)
global CFG_UpscaleScaleMode       := "fit_width"    ; fit_width | fit_height | fill | stretch | exact
global CFG_UpscalePadBars         := false
global CFG_UpscaleEncodeBars      := false
global CFG_UpscalePadColor        := "black"
global CFG_ESRGAN_Model           := "realesrgan-x4plus"
global CFG_ESRGAN_TileWidth       := "256"          ; pixels; small values needed for shared VRAM (Iris Xe)
global CFG_ESRGAN_TileHeight      := "256"
global CFG_ESRGAN_DownsampleFilt  := "spline36"     ; spline36 | lanczos
global CFG_ESRGAN_Tta             := false           ; test-time augmentation; 8x slower, rarely worth it
global CFG_W2X_NoiseLevel         := "1"            ; -1..3
global CFG_W2X_Scale              := "2"
global CFG_W2X_Model              := "cunet"
global CFG_W2X_TileSize           := "0"            ; 0 = auto

; --- ETA tracking (written by PatchVpy, read by LogETA after vspipe exits) ---
global G_OutputFrameCount  := 0   ; output frames after all decimation (from final Trim)
global G_SourceFrameCount  := 0   ; approximate source frames before RIFE
global G_RIFENum           := 1   ; RIFE factor numerator   (from factor_num=)
global G_RIFEDen           := 1   ; RIFE factor denominator (from factor_den=)
global G_InputPath         := ""  ; source video path extracted from inputPath= in vpy

; --- EstimateProcessingTime config ---
; SourceFPS: explicit override. When empty (default), FPS is read automatically from the
;            LWLibavSource .lwi index file at inputPath+".lwi" (created by vspipe on first run).
;            Set explicitly only if .lwi is absent or you use a non-LWLibavSource input plugin.
global CFG_EstimateEnable       := false
global CFG_EstimateSourceFPS    := ""
global CFG_EstimateForClipSecs  := "15,20,30,60,300,600,900,1200"
global CFG_EstimateFullDuration := ""

global LogFile    := A_ScriptDir . "\vspipe_wrapper.log"
global DbgVpyLog  := A_ScriptDir . "\rife_vpy_debug.log"

; --- Load config before anything else ---
LoadConfig()

; Rotate log on each fresh invocation
if CFG_LogEnable && FileExist(LogFile)
    FileDelete(LogFile)

Log("==== vspipe wrapper start ====")
Log("our PID:  " . DllCall("Kernel32\GetCurrentProcessId", "UInt"))
Log("config:   LogEnable=" . (CFG_LogEnable ? "True" : "False")
              . "  DebugLogEnable=" . (CFG_DebugLogEnable ? "True" : "False")
              . "  OverrideModel.Enable=" . (CFG_OverrideModelEnable ? "True" : "False")
              . "  OverrideModel.ModelDirName=" . (CFG_OverrideModelDirName != "" ? CFG_OverrideModelDirName : "(empty)")
              . "  AverageFrames.Enable=" . (CFG_AvgFramesEnable ? "True" : "False")
              . "  AverageFrames.Scenechange=" . (CFG_AvgScenechange ? "True" : "False")
              . "  OverrideVspipeScript.Enable=" . (CFG_OverrideScriptEnable ? "True" : "False"))
Log("raw args: " . ConcatArgs(A_Args))

; --- Locate the .vpy path in the argument list ---
vpyPath := ""
for arg in A_Args {
    if RegExMatch(arg, "i)\.vpy$") {
        vpyPath := arg
        break
    }
}

Log("vpyPath:  " . (vpyPath ? vpyPath : "(not found)"))

; ==============================================================================
; CONFLICT GUARD: OverrideVspipeScript + AverageFrames
; Both enabled simultaneously is contradictory: the override replaces the
; script (skipping all patches including AverageFrames), so AverageFrames.Enable
; would silently have no effect. Abort loudly instead of silently ignoring one.
; ==============================================================================
if CFG_OverrideScriptEnable && CFG_AvgFramesEnable {
    msg := "vspipe_wrapper CONFIG CONFLICT:`n`n"
         . "  OverrideVspipeScript.Enable = True`n"
         . "  AverageFrames.Enable        = True`n`n"
         . "These are mutually exclusive. When OverrideVspipeScript is active,"
         . " all patching (including AverageFrames injection) is skipped.`n`n"
         . "Disable one of the two settings in vspipe_wrapper_config.json."
    Log("ABORT: " . msg)
    MsgBox(msg, "vspipe_wrapper conflict", 16)
    ExitApp(1)
}

; ==============================================================================
; OVERRIDE PATH RESOLUTION
; Resolve OverrideVspipeScript.Path before any patching so we can abort early
; on misconfiguration without touching rife.vpy.
; Accepted forms: absolute (C:\...), relative to wrapper dir, %EnvVar% tokens.
; ==============================================================================
overrideResolved := ""
if CFG_OverrideScriptEnable {
    if CFG_OverrideScriptPath = "" {
        msg := "vspipe_wrapper CONFIG ERROR:`n`n"
             . "  OverrideVspipeScript.Enable = True`n"
             . "  OverrideVspipeScript.Path   = (empty)`n`n"
             . "Set a valid .vpy path in vspipe_wrapper_config.json."
        Log("ABORT: " . msg)
        MsgBox(msg, "vspipe_wrapper error", 16)
        ExitApp(1)
    }
    overrideResolved := ResolvePath(CFG_OverrideScriptPath)
    if !FileExist(overrideResolved) {
        msg := "vspipe_wrapper CONFIG ERROR:`n`n"
             . "  OverrideVspipeScript.Path resolved to:`n"
             . "  " . overrideResolved . "`n`n"
             . "File not found. Check OverrideVspipeScript.Path in vspipe_wrapper_config.json."
        Log("ABORT: " . msg)
        MsgBox(msg, "vspipe_wrapper error", 16)
        ExitApp(1)
    }
    Log("OverrideVspipeScript.Path resolved: " . overrideResolved)
}

; --- Patch or override the vpy file ---
if vpyPath && FileExist(vpyPath) {
    if CFG_OverrideScriptEnable {
        ; Non-destructive path-swap: rife.vpy is left intact.
        ; All patching is skipped — the override script is responsible for its own content.
        Log("OverrideVspipeScript active - all patches skipped; vpy path will be swapped in args")
    } else {
        PatchVpy(vpyPath)
    }
} else {
    Log("WARNING: .vpy not found or does not exist - passing through unmodified")
}

; --- Build command line, swapping vpy path when override is active ---
realExe := A_ScriptDir . "\VSPipe_real.exe"

if CFG_OverrideScriptEnable && overrideResolved != "" && vpyPath != "" {
    ; Replace the vpy path argument with the override path.
    ; vpyPath was extracted directly from A_Args, so string equality is exact.
    swappedArgs := []
    swapped := false
    for arg in A_Args {
        if arg = vpyPath {
            swappedArgs.Push(overrideResolved)
            swapped := true
        } else {
            swappedArgs.Push(arg)
        }
    }
    if swapped {
        cmdLine := BuildCmdLine(swappedArgs)
        Log("path-swap: '" . vpyPath . "' -> '" . overrideResolved . "'")
    } else {
        Log("WARNING: OverrideVspipeScript active but vpy path not found in args - passing original args")
        cmdLine := BuildCmdLine(A_Args)
    }
} else {
    cmdLine := BuildCmdLine(A_Args)
}

fullCmd := '"' . realExe . '" ' . cmdLine

Log("launching: " . fullCmd)

startTick := A_TickCount
exitCode  := RunWait(fullCmd, A_ScriptDir)
elapsedMs := A_TickCount - startTick

Log("exit code: " . exitCode)
Log("elapsed:   " . Format("{:.2f}", elapsedMs / 1000) . "s")

if CFG_EstimateEnable
    LogETA(elapsedMs / 1000, exitCode)

ExitApp(exitCode)


; ==============================================================================
; FUNCTION: PatchVpy
; Reads the vpy at path, applies all configured patches, writes back in-place.
; Patches are independent — each is attempted regardless of whether others matched.
; File is only written if at least one patch produced a change.
; NOT called when OverrideVspipeScript.Enable=True (path-swap bypass instead).
;
; Patches applied:
;   1. cMatrix 'rgb' guard            — always (skipped if guard already present)
;   2. model_path override            — if OverrideModel.Enable=True
;   3. multiplier=X -> factor_num/den — always; skipped if already absent
;   4. AverageFrames + SelectEvery injection after the YUV444P16 conversion line
;                                     — if AverageFrames.Enable=True
;   5. Upscaling injection            — if Upscaling.Enable=True
;                                       after_rife: after RIFE line (RGBS context)
;                                       after_average: before set_output() (YUV444P16 context)
;   6. Debug stage logging injection  — if DebugLogEnable=True
;   7. single-quote fix in inputPath  — always
; ==============================================================================
PatchVpy(path) {
    global CFG_OverrideModelEnable, CFG_OverrideModelDirName
    global CFG_AvgFramesEnable, CFG_AvgFramesWeights, CFG_AvgFramesScale
    global CFG_AvgScenechange, CFG_AvgSCThreshold
    global CFG_AvgPhaseSplit
    global CFG_SelectEveryCycle, CFG_SelectEveryOffsets
    global CFG_DebugLogEnable, DbgVpyLog
    global CFG_UpscaleEnable, CFG_UpscalePipelinePos, CFG_UpscaleOutputWidth, CFG_UpscaleOutputHeight
    global CFG_UpscaleMethod
    global G_OutputFrameCount, G_SourceFrameCount, G_RIFENum, G_RIFEDen, G_InputPath
    global CFG_EstimateEnable

    try {
        content := FileRead(path, "UTF-8")
    } catch as e {
        Log("ERROR reading vpy: " . e.Message)
        return
    }

    patched := content

    ; --- Patch 1: cMatrix 'rgb' guard ---
    ; FlowFrames maps frame prop _Matrix=0 to cMatrix='rgb'. That value is valid
    ; only as matrix_in_s for a YUV source (which never coexists with _Matrix=0),
    ; but the SAME variable is later reused as matrix_s for the post-RIFE
    ; RGB->YUV444P16 conversion, where 'rgb' is an invalid target matrix and the
    ; script dies. Remap to '709'. Inserted right before the first column-0
    ; "colRange = 'limited'" line, i.e. immediately after the vendor's cMatrix
    ; detection block, so both later uses see the corrected value.
    if !InStr(patched, "if cMatrix == 'rgb'") {
        if RegExMatch(patched, "m)^(colRange = 'limited')\r?$") {
            guard := "if cMatrix == 'rgb':`n    cMatrix = '709'  # 'rgb' is invalid as RGB->YUV target matrix (wrapper guard)`n`n"
            patched := RegExReplace(patched, "m)^(colRange = 'limited')\r?$", guard . "$1", , 1)
            Log("Injected: cMatrix 'rgb'->'709' guard before colRange detection")
        } else {
            Log("cMatrix guard anchor (colRange line) not found - guard not injected")
        }
    } else {
        Log("cMatrix guard already present - skipped")
    }

    ; --- Patch 1: model_path override ---
    ; Replaces the last path component (the model dir name) in the model_path= argument.
    ; model_path= uses forward slashes in FlowFrames-generated vpy.
    ; Regex captures everything up to and including the last slash, then the dir name,
    ; then the closing quote. Only the dir name token is replaced.
    if CFG_OverrideModelEnable && CFG_OverrideModelDirName != "" {
        if RegExMatch(patched, 'model_path="([^"]+/)[^"/]+"', &mPath) {
            newPath := 'model_path="' . mPath[1] . CFG_OverrideModelDirName . '"'
            patched := RegExReplace(patched, 'model_path="[^"]+"', newPath)
            Log("Patched: model_path -> ..." . mPath[1] . CFG_OverrideModelDirName)
        } else {
            Log("OverrideModel enabled but model_path= not found in vpy - no override applied")
        }
    } else if CFG_OverrideModelEnable && CFG_OverrideModelDirName = "" {
        Log("OverrideModel.Enable=True but ModelDirName is empty - override skipped")
    } else {
        Log("OverrideModel disabled - model_path left as-is in vpy")
    }

    ; --- Patch 2: multiplier=X -> factor_num=N, factor_den=D ---
    ; If multiplier= is not found, this is not an error — newer FlowFrames versions
    ; already emit factor_num/factor_den directly. File is correct for this patch; skip.
    if RegExMatch(patched, "multiplier=([\d.]+)", &mMatch) {
        mStr  := mMatch[1]
        frac  := MultiplierToFraction(mStr)
        numV  := frac[1]
        denV  := frac[2]
        G_RIFENum := numV
        G_RIFEDen := denV
        replacement := "factor_num=" . numV . ", factor_den=" . denV
        patched := RegExReplace(patched, "multiplier=[\d.]+", replacement)
        Log("Patched: multiplier=" . mStr . " -> factor_num=" . numV . ", factor_den=" . denV)
    } else {
        Log("No multiplier= found - factor_num/factor_den already present or newer FlowFrames version")
        ; Extract factor_num/factor_den for ETA tracking
        if RegExMatch(patched, "factor_num=(\d+)[^,\n]*,\s*factor_den=(\d+)", &mFactor) {
            G_RIFENum := Integer(mFactor[1])
            G_RIFEDen := Integer(mFactor[2])
        }
    }

    ; --- Patch 4: AverageFrames + SelectEvery injection ---
    ; Inserts the blend+downsample block immediately AFTER the vendor's
    ;   clip = vs.core.resize.Bicubic(clip, format=vs.YUV444P16, matrix_s=cMatrix)
    ; line — NOT after the RIFE line. Rationale:
    ;   * RIFE emits RGBS (32-bit float). The R57-era core's AverageFrames has a
    ;     broken float-input path (fixed upstream in r59) producing horizontal
    ;     stripe corruption. The integer YUV444P16 path is the battle-tested one.
    ;   * The vendor conversion line already applies matrix_s=cMatrix, so the
    ;     averaged frames inherit correct colorimetry tagging for the y4m pipe.
    ; Consequently Weights and Scale MUST be integers (integer formats reject
    ; float weights); validated below, injection skipped with ERROR otherwise.
    ; Optionally re-runs misc.SCDetect on the converted clip and passes
    ; scenechange=True so blend windows never cross a scene cut (SCDetect must
    ; re-run post-RIFE: RIFE changes the frame count, so pre-RIFE flags do not
    ; line up with post-RIFE frame indices).
    ; std.SelectEvery is used with modify_duration=False + explicit AssumeFPS
    ; to set the exact downsampled rate (rife_fps / Cycle).
    ; Also patches the Trim frame limit: FlowFrames calculates it for the raw
    ; RIFE output frame count. After SelectEvery(cycle=N), count reduces by N,
    ; so Trim(first, last) -> Trim(first, (last+1)//N - 1).
    if CFG_AvgFramesEnable {
        weightsOk := true
        for w in StrSplit(CFG_AvgFramesWeights, ",") {
            if InStr(Trim(w), ".") {
                weightsOk := false
                break
            }
        }
        if !weightsOk || InStr(Trim(CFG_AvgFramesScale), ".") {
            Log("ERROR: AverageFrames.Weights/Scale must be integers for the YUV444P16"
                . " integer averaging path (got Weights=" . CFG_AvgFramesWeights
                . " Scale=" . CFG_AvgFramesScale . ") - injection skipped")
        } else if InStr(patched, "core.std.AverageFrames") {
            Log("AverageFrames already present in vpy - injection skipped")
        } else if RegExMatch(patched, "m)^(clip\s*=\s*(?:vs\.)?core\.resize\.Bicubic\(clip,\s*format=vs\.YUV444P16[^\r\n]*\r?\n)") {
            weightsStr  := "[" . StrReplace(CFG_AvgFramesWeights, ",", ", ") . "]"
            cycleInt    := Integer(CFG_SelectEveryCycle)
            injected    := false
            insertLines := "_pre_avg_fps_num = clip.fps_num`n"
                         . "_pre_avg_fps_den = clip.fps_den`n"

            if CFG_AvgPhaseSplit {
                ; ---- PHASE-SPLIT (multi-clip) mode ----
                ; Split the stream into <Cycle> phase lanes and average them in
                ; multi-clip mode: every frame is used exactly once (nothing dropped
                ; or overlapped), EVEN Cycle counts are allowed (the odd-weights rule
                ; is single-clip only), and the phase split IS the decimation so no
                ; SelectEvery is used. Each weight maps to one phase -> the weight
                ; count MUST equal Cycle. NOTE: multi-clip has no scenechange feature,
                ; but on the R57 core scenechange is broken anyway (fixed upstream in
                ; r60), so nothing is lost vs centered mode here.
                weightsCount := StrSplit(CFG_AvgFramesWeights, ",").Length
                if weightsCount != cycleInt {
                    Log("ERROR: PhaseSplit needs one weight per phase: Weights count ("
                        . weightsCount . ") must equal SelectEvery.Cycle (" . cycleInt
                        . ") - injection skipped")
                } else {
                    insertLines .= "_phase = [core.std.SelectEvery(clip, cycle=" . cycleInt
                                 . ", offsets=[k]) for k in range(" . cycleInt . ")]`n"
                                 . "clip = core.std.AverageFrames(_phase, weights=" . weightsStr
                                 . ", scale=" . CFG_AvgFramesScale . ")`n"
                    if CFG_DebugLogEnable
                        insertLines .= "clip = _dbg(clip, 'phase-average')`n"
                    insertLines .= "clip = core.std.AssumeFPS(clip, fpsnum=_pre_avg_fps_num, fpsden=_pre_avg_fps_den * " . cycleInt . ")`n"
                    if CFG_DebugLogEnable
                        insertLines .= "clip = _dbg(clip, 'phase-downsample')`n"
                    patched := RegExReplace(patched,
                        "m)^(clip\s*=\s*(?:vs\.)?core\.resize\.Bicubic\(clip,\s*format=vs\.YUV444P16[^\r\n]*\r?\n)",
                        "$1" . insertLines, , 1)
                    Log("Injected after YUV444P16 conversion (PHASE-SPLIT): save fps -> "
                        . cycleInt . " phase lanes -> AverageFrames(multi-clip, weights="
                        . weightsStr . ", scale=" . CFG_AvgFramesScale . ")"
                        . " + AssumeFPS(rife_fps / " . cycleInt . ")")
                    injected := true
                }
            } else {
                ; ---- CENTERED (single-clip) mode ---- (original behaviour)
                offsetsStr := "[" . StrReplace(CFG_SelectEveryOffsets, ",", ", ") . "]"
                scStr      := CFG_AvgScenechange ? "True" : "False"
                if CFG_AvgScenechange
                    insertLines .= "clip = core.misc.SCDetect(clip, threshold=" . CFG_AvgSCThreshold . ")`n"
                insertLines .= "clip = core.std.AverageFrames(clip, weights=" . weightsStr
                             . ", scale=" . CFG_AvgFramesScale . ", scenechange=" . scStr . ")`n"
                if CFG_DebugLogEnable
                    insertLines .= "clip = _dbg(clip, 'average')`n"
                insertLines .= "clip = core.std.SelectEvery(clip, cycle=" . CFG_SelectEveryCycle
                             . ", offsets=" . offsetsStr . ", modify_duration=False)`n"
                             . "clip = core.std.AssumeFPS(clip, fpsnum=_pre_avg_fps_num, fpsden=_pre_avg_fps_den * " . CFG_SelectEveryCycle . ")`n"
                if CFG_DebugLogEnable
                    insertLines .= "clip = _dbg(clip, 'select-downsample')`n"
                patched := RegExReplace(patched,
                    "m)^(clip\s*=\s*(?:vs\.)?core\.resize\.Bicubic\(clip,\s*format=vs\.YUV444P16[^\r\n]*\r?\n)",
                    "$1" . insertLines, , 1)
                Log("Injected after YUV444P16 conversion: save fps -> "
                    . (CFG_AvgScenechange ? "SCDetect(threshold=" . CFG_AvgSCThreshold . ") -> " : "")
                    . "AverageFrames(weights=" . weightsStr . ", scale=" . CFG_AvgFramesScale
                    . ", scenechange=" . scStr . ") + SelectEvery(cycle=" . CFG_SelectEveryCycle
                    . ", offsets=" . offsetsStr . ", modify_duration=False)"
                    . " + AssumeFPS(rife_fps / " . CFG_SelectEveryCycle . ")")
                injected := true
            }

            ; Patch Trim frame limit to match reduced frame count (count drops by Cycle
            ; in BOTH modes: SelectEvery(cycle=N) and the N-lane phase split each /N)
            if injected {
                if RegExMatch(patched, "clip\.std\.Trim\((\d+),\s*(\d+)\)", &mTrim) {
                    origFirst := Integer(mTrim[1])
                    origLast  := Integer(mTrim[2])
                    newLast   := (origLast + 1) // cycleInt - 1
                    patched   := RegExReplace(patched, "clip\.std\.Trim\(\d+,\s*\d+\)",
                                     "clip.std.Trim(" . origFirst . ", " . newLast . ")")
                    Log("Patched: Trim(" . origFirst . ", " . origLast . ") -> Trim(" . origFirst . ", " . newLast . ") for " . cycleInt . "x downsample")
                } else {
                    Log("AverageFrames injected but Trim line not found - frame count not adjusted")
                }
            }
        } else {
            Log("ERROR: AverageFrames enabled but YUV444P16 conversion line not found in vpy"
                . " - injection skipped (will NOT fall back to post-RIFE float injection:"
                . " R57 core corrupts float averaging)")
        }
    } else {
        Log("AverageFrames disabled - no injection")
    }

    ; --- Patch 5: Upscaling injection ---
    ; Injects AI/filter upscaling into the vpy at the configured pipeline position.
    ;
    ; PipelinePosition options:
    ;   after_rife    - clip is RGBS at source resolution; inject after RIFE line.
    ;                   The existing YUV444P16 Bicubic conversion then runs at the
    ;                   new (upscaled) resolution — no extra format conversion needed.
    ;   after_average - clip is YUV444P16 at source resolution (post-AverageFrames);
    ;                   inject before set_output(). RealESRGAN needs an RGB roundtrip
    ;                   (Bicubic to RGBS → ESRGAN → Spline36 → Bicubic to YUV444P16).
    ;                   Spline36/Lanczos work directly in YUV — no roundtrip.
    ;   before_rife   - clip is YUV at source resolution; inject BEFORE the pre-RIFE
    ;                   Bicubic(format=vs.RGBS) line. Spline36 just resizes the YUV clip;
    ;                   the existing Bicubic then converts to RGBS at the new resolution.
    ;                   RealESRGAN converts YUV→RGBS→ESRGAN→downsample, leaving RGBS at
    ;                   target res; the existing Bicubic(RGBS) becomes a no-op identity.
    ;                   RIFE runs at upscaled resolution (~4× GPU cost for 720p→1080p).
    ;
    ; Tile size (TileWidth/TileHeight): critical for shared VRAM (Intel Iris Xe).
    ; RealESRGAN internally tiles the frame to fit available GPU memory. Set smaller
    ; values (128–256) if OOM errors occur. 0 = plugin auto-select (may OOM on Iris Xe).
    ;
    ; TODO: non-standard resolution handling (ScaleMode / PadBars / EncodeBars / PadColor)
    if CFG_UpscaleEnable {
        outW := 0
        outH := 0
        try {
            outW := Integer(CFG_UpscaleOutputWidth)
        } catch {
        }
        try {
            outH := Integer(CFG_UpscaleOutputHeight)
        } catch {
        }

        if outW <= 0 || outH <= 0 {
            Log("ERROR: Upscaling.Enable=True but OutputWidth/OutputHeight invalid ("
                . CFG_UpscaleOutputWidth . "x" . CFG_UpscaleOutputHeight . ") - injection skipped")

        } else if CFG_UpscaleMethod = "Waifu2x" {
            Log("WARNING: Upscaling.Method=Waifu2x not yet implemented - injection skipped."
                . " Use RealESRGAN or Spline36.")

        } else if InStr(patched, "core.realesrgan.ESRGAN") || InStr(patched, "core.resize.Spline36") && InStr(patched, CFG_UpscaleOutputWidth) {
            Log("Upscaling appears already present in vpy - injection skipped")

        } else {
            ; Resolve effective pipeline position
            effectivePos := CFG_UpscalePipelinePos
            if effectivePos != "before_rife" && effectivePos != "after_rife" && effectivePos != "after_average" {
                Log("WARNING: Upscaling.PipelinePosition='" . effectivePos . "' unknown - falling back to after_rife")
                effectivePos := "after_rife"
            }
            if effectivePos = "after_average" && !CFG_AvgFramesEnable {
                Log("WARNING: Upscaling.PipelinePosition=after_average but AverageFrames.Enable=False"
                    . " - falling back to after_rife")
                effectivePos := "after_rife"
            }

            upscaleLines := BuildUpscaleVpyLines(effectivePos)

            if effectivePos = "after_rife" {
                ; Anchor: RIFE output line. Clip is RGBS at source res.
                ; Existing YUV444P16 Bicubic conversion (next vendor line) runs at new res.
                if RegExMatch(patched, "m)^(clip\s*=\s*(?:vs\.)?core\.rife\.RIFE\([^\r\n]*\r?\n)") {
                    patched := RegExReplace(patched,
                        "m)^(clip\s*=\s*(?:vs\.)?core\.rife\.RIFE\([^\r\n]*\r?\n)",
                        "$1" . upscaleLines, , 1)
                    Log("Injected upscaling after_rife: " . CFG_UpscaleMethod
                        . " -> " . CFG_UpscaleOutputWidth . "x" . CFG_UpscaleOutputHeight)
                } else {
                    Log("ERROR: Upscaling after_rife anchor (RIFE line) not found - injection skipped")
                }

            } else if effectivePos = "before_rife" {
                ; Anchor: the pre-RIFE Bicubic(format=vs.RGBS) line. Clip is YUV at source res.
                ; Inject BEFORE it so upscaling runs in YUV (Spline36) or with YUV→RGBS roundtrip
                ; (RealESRGAN). After our injection the clip is at target resolution:
                ;   Spline36: YUV at target res → existing Bicubic(RGBS) does format conversion ✓
                ;   ESRGAN:   RGBS at target res → existing Bicubic(RGBS) is identity no-op ✓
                ; RIFE then runs at the upscaled resolution (higher quality, ~4× GPU cost for 720→1080).
                if RegExMatch(patched, "m)^(clip\s*=\s*(?:vs\.)?core\.resize\.Bicubic\(clip,\s*format=vs\.RGBS[^\r\n]*\r?\n)") {
                    patched := RegExReplace(patched,
                        "m)^(clip\s*=\s*(?:vs\.)?core\.resize\.Bicubic\(clip,\s*format=vs\.RGBS[^\r\n]*\r?\n)",
                        upscaleLines . "$1", , 1)
                    Log("Injected upscaling before_rife: " . CFG_UpscaleMethod
                        . " -> " . CFG_UpscaleOutputWidth . "x" . CFG_UpscaleOutputHeight
                        . " (RIFE will run at target resolution)")
                } else {
                    Log("ERROR: Upscaling before_rife anchor (pre-RIFE Bicubic RGBS line) not found - injection skipped")
                }

            } else {
                ; after_average: inject before set_output().
                ; Clip is YUV444P16 at source res (after AverageFrames block).
                ; RealESRGAN needs YUV->RGB->ESRGAN->downsample->YUV roundtrip;
                ; Spline36 resizes directly in YUV (no roundtrip).
                if RegExMatch(patched, "m)^(clip\.set_output\(\))") {
                    patched := RegExReplace(patched,
                        "m)^(clip\.set_output\(\))",
                        upscaleLines . "$1", , 1)
                    Log("Injected upscaling after_average: " . CFG_UpscaleMethod
                        . " -> " . CFG_UpscaleOutputWidth . "x" . CFG_UpscaleOutputHeight)
                } else {
                    Log("ERROR: Upscaling after_average anchor (set_output line) not found - injection skipped")
                }
            }
        }
    } else {
        Log("Upscaling disabled - no injection")
    }
    ; Injects a _dbg(clip, stage) helper right after "core = vs.core" and probe
    ; calls after each known pipeline stage. The helper logs node-level stream
    ; parameters (resolution, format name, color family, bit depth, sample type,
    ; chroma subsampling, frame count, fps) plus frame-0 properties (_Matrix,
    ; _Primaries, _Transfer, _ColorRange, SAR, field order, scene-change flags,
    ; duration) to rife_vpy_debug.log. Each probe renders frame 0 of that stage
    ; at script-evaluation time (the 'rife' probe costs one GPU interpolation) —
    ; acceptable for a debug mode. The log is rotated on each script evaluation
    ; and starts with a header echoing the wrapper's active configuration.
    ; Probes inside the AverageFrames block are emitted by Patch 4 directly.
    if CFG_DebugLogEnable {
        if InStr(patched, "def _dbg(") {
            Log("Debug logging already present in vpy - injection skipped")
        } else if RegExMatch(patched, "m)^(core = vs\.core\r?\n)") {
            cfgSummary := "AverageFrames.Enable=" . (CFG_AvgFramesEnable ? "True" : "False")
                . " Weights=" . CFG_AvgFramesWeights . " Scale=" . CFG_AvgFramesScale
                . " Scenechange=" . (CFG_AvgScenechange ? "True" : "False")
                . " SCDetectThreshold=" . CFG_AvgSCThreshold
                . " SelectEvery.Cycle=" . CFG_SelectEveryCycle
                . " SelectEvery.Offsets=" . CFG_SelectEveryOffsets
                . " OverrideModel=" . (CFG_OverrideModelEnable ? CFG_OverrideModelDirName : "(disabled)")
            helper := ""
            helper .= '_DBG_LOG = r"' . DbgVpyLog . '"' . "`n"
            helper .= 'with open(_DBG_LOG, "w", encoding="utf-8") as _lf:' . "`n"
            helper .= '    _lf.write("==== rife.vpy debug ====\n")' . "`n"
            helper .= '    _lf.write("wrapper config: ' . cfgSummary . '\n")' . "`n"
            helper .= "def _dbg(c, stage):`n"
            helper .= "    try:`n"
            helper .= "        fmt = c.format`n"
            helper .= '        line = "[{}] {}x{} {} family={} bits={} sample={} ssW={} ssH={} frames={} fps={}/{}".format(' . "`n"
            helper .= "            stage, c.width, c.height, fmt.name, str(fmt.color_family), fmt.bits_per_sample,`n"
            helper .= "            str(fmt.sample_type), fmt.subsampling_w, fmt.subsampling_h, c.num_frames, c.fps_num, c.fps_den)`n"
            helper .= "        try:`n"
            helper .= "            props = c.get_frame(0).props`n"
            helper .= '            keys = ["_Matrix", "_Primaries", "_Transfer", "_ColorRange", "_SARNum", "_SARDen",' . "`n"
            helper .= '                    "_FieldBased", "_SceneChangePrev", "_SceneChangeNext", "_DurationNum", "_DurationDen"]' . "`n"
            helper .= '            line += " | " + ", ".join("{}={}".format(k, props[k]) for k in keys if k in props)' . "`n"
            helper .= "        except Exception as pe:`n"
            helper .= '            line += " | props-error: {}".format(pe)' . "`n"
            helper .= '        with open(_DBG_LOG, "a", encoding="utf-8") as lf:' . "`n"
            helper .= '            lf.write(line + "\n")' . "`n"
            helper .= "    except Exception as e:`n"
            helper .= "        try:`n"
            helper .= '            with open(_DBG_LOG, "a", encoding="utf-8") as lf:' . "`n"
            helper .= '                lf.write("[{}] dbg-error: {}\n".format(stage, e))' . "`n"
            helper .= "        except Exception:`n"
            helper .= "            pass`n"
            helper .= "    return c`n"
            patched := RegExReplace(patched, "m)^(core = vs\.core\r?\n)", "$1" . helper, , 1)
            Log("Injected: _dbg helper + log rotation after 'core = vs.core'")

            ; Stage probes — each anchored independently; missing anchors are logged, not fatal
            probes := [
                ["m)^(clip = core\.lsmas\.LWLibavSource\([^\r\n]*\r?\n)", "$1clip = _dbg(clip, 'source')`n",            "source (after LWLibavSource)"],
                ["m)^(clip = core\.misc\.SCDetect\()",                    "clip = _dbg(clip, 'rgbs-pre-rife')`n$1",     "rgbs-pre-rife (before vendor SCDetect)"],
                ["m)^(clip = core\.rife\.RIFE\([^\r\n]*\r?\n)",           "$1clip = _dbg(clip, 'rife')`n",              "rife (after RIFE)"],
                ["m)^(clip = (?:vs\.)?core\.resize\.Bicubic\(clip,\s*format=vs\.YUV444P16[^\r\n]*\r?\n)", "$1clip = _dbg(clip, 'yuv-convert')`n", "yuv-convert (after YUV444P16 conversion)"],
                ["m)^(clip\.set_output\(\))",                             "clip = _dbg(clip, 'final')`n$1",             "final (before set_output)"]
            ]
            for p in probes {
                if RegExMatch(patched, p[1]) {
                    patched := RegExReplace(patched, p[1], p[2], , 1)
                    Log("Injected debug probe: " . p[3])
                } else {
                    Log("Debug probe anchor not found: " . p[3] . " - probe skipped")
                }
            }
        } else {
            Log("ERROR: DebugLogEnable=True but 'core = vs.core' anchor not found - debug injection skipped")
        }
    } else {
        Log("DebugLogEnable disabled - no debug injection")
    }

    ; Fix single quote in inputPath string literal.
    ; Flowframes writes:  inputPath = r'C:\path\It's a file.mp4'
    ; A single quote inside the filename terminates the Python raw string early -> SyntaxError.
    ; Fix: re-quote with double quotes. Double quotes are illegal in Windows filenames
    ; so switching delimiter from ' to " is always safe.
    ; Only applied when the inputPath line actually contains a single quote in the path itself.
    ; Detection uses a repeated capture group (.+?'.+?)+ which matches any number
    ; of embedded single quotes in the path, making it robust for filenames like
    ; "It's a test.mp4", "John's friend's video.mp4", etc.
    if RegExMatch(patched, "inputPath = r'(.+?'[^`n]+?)+'") {
        patched := RegExReplace(patched, "inputPath = r'(.+)'", "inputPath = r`"$1`"")
        Log("Fixed single quote(s) in inputPath")
    }

    ; --- Capture frame counts and source path for ETA estimation ---
    ; Read from final patched content so it's correct regardless of which patches ran.
    ; With AverageFrames: Trim is already adjusted for cycle; without it: Trim = RIFE output.
    if CFG_EstimateEnable {
        ; Extract source video path - used to locate the .lwi cache for auto FPS detection
        if RegExMatch(patched, 'inputPath\s*=\s*r?["\x27]([^"\x27\r\n]+)["\x27]', &mPath)
            G_InputPath := mPath[1]

        if RegExMatch(patched, "clip\.std\.Trim\((\d+),\s*(\d+)\)", &mFinalTrim) {
            finalFirst := Integer(mFinalTrim[1])
            finalLast  := Integer(mFinalTrim[2])
            G_OutputFrameCount := finalLast - finalFirst + 1
            if G_RIFENum > 0 && G_RIFEDen > 0 {
                cycle := 1
                if CFG_AvgFramesEnable {
                    try {
                        cycle := Integer(CFG_SelectEveryCycle)
                    } catch {
                        cycle := 1
                    }
                }
                ; output = source × RIFE_num / (RIFE_den × cycle)  →  source = output × cycle × RIFE_den / RIFE_num
                G_SourceFrameCount := G_OutputFrameCount * cycle * G_RIFEDen // G_RIFENum
            }
            Log("ETA capture: outputFrames=" . G_OutputFrameCount . " sourceFrames≈" . G_SourceFrameCount
                . " RIFE=" . G_RIFENum . "/" . G_RIFEDen)
        } else {
            Log("EstimateProcessingTime: Trim line not found in vpy — frame counts not captured")
        }
    }

    ; --- Write back only if something changed ---
    if patched = content {
        Log("WARNING: no patches produced any change - vpy left unchanged")
        return
    }

    try {
        f := FileOpen(path, "w", "UTF-8-RAW")
        f.Write(patched)
        f.Close()
    } catch as e {
        Log("ERROR writing patched vpy: " . e.Message)
        return
    }

    Log("vpy written back successfully")
}


; ==============================================================================
; FUNCTION: ReadSourceFPSFromLwi
; Reads source video FPS from the LWLibavSource .lwi index file.
; LWLibavSource creates <inputPath>.lwi before decoding any frames, so it is
; always present by the time vspipe has finished and LogETA is called.
; Returns FPS as a float, or 0 if the file is absent / fields not found.
; Falls back gracefully — caller uses CFG_EstimateSourceFPS if this returns 0.
; ==============================================================================
ReadSourceFPSFromLwi(inputPath) {
    if inputPath = ""
        return 0
    lwiPath := inputPath . ".lwi"
    if !FileExist(lwiPath)
        return 0
    raw := ""
    try {
        raw := FileRead(lwiPath, "UTF-8")
    } catch {
        return 0
    }
    num := 0
    den := 1
    if RegExMatch(raw, "FrameRateNum=(\d+)", &m) {
        try {
            num := Integer(m[1])
        } catch {
            num := 0
        }
    }
    if RegExMatch(raw, "FrameRateDen=(\d+)", &m) {
        try {
            den := Integer(m[1])
        } catch {
            den := 0
        }
    }
    if num <= 0 || den <= 0
        return 0
    return num / den
}


; ==============================================================================
; FUNCTION: ParseDuration
; Parses a duration string into total seconds (float).
; Accepted formats: HH:MM:SS[.mmm]  MM:SS[.mmm]  bare seconds
; ==============================================================================
ParseDuration(str) {
    str := Trim(str)
    if RegExMatch(str, "^(\d+):(\d+):(\d+(?:\.\d+)?)$", &m)
        return Integer(m[1]) * 3600 + Integer(m[2]) * 60 + Float(m[3])
    if RegExMatch(str, "^(\d+):(\d+(?:\.\d+)?)$", &m)
        return Integer(m[1]) * 60 + Float(m[2])
    result := 0.0
    try {
        result := Float(str)
    } catch {
        result := 0.0
    }
    return result
}


; ==============================================================================
; FUNCTION: FormatElapsed
; Formats a duration in seconds as a human-readable string.
; ==============================================================================
FormatElapsed(seconds) {
    total := Floor(seconds)
    hr    := total // 3600
    mn    := Mod(total, 3600) // 60
    sc    := Mod(total, 60)
    if hr > 0
        return Format("{:d}h {:02d}m {:02d}s", hr, mn, sc)
    else if mn > 0
        return Format("{:d}m {:02d}s", mn, sc)
    else
        return Format("{:.1f}s", seconds)
}


; ==============================================================================
; FUNCTION: LogETA
; Called after vspipe exits. Uses measured elapsed time and captured frame
; counts to estimate processing time for configured clip durations.
;
; Requires:
;   G_OutputFrameCount  - set by PatchVpy from the final Trim
;   G_RIFENum/G_RIFEDen - set by PatchVpy from factor_num/den
;   CFG_EstimateSourceFPS - source video FPS (e.g. "25")
;   CFG_EstimateForClipSecs - comma-separated source durations to estimate
;   CFG_EstimateFullDuration - optional full movie duration for final estimate
; ==============================================================================
LogETA(elapsedSec, exitCode) {
    global G_OutputFrameCount, G_SourceFrameCount, G_RIFENum, G_RIFEDen, G_InputPath
    global CFG_EstimateSourceFPS, CFG_EstimateForClipSecs, CFG_EstimateFullDuration
    global CFG_SelectEveryCycle, CFG_AvgFramesEnable

    if exitCode != 0 {
        Log("EstimateProcessingTime: skipped (vspipe exit code " . exitCode . ")")
        return
    }
    if G_OutputFrameCount <= 0 {
        Log("EstimateProcessingTime: skipped (G_OutputFrameCount=0; Trim not found or PatchVpy not called)")
        return
    }

    measuredFPS := G_OutputFrameCount / Max(elapsedSec, 0.001)

    Log("========== EstimateProcessingTime ==========")
    Log("  Elapsed:          " . FormatElapsed(elapsedSec))
    Log("  Output frames:    " . G_OutputFrameCount)
    Log(Format("  Throughput:       {:.2f} output fps", measuredFPS))

    ; Source FPS: auto-detect from .lwi cache, fall back to config override
    sourceFPS := 0.0
    fpsSource := ""
    sourceFPS := ReadSourceFPSFromLwi(G_InputPath)
    if sourceFPS > 0 {
        fpsSource := "from .lwi (" . G_InputPath . ".lwi)"
    } else if CFG_EstimateSourceFPS != "" {
        try {
            sourceFPS := Float(CFG_EstimateSourceFPS)
        } catch {
            sourceFPS := 0.0
        }
        if sourceFPS > 0
            fpsSource := "from config override"
    }
    if sourceFPS <= 0 {
        Log("  Source FPS:       not detected (.lwi absent; set EstimateProcessingTime.SourceFPS as fallback)")
        Log("============================================")
        return
    }

    ; Pipeline output fps
    cycle := 1
    if CFG_AvgFramesEnable {
        try {
            cycle := Integer(CFG_SelectEveryCycle)
        } catch {
            cycle := 1
        }
    }
    outputFPS := sourceFPS * G_RIFENum / (G_RIFEDen * cycle)

    Log(Format("  Source FPS:       {:.4g}  ({})", sourceFPS, fpsSource))
    Log(Format("  RIFE factor:      {}/{}", G_RIFENum, G_RIFEDen))
    Log(Format("  SelectEvery:      /{}", cycle))
    Log(Format("  Pipeline out fps: {:.2f}  ({:.4g} × {}/{} / {})", outputFPS, sourceFPS, G_RIFENum, G_RIFEDen, cycle))
    Log(Format("  Source frames≈:   {} ({:.2f}s @ {:.4g}fps)", G_SourceFrameCount, G_SourceFrameCount / sourceFPS, sourceFPS))

    ; Per-clip estimates
    if CFG_EstimateForClipSecs != "" {
        Log("  ----  Per source-clip duration  ----")
        for rawSec in StrSplit(CFG_EstimateForClipSecs, ",") {
            targetSec := 0.0
            try {
                targetSec := Float(Trim(rawSec))
            } catch {
                continue
            }
            if targetSec <= 0
                continue
            frames := targetSec * outputFPS
            eta    := frames / measuredFPS
            Log(Format("    {:.0f}s source  →  {:.0f} out-frames  →  {}", targetSec, frames, FormatElapsed(eta)))
        }
    }

    ; FullDuration estimate
    if CFG_EstimateFullDuration != "" {
        fullSec := ParseDuration(CFG_EstimateFullDuration)
        if fullSec > 0 {
            frames := fullSec * outputFPS
            eta    := frames / measuredFPS
            Log("  ----  Full content: " . CFG_EstimateFullDuration . "  ----")
            Log(Format("    {:.0f}s source  →  {:.0f} out-frames  →  {}", fullSec, frames, FormatElapsed(eta)))
        }
    }
    Log("============================================")
}


; ==============================================================================
; FUNCTION: BuildUpscaleVpyLines
; Builds the Python vpy code to inject for upscaling at the given pipeline
; position ("after_rife" or "after_average").
;
; after_rife:    clip arrives as RGBS (RIFE output format).
;                RealESRGAN and Spline36 both accept RGBS directly. No format
;                conversion in the injected block — the existing vendor
;                Bicubic(format=vs.YUV444P16) line runs at the new resolution.
; after_average: clip arrives as YUV444P16 (post AverageFrames).
;                RealESRGAN needs RGBS: inject Bicubic roundtrip around ESRGAN.
;                Spline36 resizes directly in YUV — no roundtrip.
;
; Returns the Python code block as a string (AHK `n newlines).
; ==============================================================================
BuildUpscaleVpyLines(position) {
    global CFG_UpscaleMethod, CFG_ESRGAN_Model, CFG_ESRGAN_TileWidth, CFG_ESRGAN_TileHeight
    global CFG_ESRGAN_DownsampleFilt, CFG_ESRGAN_Tta
    global CFG_UpscaleOutputWidth, CFG_UpscaleOutputHeight
    global CFG_DebugLogEnable

    lines := ""
    w     := CFG_UpscaleOutputWidth
    h     := CFG_UpscaleOutputHeight

    if CFG_UpscaleMethod = "RealESRGAN" {
        ; RealESRGAN is an ncnn-vulkan plugin; needs RGBS input.
        ; after_average: source is YUV444P16 - roundtrip to RGBS and back.
        ; before_rife:   source is YUV - convert to RGBS for ESRGAN; leave as RGBS
        ;                so the existing vendor Bicubic(format=vs.RGBS) becomes a no-op.
        if position = "after_average" || position = "before_rife"
            lines .= "clip = core.resize.Bicubic(clip, format=vs.RGBS, matrix_in_s=cMatrix)`n"

        ; Model name -> plugin model index mapping.
        ; Models: realesrgan-x4plus (0) = general photography/video (best for camera content)
        ;         realesrnet-x4plus (1) = faster, slightly lower quality
        ;         realesrgan-x4plus-anime (2) = anime/illustration optimised
        ;         realesr-animevideov3 (3) = anime video, temporal consistency
        lines .= "_esrgan_models = {`"realesrgan-x4plus`": 0, `"realesrnet-x4plus`": 1, `"realesrgan-x4plus-anime`": 2, `"realesr-animevideov3`": 3}`n"
        lines .= "clip = core.realesrgan.ESRGAN(clip, scale=4"
               . ", model=_esrgan_models.get(`"" . CFG_ESRGAN_Model . "`", 0)"
               . ", tile_w=" . CFG_ESRGAN_TileWidth
               . ", tile_h=" . CFG_ESRGAN_TileHeight
               . ", tta=" . (CFG_ESRGAN_Tta ? "True" : "False") . ")`n"

        ; Downsample from intermediate 4x resolution to exact target.
        ; Spline36 default: fewer ringing artifacts than Lanczos, cleaner on AI-processed content.
        if CFG_ESRGAN_DownsampleFilt = "lanczos"
            lines .= "clip = core.resize.Lanczos(clip, width=" . w . ", height=" . h . ")`n"
        else
            lines .= "clip = core.resize.Spline36(clip, width=" . w . ", height=" . h . ")`n"

        ; after_average needs back to YUV444P16 for set_output().
        ; before_rife: leave as RGBS — existing vendor Bicubic(format=vs.RGBS) is then a no-op.
        ; after_rife:  leave as RGBS — existing vendor Bicubic(format=vs.YUV444P16) runs at new res.
        if position = "after_average"
            lines .= "clip = core.resize.Bicubic(clip, format=vs.YUV444P16, matrix_s=cMatrix)`n"

    } else if CFG_UpscaleMethod = "Spline36" {
        ; Spline36 operates directly in any VS format (YUV or RGB) — no roundtrip needed.
        ; before_rife/after_rife: clip is RGBS (or YUV) at source res; just resize.
        ; after_average: clip is YUV444P16; just resize.
        ; Less GPU-intensive than ESRGAN; good fallback when plugin is unavailable or VRAM is tight.
        lines .= "clip = core.resize.Spline36(clip, width=" . w . ", height=" . h . ")`n"

    }
    ; Waifu2x: TODO
    ; Would inject: core.w2xnvk.Waifu2x(clip, noise=CFG_W2X_NoiseLevel, scale=CFG_W2X_Scale,
    ;               model=..., tilesize=CFG_W2X_TileSize) + Spline36 downsample to exact target.
    ; waifu2x models are optimized for anime/illustration; less suitable for camera footage.

    ; Debug probe - _dbg is injected by Patch 6 (debug logging patch) which runs after this.
    ; The definition is near the top of the vpy (after "core = vs.core") so it will be in scope.
    if lines != "" && CFG_DebugLogEnable
        lines .= "clip = _dbg(clip, 'upscale')`n"

    return lines
}


; ==============================================================================
; FUNCTION: StripJsonComments
; Removes // line comments and /* */ block comments so the configs can be JSONC.
; STRING-AWARE: a // or /* inside a quoted string value is left untouched, and a
; commented-out line like  // "Enable": "False"  cannot be mis-matched by the
; key regexes. Backslash escapes inside strings are honored so "C:\\x" is safe.
; Comment bodies are removed; line structure (newlines) is preserved.
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
            if (c = Chr(92)) {        ; escaped char (backslash): copy next verbatim
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
        if (c = "/" && c2 = "/") {     ; line comment -> skip to newline
            while (i <= len && SubStr(text, i, 1) != "`n")
                i += 1
            continue
        }
        if (c = "/" && c2 = "*") {     ; block comment -> skip to */
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
; FUNCTION: ResolvePath
; Resolves an OverrideVspipeScript.Path value to an absolute filesystem path.
; Accepts:
;   absolute:  C:\full\path\script.vpy          -> used as-is
;   %env%:     %LocalAppData%\...\script.vpy    -> ExpandEnvironmentStringsW
;   relative:  subdir\script.vpy                -> A_ScriptDir + "\" + raw
; ==============================================================================
ResolvePath(raw) {
    ; Expand %ENVVAR% tokens (ExpandEnvironmentStringsW writes UTF-16 into a Buffer)
    expanded := Buffer(2048, 0)
    DllCall("Kernel32\ExpandEnvironmentStringsW", "Str", raw, "Ptr", expanded, "UInt", 1024, "UInt")
    result := StrGet(expanded, "UTF-16")
    ; If not absolute (no drive letter, no UNC \\), treat as relative to wrapper dir
    if !RegExMatch(result, "^[A-Za-z]:\\|^\\\\")
        result := A_ScriptDir . "\" . result
    return result
}


; ==============================================================================
; FUNCTION: LoadConfig
; Reads vspipe_wrapper_config.json from the same folder as the exe.
; Missing file or missing keys silently fall back to built-in defaults.
; Only "True" (case-insensitive) is treated as true; everything else is false.
; ==============================================================================
LoadConfig() {
    global CFG_LogEnable, CFG_DebugLogEnable
    global CFG_OverrideModelEnable, CFG_OverrideModelDirName
    global CFG_AvgFramesEnable, CFG_AvgFramesWeights, CFG_AvgFramesScale
    global CFG_AvgScenechange, CFG_AvgSCThreshold
    global CFG_AvgPhaseSplit
    global CFG_SelectEveryCycle, CFG_SelectEveryOffsets
    global CFG_OverrideScriptEnable, CFG_OverrideScriptPath
    global CFG_UpscaleEnable, CFG_UpscalePipelinePos, CFG_UpscaleOutputWidth, CFG_UpscaleOutputHeight
    global CFG_UpscaleMethod, CFG_UpscaleScaleMode, CFG_UpscalePadBars, CFG_UpscaleEncodeBars, CFG_UpscalePadColor
    global CFG_ESRGAN_Model, CFG_ESRGAN_TileWidth, CFG_ESRGAN_TileHeight, CFG_ESRGAN_DownsampleFilt, CFG_ESRGAN_Tta
    global CFG_W2X_NoiseLevel, CFG_W2X_Scale, CFG_W2X_Model, CFG_W2X_TileSize
    global CFG_EstimateEnable, CFG_EstimateSourceFPS, CFG_EstimateForClipSecs, CFG_EstimateFullDuration

    cfgPath := A_ScriptDir . "\vspipe_wrapper_config.json"
    if !FileExist(cfgPath)
        return   ; no config file -> all defaults

    try {
        raw := FileRead(cfgPath, "UTF-8")
    } catch {
        return   ; unreadable -> all defaults
    }
    raw := StripJsonComments(raw)   ; JSONC: tolerate // and /* */ comments

    ; LogEnable (top-level)
    if RegExMatch(raw, '"LogEnable"\s*:\s*"([^"]*)"', &m)
        CFG_LogEnable := (m[1] = "True" || m[1] = "true")

    ; DebugLogEnable (top-level)
    if RegExMatch(raw, '"DebugLogEnable"\s*:\s*"([^"]*)"', &m)
        CFG_DebugLogEnable := (m[1] = "True" || m[1] = "true")

    ; OverrideModel block
    if RegExMatch(raw, '"OverrideModel"\s*:\s*\{[^}]*?"Enable"\s*:\s*"([^"]*)"', &m)
        CFG_OverrideModelEnable := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"OverrideModel"\s*:\s*\{[^}]*?"ModelDirName"\s*:\s*"([^"]*)"', &m)
        CFG_OverrideModelDirName := m[1]

    ; AverageFrames block — uses [\s\S]{0,500}? (lazy) to cross nested SelectEvery braces
    ; and match the FIRST "Enable" after the opening { rather than the last within range.
    if RegExMatch(raw, '"AverageFrames"\s*:\s*\{[\s\S]{0,500}?"Enable"\s*:\s*"([^"]*)"', &m)
        CFG_AvgFramesEnable := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"AverageFrames"\s*:\s*\{[\s\S]{0,500}?"Weights"\s*:\s*"([^"]*)"', &m)
        CFG_AvgFramesWeights := m[1]
    if RegExMatch(raw, '"AverageFrames"\s*:\s*\{[\s\S]{0,500}?"Scale"\s*:\s*"([^"]*)"', &m)
        CFG_AvgFramesScale := m[1]
    if RegExMatch(raw, '"AverageFrames"\s*:\s*\{[\s\S]{0,500}?"Scenechange"\s*:\s*"([^"]*)"', &m)
        CFG_AvgScenechange := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"AverageFrames"\s*:\s*\{[\s\S]{0,500}?"SCDetectThreshold"\s*:\s*"([^"]*)"', &m)
        CFG_AvgSCThreshold := m[1]
    ; PhaseSplit: lazy-window match within the AverageFrames block (crosses nested SelectEvery)
    if RegExMatch(raw, '"AverageFrames"\s*:\s*\{[\s\S]{0,500}?"PhaseSplit"\s*:\s*"([^"]*)"', &m)
        CFG_AvgPhaseSplit := (m[1] = "True" || m[1] = "true")

    ; AverageFrames.SelectEvery — search within SelectEvery block context
    if RegExMatch(raw, '"SelectEvery"\s*:\s*\{[^}]*"Cycle"\s*:\s*"([^"]*)"', &m)
        CFG_SelectEveryCycle := m[1]
    if RegExMatch(raw, '"SelectEvery"\s*:\s*\{[^}]*"Offsets"\s*:\s*"([^"]*)"', &m)
        CFG_SelectEveryOffsets := m[1]

    ; OverrideVspipeScript block (was ReplaceVspipeScript in older configs)
    if RegExMatch(raw, '"OverrideVspipeScript"\s*:\s*\{[^}]*"Enable"\s*:\s*"([^"]*)"', &m)
        CFG_OverrideScriptEnable := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"OverrideVspipeScript"\s*:\s*\{[^}]*"Path"\s*:\s*"([^"]*)"', &m)
        CFG_OverrideScriptPath := m[1]

    ; Upscaling block — lazy window across all nested sub-objects (RealESRGAN_Settings, Waifu2x_Settings)
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"Enable"\s*:\s*"([^"]*)"', &m)
        CFG_UpscaleEnable := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"PipelinePosition"\s*:\s*"([^"]*)"', &m)
        CFG_UpscalePipelinePos := m[1]
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"OutputWidth"\s*:\s*"([^"]*)"', &m)
        CFG_UpscaleOutputWidth := m[1]
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"OutputHeight"\s*:\s*"([^"]*)"', &m)
        CFG_UpscaleOutputHeight := m[1]
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"Method"\s*:\s*"([^"]*)"', &m)
        CFG_UpscaleMethod := m[1]
    ; TODO: ScaleMode / PadBars / EncodeBars / PadColor
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"ScaleMode"\s*:\s*"([^"]*)"', &m)
        CFG_UpscaleScaleMode := m[1]
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"PadBars"\s*:\s*"([^"]*)"', &m)
        CFG_UpscalePadBars := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"EncodeBars"\s*:\s*"([^"]*)"', &m)
        CFG_UpscaleEncodeBars := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"Upscaling"\s*:\s*\{[\s\S]{0,3000}?"PadColor"\s*:\s*"([^"]*)"', &m)
        CFG_UpscalePadColor := m[1]

    ; RealESRGAN_Settings sub-block
    if RegExMatch(raw, '"RealESRGAN_Settings"\s*:\s*\{[^}]*"Model"\s*:\s*"([^"]*)"', &m)
        CFG_ESRGAN_Model := m[1]
    if RegExMatch(raw, '"RealESRGAN_Settings"\s*:\s*\{[^}]*"TileWidth"\s*:\s*"([^"]*)"', &m)
        CFG_ESRGAN_TileWidth := m[1]
    if RegExMatch(raw, '"RealESRGAN_Settings"\s*:\s*\{[^}]*"TileHeight"\s*:\s*"([^"]*)"', &m)
        CFG_ESRGAN_TileHeight := m[1]
    if RegExMatch(raw, '"RealESRGAN_Settings"\s*:\s*\{[^}]*"DownsampleFilter"\s*:\s*"([^"]*)"', &m)
        CFG_ESRGAN_DownsampleFilt := m[1]
    if RegExMatch(raw, '"RealESRGAN_Settings"\s*:\s*\{[^}]*"Tta"\s*:\s*"([^"]*)"', &m)
        CFG_ESRGAN_Tta := (m[1] = "True" || m[1] = "true")

    ; Waifu2x_Settings sub-block (parsed but injection not yet implemented)
    if RegExMatch(raw, '"Waifu2x_Settings"\s*:\s*\{[^}]*"NoiseLevel"\s*:\s*"([^"]*)"', &m)
        CFG_W2X_NoiseLevel := m[1]
    if RegExMatch(raw, '"Waifu2x_Settings"\s*:\s*\{[^}]*"Scale"\s*:\s*"([^"]*)"', &m)
        CFG_W2X_Scale := m[1]
    if RegExMatch(raw, '"Waifu2x_Settings"\s*:\s*\{[^}]*"Model"\s*:\s*"([^"]*)"', &m)
        CFG_W2X_Model := m[1]
    if RegExMatch(raw, '"Waifu2x_Settings"\s*:\s*\{[^}]*"TileSize"\s*:\s*"([^"]*)"', &m)
        CFG_W2X_TileSize := m[1]

    ; EstimateProcessingTime block
    if RegExMatch(raw, '"EstimateProcessingTime"\s*:\s*\{[\s\S]{0,500}?"Enable"\s*:\s*"([^"]*)"', &m)
        CFG_EstimateEnable := (m[1] = "True" || m[1] = "true")
    if RegExMatch(raw, '"EstimateProcessingTime"\s*:\s*\{[\s\S]{0,500}?"SourceFPS"\s*:\s*"([^"]*)"', &m)
        CFG_EstimateSourceFPS := m[1]
    if RegExMatch(raw, '"EstimateProcessingTime"\s*:\s*\{[\s\S]{0,500}?"ForClipSeconds"\s*:\s*"([^"]*)"', &m)
        CFG_EstimateForClipSecs := m[1]
    if RegExMatch(raw, '"EstimateProcessingTime"\s*:\s*\{[\s\S]{0,500}?"FullDuration"\s*:\s*"([^"]*)"', &m)
        CFG_EstimateFullDuration := m[1]
}


; ==============================================================================
; FUNCTION: MultiplierToFraction
; Converts a decimal string like "2.4" to a lowest-terms integer pair [12, 5].
; Uses string arithmetic to avoid floating-point imprecision.
; Returns an array [numerator, denominator].
; ==============================================================================
MultiplierToFraction(mStr) {
    if !InStr(mStr, ".") {
        ; Integer  e.g. "2"
        return [Integer(mStr), 1]
    }

    ; Float  e.g. "2.4"  ->  split on "."  ->  intPart="2"  decPart="4"
    parts   := StrSplit(mStr, ".")
    intPart := Integer(parts[1])
    decPart := parts[2]
    decLen  := StrLen(decPart)
    den     := 10 ** decLen            ; e.g. 10 for one decimal place
    num     := intPart * den + Integer(decPart)   ; e.g. 2*10+4 = 24

    ; Reduce to lowest terms
    g := GCD(num, den)
    return [num // g, den // g]
}


; ==============================================================================
; FUNCTION: GCD
; Euclidean greatest common divisor.
; ==============================================================================
GCD(a, b) {
    while b {
        temp := b
        b    := Mod(a, b)
        a    := temp
    }
    return a
}


; ==============================================================================
; FUNCTION: BuildCmdLine
; Reconstructs a quoted command-line string from the A_Args array.
; Args containing spaces are double-quoted.
; ==============================================================================
BuildCmdLine(args) {
    result := ""
    for arg in args {
        if InStr(arg, " ") || InStr(arg, '"')
            result .= ' "' . StrReplace(arg, '"', '\"') . '"'
        else
            result .= " " . arg
    }
    return LTrim(result)
}


; ==============================================================================
; FUNCTION: ConcatArgs
; Returns all args joined with spaces, each double-quoted, for logging.
; ==============================================================================
ConcatArgs(args) {
    result := ""
    for arg in args
        result .= '"' . arg . '" '
    return Trim(result)
}


; ==============================================================================
; FUNCTION: Log
; Appends a timestamped line to the log file.
; Silently skipped when CFG_LogEnable=False.
; ==============================================================================
Log(msg) {
    global LogFile, CFG_LogEnable
    if !CFG_LogEnable
        return
    FileAppend(A_Now . "  " . msg . "`n", LogFile)
}
