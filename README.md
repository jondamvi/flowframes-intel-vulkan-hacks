# flowframes-intel-vulkan-hacks
Workarounds for Flowframes + Intel GPU (Vulkan) + HEVC QSV hardware encoding + RIFE-NCNN-VS v4.25 model.


Here will be shown possible workarounds for running Flowframes with Intel GPU (Vulkan) and HEVC QSV hardware encoding, plus support for RIFE v4.25 model.

Tested on Flowframes 1.40.0 (Patreon release). Whether this works on the free public release 1.36.0 is unknown.

Hardware tested: Intel Iris Xe Graphics (Intel Tiger Lake Core i5).

---

## Who is this Repo for?

If you have only integrated Intel Graphics (with Vulkan supported) and want to run faster Flowframes video interpolation (GPU-accelerated), then workarounds described here may help to achieve this.

## What this is

Two Flowframes calls intercepting executables - 'ffmpeg.exe' and 'VSPipe.exe' that can be compiled from AHK v2 scripts.

**ffmpeg_wrapper** - Intercepts ffmpeg encoding calls and replaces libx265 (CPU-bound) with `hevc_qsv` (Intel Quick Sync hardware encoder). Result: Interpolation to 50FPS and encoding 1080p video that was estimated as 23+ hours completed in 3.5 hours, shifting workload to GPU, and with CPU usage dropping from 95% to ~10%.

**vspipe_wrapper** - Intercepts VSPipe calls and patches the generated rife.vpy script on the fly. Required because Flowframes 1.40 generates `multiplier=` parameter in the vpy, but newer RIFE DLLs (from Flowframes 1.42 packages) use `factor_num`/`factor_den` instead. Without this patch, interpolation fails immediately.

---

## Requirements

- Flowframes 1.40.0 (Patreon)
- AutoHotkey v2 (for compiling AHK scripts to .exe)
- Intel GPU with Quick Sync Video support (HEVC encoding)
- Autohotkey may need adding Windows Defender exception

---

## Warning

**Make a backup of your Flowframes application directory before making any changes!**

`%LocalAppData%\Flowframes`

These wrappers allow arbitrary ffmpeg parameters to be passed to your GPU encoder. Use at your own risk. No support provided. Different hardware/video type/encoding options - may need manual investigation and ffmpeg/vspipe/interceptor script tuning.

---

## Part 1 - HEVC QSV encoding wrapper

### What it does

By default Flowframes calls ffmpeg with `-c:v libx265` for encoding. 
But not all GPU's can work with libx265 codec.
For example Intel Graphics Xe cannot.
If in Flowfraes encoding MP4 HEVC is selected, then this wrapper intercepts Flowframes call to ffmpeg.exe and changes encoding parameters from libx265 to hevc_qsv, which is supported with Intel Graphics Xe. It also injects `format=nv12` into the VapourSynth pipe filter chain, which is required because the VS pipe outputs yuv444p16le and hevc_qsv needs nv12.

### Files

- `ffmpeg_wrapper.ahk` - wrapper source
- `ffmpeg_wrapper_config.json` - encoder settings

### Setup

