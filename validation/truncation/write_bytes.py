#!/usr/bin/env python3
"""Write a known number of bytes from a child that then exits, and linger.

Two mechanisms can make a sampling profiler under-report disk writes:

  attribution  the writing process exits before the monitor's next sample, so a
               monitor that sums /proc/<pid>/io over *currently alive* processes
               loses its counters entirely (Snakemake's benchmark.py does this).
  writeback    bytes written and unlinked before the kernel flushes them may
               never reach the block layer, so write_bytes stays low while wchar
               records the full amount. This is what `samtools sort` temp files do.

--linger-s controls the first, --unlink/--no-fsync the second.
"""
import argparse, os, sys, time

def child_write(path, mib, fsync, unlink):
    buf = b"\xa5" * (1024 * 1024)
    with open(path, "wb") as fh:
        for _ in range(mib):
            fh.write(buf)
        fh.flush()
        if fsync:
            os.fsync(fh.fileno())
    written = os.path.getsize(path)
    if unlink:
        os.unlink(path)
    return written

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mib", type=int, required=True)
    p.add_argument("--path", required=True)
    p.add_argument("--linger-s", type=float, default=0.0,
                   help="parent sleeps this long AFTER the writer child exits")
    p.add_argument("--no-fsync", action="store_true")
    p.add_argument("--unlink", action="store_true",
                   help="delete the file immediately after writing")
    a = p.parse_args()

    pid = os.fork()
    if pid == 0:
        n = child_write(a.path, a.mib, not a.no_fsync, a.unlink)
        os._exit(0 if n == a.mib * 1024 * 1024 else 1)
    _, status = os.waitpid(pid, 0)
    if os.waitstatus_to_exitcode(status) != 0:
        sys.exit("child failed to write the requested bytes")
    time.sleep(a.linger_s)

if __name__ == "__main__":
    main()
