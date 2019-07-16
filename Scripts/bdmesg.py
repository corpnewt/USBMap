import binascii, subprocess, sys

def get_clover_uuid():
    bd = bdmesg()
    if not len(bd):
        return ""
    # Get bdmesg output - then parse for SelfDevicePath
    if not "SelfDevicePath=" in bd:
        # Not found
        return ""
    try:
        # Split to just the contents of that line
        line = bd.split("SelfDevicePath=")[1].split("\n")[0]
        # Get the HD section
        hd   = line.split("HD(")[1].split(")")[0]
        # Get the UUID
        uuid = hd.split(",")[2]
        return uuid
    except:
        pass
    return ""

def get_oc_uuid():
    p = subprocess.Popen(["nvram","4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path"], shell=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    oc, oe = p.communicate()
    oc = _decode(oc)
    try:
        path = oc.split("GPT,")[1].split(",")[0]
    except:
        path = ""
    return path

def get_bootloader_uuid():
    b_uuid = get_clover_uuid()
    if not b_uuid:
        b_uuid = get_oc_uuid()
    return b_uuid

def bdmesg(just_clover = True):
    b = "" if just_clover else _bdmesg(["ioreg","-l","-p","IOService","-w0"])
    if b == "":
        b = _bdmesg(["ioreg","-l","-p","IODeviceTree","-w0"])
    return b

def _decode(var):
    if sys.version_info >= (3,0) and isinstance(var, bytes):
        var = var.decode("utf-8","ignore")
    return var

def _bdmesg(comm):
    # Runs ioreg -l -p IODeviceTree -w0 and searches for "boot-log"
    p = subprocess.Popen(comm, shell=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    bd, be = p.communicate()
    bd = _decode(bd)
    for line in bd.split("\n"):
        # We're just looking for the "boot-log" property, then we need to format it
        if not '"boot-log"' in line:
            # Skip it!
            continue
        # Must have found it - let's try to split it, then get the hex data and process it
        try:
            # Split it up, then convert from hex to ascii
            ascii_bytes = binascii.unhexlify(line.split("<")[1].split(">")[0].encode("utf-8"))
            ascii_bytes = _decode(ascii_bytes)
            return ascii_bytes
        except:
            # Failed to convert
            return ""
    # Didn't find it
    return ""
