#!/bin/bash
# Hardware verification for a USB stick: pattern write/read-back, targeted
# region stability, then f3probe. Usage: hwtest.sh [/dev/sdX] [suspect_MiB]
DEV=${1:-/dev/sdb}
SUSPECT_MIB=${2:-0}
[ "$(lsblk -dno TRAN $DEV)" = "usb" ] || { echo "ABORT: not usb"; exit 1; }
umount ${DEV}* 2>/dev/null
SECTORS=$(blockdev --getsz $DEV)
echo "== device $DEV, $SECTORS sectors =="
echo "== pattern write/readback: first 1MB, last 1MB, spread markers, suspect region =="
DEV=$DEV SECTORS=$SECTORS SUSPECT_MIB=$SUSPECT_MIB python3 - <<'PY'
import os, hashlib, mmap, time
DEV=os.environ['DEV']; total=int(os.environ['SECTORS']); sus=int(os.environ['SUSPECT_MIB'])
fd=os.open(DEV,os.O_RDWR|os.O_DIRECT|os.O_SYNC)
def stamp(lba,n):
    b=mmap.mmap(-1,n*512)
    for k in range(n):
        b[k*512:(k+1)*512]=hashlib.md5(b'LBA%d'%(lba+k)).digest()*32
    return b
def wr(lba,n): os.pwritev(fd,[stamp(lba,n)],lba*512)
def chk(lba,n):
    b=mmap.mmap(-1,n*512); os.preadv(fd,[b],lba*512)
    exp=stamp(lba,n)
    return [k for k in range(n) if b[k*512:(k+1)*512]!=exp[k*512:(k+1)*512]]
tests=[(0,2048),(total-2048,2048)]
if sus: tests.append((sus*2048-8192, 200*2048))   # ~100 MiB around suspect region
spread=[(lba,8) for lba in range(4096, total-8, 4194304)]
for lba,n in tests+spread: wr(lba,n)
os.fsync(fd)
os.system('sync; echo 3 > /proc/sys/vm/drop_caches')
for lba,n in tests:
    bad=chk(lba,n); print(f"region LBA {lba} x{n} ({lba*512/1e9:.1f} GB): {len(bad)} bad sectors", bad[:5])
if sus:
    lba,n=tests[-1]
    for t in range(3):
        time.sleep(1); bad=chk(lba,n); print(f"  suspect region re-read {t}: {len(bad)} bad sectors")
badspread=[lba for lba,n in spread if chk(lba,n)]
print(f"spread markers: {len(spread)} written, {len(badspread)} failed readback")
if badspread: print("failed at LBAs (GB):",[round(l*512/1e9,1) for l in badspread[:15]])
PY
echo "== f3probe =="
f3probe --destructive --time-ops $DEV 2>&1 | grep -vE '^$|Copyright|free software|WARNING|it can take|Probing normally' | tail -20
echo "HWTEST_DONE"
