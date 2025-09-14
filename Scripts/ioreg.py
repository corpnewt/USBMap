import os, sys, binascii, json, gzip
from . import run

class IOReg:
    def __init__(self):
        self.ioreg = {}
        self.pci_devices = []
        self.r = run.Run()
        self.d = None # Placeholder
        # Placeholder for a local pci.ids file.  You can get it from: https://pci-ids.ucw.cz/
        # and place it next to this file
        self.pci_ids_url = "https://pci-ids.ucw.cz"
        self.pci_ids = {}

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

    def get_pci_devices(self, force=False):
        # Uses system_profiler to build a list of connected
        # PCI devices
        if force or not self.pci_devices:
            try:
                self.pci_devices = json.loads(self.r.run({"args":[
                    "system_profiler",
                    "SPPCIDataType",
                    "-json"
                ]})[0])["SPPCIDataType"]
                assert isinstance(self.pci_devices,list)
            except:
                # Failed - reset
                self.pci_devices = []
        return self.pci_devices

    def _update_pci_ids_if_missing(self, quiet=True):
        # Checks for the existence of pci.ids or pci.ids.gz - and attempts
        # to download the latest if none is found.
        pci_ids_path = os.path.join(os.path.dirname(os.path.realpath(__file__)),"pci.ids")
        pci_ids_gz_path = pci_ids_path+".gz"
        found = next((x for x in (pci_ids_path,pci_ids_gz_path) if os.path.isfile(x)),None)
        if found:
            return found
        # Not found - try to update
        return self._update_pci_ids(quiet=quiet)

    def _update_pci_ids(self, quiet=True):
        if self.d is None:
            try:
                # Only initialize if we're actually using it
                from . import downloader
                self.d = downloader.Downloader()
            except:
                return None
        def qprint(text):
            if quiet: return
            print(text)
        qprint("Gathering latest info from {}...".format(self.pci_ids_url))
        try:
            _html = self.d.get_string(self.pci_ids_url,progress=False)
            assert _html
        except:
            qprint(" - Something went wrong")
            return None
        # Try to scrape for the .gz compressed download link
        qprint("Locating download URL...")
        dl_url = None
        for line in _html.split("\n"):
            if ">pci.ids.gz</a>" in line:
                # Got it - build the URL
                try:
                    dl_url = "/".join([
                        self.pci_ids_url.rstrip("/"),
                        line.split('"')[1].lstrip("/")
                    ])
                    break
                except:
                    continue
        if not dl_url:
            qprint(" - Not located")
            return None
        # Got a download URL - let's actually download it
        qprint(" - {}".format(dl_url))
        qprint("Downloading {}...".format(os.path.basename(dl_url)))
        target_path = os.path.join(os.path.dirname(os.path.realpath(__file__)),os.path.basename(dl_url))
        try:
            saved_file = self.d.stream_to_file(dl_url,target_path,progress=not quiet)
        except:
            qprint(" - Something went wrong")
            return None
        if os.path.isfile(target_path):
            qprint("\nSaved to: {}".format(target_path))
            return target_path
        qprint("Download failed.")
        return None

    def _get_pci_ids_dict(self, force=False):
        if self.pci_ids and not force:
            return self.pci_ids
        self.pci_ids = {}
        # Hasn't already been processed - see if it exists, and load it if so
        pci_ids_path = os.path.join(os.path.dirname(os.path.realpath(__file__)),"pci.ids")
        pci_ids_gz_path = pci_ids_path+".gz"
        pci_ids = None
        if os.path.isfile(pci_ids_gz_path):
            # Prioritize the gzip file if found
            try:
                pci_ids = gzip.open(pci_ids_gz_path) \
                .read().decode(errors="ignore").replace("\r","") \
                .split("\n")
            except:
                pass
        if not pci_ids and os.path.isfile(pci_ids_path):
            # Try loading the file
            try:
                with open(pci_ids_path,"rb") as f:
                    pci_ids = f.read().decode(errors="ignore") \
                    .replace("\r","").split("\n")
            except:
                pass
        # Check again
        if not pci_ids:
            return self.pci_ids
        def get_id_name_from_line(line):
            # Helper to rip the id(s) out of the passed
            # line and convert to an int
            try:
                line = line.strip()
                if line.startswith("C "):
                    line = line[2:]
                _id = int(line.split("  ")[0].replace(" ",""),16)
                name = "  ".join(line.split("  ")[1:])
                return (_id,name)
            except:
                return None
        # Walk our file and build out our dict
        _classes = False
        device = sub = None
        key = "devices"
        for line in pci_ids:
            if line.strip().startswith("# List of known device classes"):
                _classes = True
                key = "classes"
                device = sub = None
                continue
            if line.strip().startswith("#"):
                continue # Skip comments
            if line.startswith("\t\t"):
                if sub is None: continue
                # Got a subsystem/programming interface name
                try:
                    _id,name = get_id_name_from_line(line)
                    sub[_id] = name
                except:
                    continue
            elif line.startswith("\t"):
                if device is None: continue
                # Got a device/subclass name
                try:
                    _id,name = get_id_name_from_line(line)
                    device[_id] = sub = {"name":name}
                except:
                    sub = None
                    continue
            else:
                # Got a vendor/class
                try:
                    _id,name = get_id_name_from_line(line)
                    if not key in self.pci_ids:
                        self.pci_ids[key] = {}
                    self.pci_ids[key][_id] = device = {"name":name}
                except:
                    device = sub = None
                    continue
        return self.pci_ids

    def get_device_info_from_pci_ids(self, device_dict):
        # Returns a dictionary containing the following info:
        # {
        #     "vendor":ven,
        #     "device":dev,
        #     "subsystem":sub,
        #     "class":cls,
        #     "subclass":scls,
        #     "programming_interface":pi
        # }
        info = {}
        pci_ids = self._get_pci_ids_dict()
        if not pci_ids:
            return info
        def normalize_id(_id):
            if not isinstance(_id,(int,str)):
                return None
            if isinstance(_id,str):
                if _id.startswith("<") and _id.endswith(">"):
                    _id = _id.strip("<>")
                    try:
                        _id = binascii.hexlify(binascii.unhexlify(_id)[::-1]).decode()
                    except:
                        return None
                try:
                    _id = int(_id,16)
                except:
                    return None
            return _id
        device_info = {}
        # Get the vendor, device, subsystem ids
        v  = normalize_id(device_dict.get("vendor-id"))
        d  = normalize_id(device_dict.get("device-id"))
        sv = normalize_id(device_dict.get("subsystem-vendor-id"))
        si = normalize_id(device_dict.get("subsystem-id"))
        device_info["vendor"] = pci_ids.get("devices",{}).get(v,{}).get("name")
        device_info["device"] = pci_ids.get("devices",{}).get(v,{}).get(d,{}).get("name")
        if sv is not None and si is not None:
            sid = (sv << 16) + si
            device_info["subsystem"] = pci_ids.get("devices",{}).get(v,{}).get(d,{}).get(sid)
        # Resolve our class-code to sub ids if possible
        cc = normalize_id(device_dict.get("class-code"))
        if cc is not None:
            # 0xAAAABBCC
            c = cc >> 16 & 0xFFFF
            s = cc >> 8 & 0xFF
            p = cc & 0xFF
            device_info["class"] = pci_ids.get("classes",{}).get(c,{}).get("name")
            device_info["subclass"] = pci_ids.get("classes",{}).get(c,{}).get(s,{}).get("name")
            device_info["programming_interface"] = pci_ids.get("classes",{}).get(c,{}).get(s,{}).get(p)
        return device_info

    def get_pci_device_name(self, device_dict, pci_devices=None, force=False, use_unknown=True, use_pci_ids=True):
        device_name = "Unknown PCI Device" if use_unknown else None
        if not device_dict or not isinstance(device_dict,dict):
            return device_name
        if "info" in device_dict:
            # Expand the info
            device_dict = device_dict["info"]
        if use_pci_ids:
            pci_dict = self.get_device_info_from_pci_ids(device_dict)
            if pci_dict and pci_dict.get("device"):
                return pci_dict["device"]
        # Compare the vendor-id, device-id, revision-id,
        # subsystem-id, and subsystem-vendor-id if found
        # The system_profiler output prefixes those with "sppci-"
        def normalize_id(_id):
            if not _id:
                return None
            if _id.startswith("<") and _id.endswith(">"):
                _id = _id.strip("<>")
                try:
                    _id = binascii.hexlify(binascii.unhexlify(_id)[::-1]).decode()
                except:
                    return None
            try:
                return int(_id,16)
            except:
                return None
        key_list = (
            "vendor-id",
            "device-id",
            "subsystem-vendor-id",
            "subsystem-id"
        )
        # Normalize the ids
        d_keys = [normalize_id(device_dict.get(key)) for key in key_list]
        if any(k is None for k in d_keys[:2]):
            # vendor and device ids are required
            return device_name
        # - check our system_profiler info
        if not isinstance(pci_devices,list):
            pci_devices = self.get_pci_devices(force=force)
        for pci_device in pci_devices:
            p_keys = [normalize_id(pci_device.get("sppci_"+key)) for key in key_list]
            if p_keys == d_keys:
                # Got a match - save the name if present
                device_name = pci_device.get("_name",device_name)
                break
        return device_name

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
                    line,
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
                    elif _path[-1][2] == "IOACPIPlatformDevice":
                        # Got an ACPI device that's not a PciRoot - skip
                        continue
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
                        "acpi_path":acpi_path,
                        "line":_path[-1][3]
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
