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
;
; WHAT IT DOES:
;   - Finds the .vpy path in the command-line args
;   - Reads the vpy, locates  multiplier=X  (integer or float)
;   - Converts X to a lowest-terms fraction: factor_num=N, factor_den=D
;   - Overwrites the vpy with the patched version
;   - Launches VSPipe_real.exe with all original arguments
;   - Exits with VSPipe_real.exe's exit code
;
; MULTIPLIER CONVERSION EXAMPLES:
;   multiplier=2   -> factor_num=2,  factor_den=1
;   multiplier=2.4 -> factor_num=12, factor_den=5   (12/5 = 2.4)
;   multiplier=2.5 -> factor_num=5,  factor_den=2
;   multiplier=1.5 -> factor_num=3,  factor_den=2
;
; LOG FILE:
;   vspipe_wrapper.log in the same folder as the wrapper exe.
;   Rotated (deleted) at the start of each new session (once per process).
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off

global LogFile := A_ScriptDir . "\vspipe_wrapper.log"

; Rotate log on each fresh invocation
if FileExist(LogFile)
    FileDelete(LogFile)

Log("==== vspipe wrapper start ====")
Log("our PID:  " . DllCall("Kernel32\GetCurrentProcessId", "UInt"))
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

; --- Patch the vpy file ---
if vpyPath && FileExist(vpyPath) {
    PatchVpy(vpyPath)
} else {
    Log("WARNING: .vpy not found or does not exist - passing through unmodified")
}

; --- Launch VSPipe_real.exe with original args ---
realExe   := A_ScriptDir . "\VSPipe_real.exe"
cmdLine   := BuildCmdLine(A_Args)
fullCmd   := '"' . realExe . '" ' . cmdLine

Log("launching: " . fullCmd)

exitCode  := RunWait(fullCmd, A_ScriptDir)

Log("exit code: " . exitCode)

ExitApp(exitCode)


; ==============================================================================
; FUNCTION: PatchVpy
; Reads the vpy at path, replaces  multiplier=X  with  factor_num=N, factor_den=D
; then writes the file back in-place.
; ==============================================================================
PatchVpy(path) {
    try {
        content := FileRead(path, "UTF-8")
    } catch as e {
        Log("ERROR reading vpy: " . e.Message)
        return
    }

    ; Find multiplier=X (integer or float, e.g. 2 or 2.4)
    if !RegExMatch(content, "multiplier=([\d.]+)", &mMatch) {
        Log("No multiplier= found in vpy - file left unchanged")
        return
    }

    mStr  := mMatch[1]
    frac  := MultiplierToFraction(mStr)
    numV  := frac[1]
    denV  := frac[2]

    ; Replace  multiplier=X  with  factor_num=N, factor_den=D
    ; The comma that was after  multiplier=X  remains in the source text,
    ; so we only replace the key=value portion, not the trailing comma.
    replacement := "factor_num=" . numV . ", factor_den=" . denV
    patched     := RegExReplace(content, "multiplier=[\d.]+", replacement)

    if patched = content {
        Log("WARNING: RegExReplace produced no change - vpy left unchanged")
        return
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

    ; Write patched content back
    try {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(patched)
        f.Close()
    } catch as e {
        Log("ERROR writing patched vpy: " . e.Message)
        return
    }

    Log("Patched: multiplier=" . mStr
        . " -> factor_num=" . numV . ", factor_den=" . denV)
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
; ==============================================================================
Log(msg) {
    global LogFile
    FileAppend(A_Now . "  " . msg . "`n", LogFile)
}