1. Go to `%LocalAppData%\Flowframes\FlowframesData\pkgs\av\`
2. Rename `ffmpeg.exe` to `ffmpeg_real.exe`
3. Compile `ffmpeg_wrapper.ahk` as **64-bit console app** using Ahk2Exe with AutoHotkey64.exe as base
4. Place compiled `ffmpeg.exe` in the same folder
5. Place `ffmpeg_wrapper_config.json` in the same folder

### Config

```json
{
  "OverrideH265EncodingEnable": "True",
  "OverrideH265EncodingSettings": {
    "OverrideEncodingArgs": "-c:v hevc_qsv -global_quality 17 -preset slow -async_depth 8 -g 50 -keyint_min 1 -forced_idr 1 -movflags +faststart",
    "LogEnable": "True",
    "DebugLogEnable": "False"
  }
}
```

This allows overriding Flowframes encoding parameters, because Flowframes can override additional encoding arguments specified in Developer Options with own pre-defined settings. For example, if you set additional encoding arguments in developer options to different video codec like `-c:v hevc_qsv` then Flowframes will append its own pre-defined arguments as `... -c:v libx265 ...` after these developer options and this makes ffmpeg to respect only the latest video codec argument in command line. 
With these ffmpeg settings configured in OverrideEncodingArgs achieved faster encoding speed and great quality results.
For your video type and goal parameters needed may be different.

*Refer to ffmpeg documentation for argument and value descriptions*: https://ffmpeg.org/ffmpeg.html

Log files are written to the `%LocalAppData%\Flowframes\FlowframesData\pkgs\av\ffmpeg_wrapper.log` folder when `LogEnable` is True.

---

## Part 2 - RIFE v4.25 model + VSPipe wrapper

### What it does

Flowframes 1.40 only includes RIFE v4.6. This section adds RIFE v4.25 support (released September 2024, the last stable RIFE release) and patches the VSPipe call to fix a parameter name incompatibility between the old and new RIFE DLL.

### Step 1 - Copy packages from Flowframes 1.42

Flowframes 1.42 (Patreon) ships with an updated rife-ncnn-vs package which can handle latest RIFE v4.25. Copy the entire directory:

In Flowframes 1.40 installation delete directory `%LocalAppData%\Flowframes\FlowframesData\pkgs\rife-ncnn-vs`.
Then copy `rife-ncnn-vs` directory Flowframes 1.42 in Flowframes 1.40 installation directory to same path.

This brings in the updated VSPipe.exe, python scripts, VapourSynth DLLs and RIFE DLL `librife_windows_x86-64.dll` that supports newer models.

Note that this public community repository from [styler00dollar/VapourSynth-RIFE-ncnn-Vulkan] https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan/releases/tag/r9_mod_v33 provides latest binary of `librife_windows_x86-64.dll` but that is not enough. You need entire RIFE-NCNN-VS stack including other plugin DLLs, VSPipe.exe and python scripts. Therefore easiest is to copy full `rife-ncnn-vs` directory from latest version of Flowframes as it includes everything bundled-in.

### Step 2 - Download RIFE v4.25 model files

Download `flownet.param` and `flownet.bin` for rife-v4.25_ensembleFalse from:

https://github.com/styler00dollar/VapourSynth-RIFE-ncnn-Vulkan/tree/master/RIFE/models/rife-v4.25_ensembleFalse

Create folder: `%LocalAppData%\Flowframes\FlowframesData\pkgs\rife-ncnn-vs\rife-v4.25\`

Place both files there.

Alternatively, Flowframes can download the model automatically once it is registered in models.json (see next step).

### Step 3 - Register the model in models.json

Edit `%LocalAppData%\Flowframes\FlowframesData\pkgs\rife-ncnn-vs\models.json`. Add the v4.25 entry and set it as default:

```json
[
{
    "name": "RIFE 2.3",
    "desc": "Old Model",
    "dir": "rife-v2.3",
    "isDefault": "false",
    "fixedFactors": [2]
},
{
    "name": "RIFE 4.0",
    "desc": "New Fast General Model",
    "dir": "rife-v4",
    "isDefault": "false"
},
{
    "name": "RIFE 4.3",
    "desc": "New Fast General Model",
    "dir": "rife-v4.3",
    "isDefault": "false"
},
{
    "name": "RIFE 4.4",
    "desc": "Latest Fast General Model",
    "dir": "rife-v4.4",
    "isDefault": "false"
},
{
    "name": "RIFE 4.6",
    "desc": "Previous General Model",
    "dir": "rife-v4.6",
    "isDefault": "false"
},
{
    "name": "RIFE 4.25",
    "desc": "Latest General Model",
    "dir": "rife-v4.25",
    "isDefault": "true"
}
]
```

### Step 4 - VSPipe wrapper

Flowframes 1.40 generates VSPipe.exe command line with parameter `multiplier=X` in rife.vpy. The newer RIFE DLL `librife_windows_x86-64.dll` does not accept this parameter and fails. This VSPipe wrapper patches the `rife.vpy` file with correct parameters for RIFE v4.25 before then calling real VSPipe.

1. Go to `%LocalAppData%\Flowframes\FlowframesData\pkgs\rife-ncnn-vs\`
2. Rename `VSPipe.exe` to `VSPipe_real.exe`
3. Compile `vspipe_wrapper.ahk` as **64-bit console app** using Ahk2Exe with AutoHotkey64.exe as base
4. Place compiled `VSPipe.exe` in the same folder

### Screenshots

<img width="701" height="400" alt="Flowframes_with_RIFEv4 25" src="https://github.com/user-attachments/assets/aefc8807-f15a-4084-9390-9154b32e7387" />


---

## Folder structure after setup

```
pkgs\
  av\
    ffmpeg.exe              <- compiled ffmpeg_wrapper
    ffmpeg_real.exe         <- original ffmpeg renamed
    ffmpeg_wrapper_config.json
    ffmpeg_wrapper.log      <- created at runtime

  rife-ncnn-vs\
    VSPipe.exe              <- compiled vspipe_wrapper
    VSPipe_real.exe         <- original VSPipe renamed
    vspipe_wrapper.log      <- created at runtime
    rife-v4.6\
      flownet.bin
      flownet.param
      files.json
    rife-v4.25\
      flownet.bin
      flownet.param
      files.json
    models.json
    rife.vpy                <- generated by Flowframes, patched by wrapper
```

---

## Notes

Here you get an idea of what can be done to make wanted features work.
If your hardware/video/encoding parameters are different and you get errors - then you may need to do additional research and change this solution to make it work.

---

## License

Do whatever you want with this. No warranty.

