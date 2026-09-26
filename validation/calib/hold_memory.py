"""Hold a known amount of resident memory for a known time: hold_memory.py MIB HOLD_S PRE_S.
Sleeps PRE_S first (randomised phase), then touches MIB MiB, holds HOLD_S, frees, idles 0.5 s."""
import sys, time
mib, hold, pre = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
time.sleep(pre)
buf = b"\x01" * (mib * 2**20)  # filled, so every page is resident
time.sleep(hold)
del buf
time.sleep(0.5)
