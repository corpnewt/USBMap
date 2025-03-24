import os, sys
from . import run

class IOReg:
    def __init__(self):
        self.ioreg = {}
        self.r = run.Run()

    def _get_hex_addr(self,item):
        # Attempts to reformat an item from NAME@X,Y to NAME@X000000Y
        try:
            if not "@" in item:
                # If no address - assume 0
                item = "{}@0".format(item)
            name,addr = item.split("@")
            if "," in addr:
                cont,port = addr.split(",")
            elif len(addr) > 4:
                # Using XXXXYYYY formatting already
                return name+"@"+addr
            else:
                # No comma, and 4 or fewer digits
                cont,port = addr,"0"
            item = name+"@"+hex(int(port,16)+(int(cont,16)<<16))[2:].upper()
        except:
            pass
        return item

    def _get_dec_addr(self,item):
        # Attemps to reformat an item from NAME@X000000Y to NAME@X,Y
        try:
            if not "@" in item:
                # If no address - assume 0
                item = "{}@0".format(item)
            name,addr = item.split("@")
            if addr.count(",")==1:
                # Using NAME@X,Y formating already
                return name+"@"+addr
            if len(addr)<5:
                return "{}@{},0".format(name,addr)
            hexaddr = int(addr,16)
            port = hexaddr & 0xFFFF
            cont = (hexaddr >> 16) & 0xFFFF
            item = name+"@"+hex(cont)[2:].upper()
            if port:
                item += ","+hex(port)[2:].upper()
        except:
            pass
        return item

    def _get_pcix_uid(self,item,allow_fallback=True,fallback_uid=0,plane="IOService",force=False):
        # Helper to look for the passed item's _UID
        # Expects a XXXX@Y style string
        self.get_ioreg(plane=plane,force=force)
        # Ensure our item ends with 2 spaces
        item = item.rstrip()+"  "
        item_uid = None
        found_device = False
        for line in self.ioreg[plane]:
            if item in line:
                found_device = True
                continue
            if not found_device:
                continue # Haven't found it yet
            # We have the device here - let's look for _UID or a closing
            # curly bracket
            if line.replace("|","").strip() == "}":
                break # Bail on the loop
            elif '"_UID" = "' in line:
                # Got a _UID - let's rip it
                try:
                    item_uid = int(line.split('"_UID" = "')[1].split('"')[0])
                except:
                    # Some _UIDs are strings - but we won't accept that here
                    # as we're ripping it specifically for PciRoot/Pci pathing
                    break
        if item_uid is None and allow_fallback:
            return fallback_uid
        return item_uid

    def get_ioreg(self,plane="IOService",force=False):
        if force or not self.ioreg.get(plane,None):
            self.ioreg[plane] = self.r.run({"args":["ioreg", "-lw0", "-p", plane]})[0].split("\n")
        return self.ioreg[plane]

    def get_all_devices(self, plane=None, force=False):
        # Let's build a device dict - and retain any info for each
        if plane is None:
            # Try to use IODeviceTree if it's populated, or if
            # IOService is not populated
            if self.ioreg.get("IODeviceTree") or not self.ioreg.get("IOService"):
                plane = "IODeviceTree"
            else:
                plane = "IOService"
        self.get_ioreg(plane=plane,force=force)
        # We're only interested in these two classes
        class_match = (
            "<class IOPCIDevice,",
            "<class IOACPIPlatformDevice,"
        )
        # Set up some preliminary placeholders
        path_list = {}
        _path = []
        dev_primed = False
        curr_dev = {}
        # Walk the ioreg lines and keep track of the last
        # valid class, indentation, etc
        for line in self.ioreg[plane]:
            if not dev_primed:
                # We're not looking within a device already
                # Only prime on devices
                if not "+-o " in line:
                    continue # Not a class entry
                # Ensure we're keeping track of scope
                parts = line.split("+-o ")
                pad = len(parts[0])
                while len(_path):
                    # Remove any path entries that are nested
                    # equal to or further than our current set
                    if _path[-1][-1] >= pad:
                        del _path[-1]
                    else:
                        break
                if class_match and not any(c in line for c in class_match):
                    continue # Not the right class
                # We found a device of our class - let's
                # retain info about it
                name = parts[1].split("  ")[0]
                clss = parts[1].split("<class ")[1].split(",")[0]
                # Get the decimal address in X,Y format
                a = self._get_dec_addr(name)
                outs = a.split("@")[1].split(",")
                d = outs[0].upper()
                f = 0 if len(outs) == 1 else outs[1].upper()
                # Format as the device path
                dev_path = "Pci(0x{},0x{})".format(d,f)
                _path.append([
                    dev_path,
                    parts[1].split("  ")[0],
                    parts[1].split("<class ")[1].split(",")[0],
                    pad
                ])
                # Prime our device walker
                dev_primed = True
            else:
                # We'd wait until we get a lone closing curly brace
                # to denote the end of a device scope here
                if line.replace("|","").strip() == "}":
                    # Closed - check what kind of device we got
                    dev_primed = False
                    # Retain the curr_dev as a local var
                    # and reset
                    this_dev = curr_dev
                    curr_dev = {}
                    # PCI roots should use PNP0A03 or PNP0A08 in either
                    # name or compatible
                    if any(p in this_dev.get("compatible","")+this_dev.get("name","") for p in ("PNP0A03","PNP0A08")):
                        # Got one - we need to change the type in the last _path entry
                        # and we need to get the _UID
                        try:
                            _uid = int(this_dev.get("_UID","0").strip('"'))
                        except:
                            _uid = 0 # Fall back on zero
                        # Update the device path
                        _path[-1][0] = "PciRoot(0x{})".format(hex(_uid)[2:].upper())
                        # Ensure this is top-level.  Reset if needed.
                        # This can help prevent things like _SB taking priority
                        # in the IOACPIPlane
                        _path = [_path[-1]]
                    elif len(_path) == 1:
                        # Got a lone path that's not a PciRoot()
                        # Skip it to avoid things like CPU objects being added
                        continue
                    # Get our full device path
                    dev_path = "/".join([x[0] for x in _path])
                    # Add a new entry to our path list
                    if dev_path in path_list or not dev_path.startswith("PciRoot("):
                        # Skip - either a duplicate (shouldn't happen), or
                        # it lacks a PciRoot
                        continue
                    # Get our parent's acpi path + ours
                    acpi_path = None
                    if not "/" in dev_path:
                        # We're the PCI root - just save our path
                        # preceeded by /
                        acpi_path = "/{}".format(_path[-1][1])
                    else:
                        # We should have a parent - get their dev path
                        parent_dev_path = "/".join(dev_path.split("/")[:-1])
                        parent_acpi_path = path_list.get(parent_dev_path,{}).get("acpi_path",None)
                        if parent_acpi_path is not None:
                            # We got something - append our path
                            acpi_path = "{}/{}".format(parent_acpi_path,_path[-1][1])
                    path_list[dev_path] = {
                        "device_path":dev_path,
                        "info":this_dev,
                        "segment":_path[-1][0],
                        "name":_path[-1][1],
                        "name_no_addr":_path[-1][1].split("@")[0],
                        "addr": "0" if not "@" in _path[-1][1] else _path[-1][1].split("@")[-1],
                        "type":_path[-1][2],
                        "acpi_path":acpi_path
                    }
                    continue
                # We're walking scope here - try to retain info
                try:
                    name = line.split(" = ")[0].split('"')[1]
                    curr_dev[name] = line.split(" = ")[1]
                except Exception as e:
                    pass
        return path_list

    def get_devices(self, dev_list=None, plane="IOService", force=False):
        # Iterate looking for our device(s)
        # returns a list of devices@addr
        if dev_list is None:
            return []
        if not isinstance(dev_list, list):
            dev_list = [dev_list]
        self.get_ioreg(plane=plane,force=force)
        dev = []
        for line in self.ioreg[plane]:
            if any(x for x in dev_list if x in line) and "+-o" in line:
                dev.append(line.split("+-o ")[1].split("  ")[0])
        return dev

    def get_device_info(self, dev_search=None, isclass=False, parent=None, plane="IOService", force=False):
        # Returns a list of all matched classes and their properties
        if not dev_search:
            return []
        self.get_ioreg(plane=plane,force=force)
        dev = []
        primed = False
        current = None
        path = []
        search = dev_search if not isclass else "<class " + dev_search
        for line in self.ioreg[plane]:
            if "<class " in line:
                # Add each class entry to our path
                path.append(line)
            if not primed and not search in line:
                continue
            # Should have a device - let's see if we need to check a parent
            if parent and not parent in self._walk_path(path):
                # Need a parent, and we don't have it - keep going
                continue
            if not primed:
                primed = True
                current = {"name":dev_search,"parts":{}}
                continue
            # Primed, but not our device
            if "+-o" in line:
                # Past our prime - see if we have a current, save
                # it to the list, and clear it
                primed = False
                if current:
                    dev.append(current)
                    current = None
                continue
            # Primed, not class, not next device - must be info
            try:
                name = line.split(" = ")[0].split('"')[1]
                current["parts"][name] = line.split(" = ")[1]
            except Exception as e:
                pass
        return dev

    def _walk_path(self,path,classes=("IOPCIDevice","IOACPIPlatformDevice")):
        # Got a path - walk backward
        out = []
        prefix = None
        class_match = []
        if classes:
            # Ensure all our classes start with <class
            # and end with ,
            for c in classes:
                c = str(c).strip()
                if not c.startswith("<class "):
                    c = "<class "+c
                if not c.endswith(","):
                    c += ","
                class_match.append(c)
        # Work in reverse to find our path
        for x in path[::-1]:
            if not "+-o " in x:
                continue # Not a class entry
            if class_match and not any(c in x for c in class_match):
                continue # Not the right class
            parts = x.split("+-o ")
            if prefix is None or len(parts[0]) < len(prefix):
                # Path length changed, must be parent?
                item = parts[1].split("  ")[0]
                prefix = parts[0]
                out.append(self._get_hex_addr(item))
        # Reverse the path - ensure we use / as the root
        out = [""]+out[::-1]
        return "/".join(out)

    def get_acpi_path(self, device, parent=None, plane="IOService", force=False):
        if not device:
            return ""
        self.get_ioreg(plane=plane,force=force)
        path = []
        found = False
        # First we find our device if it exists - and save each step
        for x in self.ioreg[plane]:
            if "<class " in x:
                path.append(x)
                if device in x:
                    # Got our device - get the path walked
                    test = self._walk_path(path)
                    if parent:
                        # Verify we have the parent in the path
                        if parent in test:
                            return test
                        # Not in there - keep going
                        continue
                    # No parent check needed - return the test path
                    return test
        # Didn't find anything
        return ""

    def get_device_path(self, device, parent=None, plane="IOService", force=False):
        path = self.get_acpi_path(
            device,
            parent=parent,
            plane=plane,
            force=force
        )
        if not path:
            return ""
        out = path.lstrip("/").split("/")
        dev_path = ""
        for x in out:
            if not len(dev_path):
                # First entry - assume a PCI Root
                _uid = self._get_pcix_uid(x)
                if _uid is None:
                    # Broken path
                    return ""
                dev_path = "PciRoot(0x{})".format(hex(_uid)[2:].upper())
            else:
                # Not first
                x = self._get_dec_addr(x)
                outs = x.split("@")[1].split(",")
                d = outs[0].upper()
                f = 0 if len(outs) == 1 else outs[1].upper()
                dev_path += "/Pci(0x{},0x{})".format(d,f)
        return dev_path
