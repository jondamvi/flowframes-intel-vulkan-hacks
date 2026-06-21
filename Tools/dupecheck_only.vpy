import os
from collections import Counter
import vapoursynth as vs
core = vs.core

# ==============================================================================
# Detects repeated/held source frames (the "object jumps between positions"
# stutter from an FLV re-encode). Runs the check at SCRIPT-LOAD time and writes
# a log + an auto-classified SUMMARY before any encoding starts, then emits a
# short stub clip so FlowFrames/vspipe runs a normal-looking (but trivial) job.
#
# Read <input>_dupecheck.log -> the SUMMARY block at the bottom tells you the
# pattern and the matching dedup approach. You can cancel once the log appears.
#
# SPEED NOTE: the check decodes every frame in CHECK_FRAMES at source res. For a
# 5K input that's slow. Two ways to make it fast:
#   - point inputPath at the ORIGINAL 720p file (dupes are identical pre/post
#     upscale, and 720p decodes ~50x faster), or
#   - set CHECK_FRAMES to a frame cap instead of 0 (full).
# ==============================================================================

# ---- input (change ONLY this) ------------------------------------------------
inputPath = r'C:\Videos\Test_Video.mp4'

# ---- params ------------------------------------------------------------------
CHECK_FRAMES  = 0        # 0 = whole file; or e.g. 1500 to cap (faster on 5K)
DUP_THRESHOLD = 1e-4     # mean abs frame-to-frame diff below this = duplicate.
                         # raise to ~1e-3 if the re-encode added light noise to dupes
PROBE_W, PROBE_H = 256, 144   # diff is done on a tiny luma proxy (decode dominates;
                              # a true dup is a dup at any resolution)
STUB_SECONDS  = 4        # length of the throwaway stub output (0 = full passthrough)

# ---- derived paths -----------------------------------------------------------
inputDir = os.path.dirname(inputPath)
baseName = os.path.splitext(os.path.basename(inputPath))[0]
tempDir  = os.path.join(inputDir, baseName + '-temp')

indexFilePath = inputPath + '.cache.lwi'
if os.path.isdir(tempDir):
    indexFilePath = os.path.join(tempDir, 'cache.lwi')

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_LOG = os.path.join(_SCRIPT_DIR, baseName + '_dupecheck.log')


def _tc(frame_idx, fps):
    s = frame_idx / fps if fps else 0
    h = int(s // 3600); m = int((s % 3600) // 60); sec = s % 60
    return "{:02d}:{:02d}:{:06.3f}".format(h, m, sec)


# ------------------------------------------------------------------------------
# Source
# ------------------------------------------------------------------------------
clip = core.lsmas.LWLibavSource(inputPath, cachefile=indexFilePath)
fps = clip.fps_num / clip.fps_den if clip.fps_den else 25.0
n_total = clip.num_frames

# matrix only needed if source is RGB (for the luma proxy); YUV needs none
cMatrix = '709'
try:
    if clip.get_frame(0).props._Matrix == 9:  cMatrix = '2020ncl'
except Exception:
    pass

# ------------------------------------------------------------------------------
# Tiny luma proxy, then frame-to-frame diff: PlaneStatsDiff = mean|f(i)-f(i+1)|
# ------------------------------------------------------------------------------
if clip.format.color_family == vs.RGB:
    probe = core.resize.Bilinear(clip, PROBE_W, PROBE_H, format=vs.GRAY8, matrix_s=cMatrix)
else:
    probe = core.resize.Bilinear(clip, PROBE_W, PROBE_H, format=vs.GRAY8)

a = probe[:-1]
b = probe[1:]
diff = core.std.PlaneStats(a, b)          # valid indices 0 .. n_total-2

limit = diff.num_frames if CHECK_FRAMES <= 0 else min(CHECK_FRAMES, diff.num_frames)

# ------------------------------------------------------------------------------
# Run the check NOW (at load), write per-frame log + classified SUMMARY
# ------------------------------------------------------------------------------
dups = []
with open(_LOG, "w", encoding="utf-8") as f:
    f.write("==== duplicate-frame check ====\n")
    f.write("input   : {}\n".format(inputPath))
    f.write("frames  : {} total, checking {} , fps {:.3f}\n".format(n_total, limit, fps))
    f.write("threshold: diff < {} = DUP (frame i == frame i+1)\n".format(DUP_THRESHOLD))
    f.write("-" * 60 + "\n")
    f.write("idx\tdiff\t\ttimecode\tflag\n")
    for i in range(limit):
        d = diff.get_frame(i).props.PlaneStatsDiff
        is_dup = d < DUP_THRESHOLD
        if is_dup:
            dups.append(i)
        f.write("{}\t{:.7f}\t{}\t{}\n".format(i, d, _tc(i, fps), "DUP" if is_dup else ""))

    # ---- classify ----
    f.write("\n" + "=" * 60 + "\n")
    f.write("SUMMARY\n")
    f.write("=" * 60 + "\n")
    f.write("checked frames : {}\n".format(limit))
    f.write("duplicates     : {}  ({:.2f}% of checked)\n".format(
        len(dups), 100.0 * len(dups) / limit if limit else 0))
    if not dups:
        f.write("pattern        : NONE — no duplicate frames found in range.\n")
        verdict = "NONE"
    else:
        span_lo, span_hi = dups[0], dups[-1]
        f.write("dup span       : frame {}..{}  ({} .. {})\n".format(
            span_lo, span_hi, _tc(span_lo, fps), _tc(span_hi, fps)))
        gaps = [dups[k + 1] - dups[k] for k in range(len(dups) - 1)]
        contiguous = bool(gaps) and all(g == 1 for g in gaps)
        if not gaps or contiguous:
            verdict = "CLUSTERED"
            f.write("pattern        : CLUSTERED RUN (a held/frozen block of frames)\n")
            f.write("suggested fix  : drop or RIFE-fill that run; it's a frozen\n")
            f.write("                 opening, not periodic — targeted, not VDecimate.\n")
        else:
            c = Counter(gaps)
            common, cnt = c.most_common(1)[0]
            if common > 1 and cnt >= 0.7 * len(gaps):
                verdict = "PERIODIC"
                f.write("pattern        : PERIODIC — a DUP roughly every {} frames\n".format(common))
                f.write("                 (cadence/pulldown artifact).\n")
                f.write("suggested fix  : core.vivtc.VDecimate (drops 1 dup per cycle).\n")
            else:
                verdict = "SCATTERED"
                f.write("pattern        : SCATTERED — irregular dupes, no steady rhythm\n")
                f.write("                 (classic FLV re-encode).\n")
                f.write("suggested fix  : diff-based REPLACE — swap each dup for a RIFE\n")
                f.write("                 frame between its real neighbours (keeps length+sync).\n")
        # show the actual dup indices (capped) so you can see the distribution
        shown = dups if len(dups) <= 80 else dups[:80]
        f.write("dup indices    : {}{}\n".format(
            ", ".join(map(str, shown)), "" if len(dups) <= 80 else " ...(+{} more)".format(len(dups) - 80)))

print("[dupecheck] {} dups in first {} frames -> {} | log: {}".format(len(dups), limit, verdict, _LOG))

# ------------------------------------------------------------------------------
# Stub output so FlowFrames/vspipe runs a normal-looking job. The real result is
# the log above; you can cancel here. Short by default so letting it finish is cheap.
# ------------------------------------------------------------------------------
stub = clip
if STUB_SECONDS > 0:
    stub = stub[: int(STUB_SECONDS * fps)]
stub = core.resize.Bicubic(stub, format=vs.YUV420P8, matrix_s=cMatrix)
stub.set_output()
