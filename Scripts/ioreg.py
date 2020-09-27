import os, sys
from . import run

class IOReg:
    def __init__(self):
        self.ioreg = {}
        self.r = run.Run()

    def _get_hex_addr(self,item):
        # Attempts to reformat an item from NAME@X,Y to NAME@X000000Y
        try:
            name,addr = item.split("@")
            cont,port = addr.split(",")
            item = name+"@"+hex(int(port,16)+(int(cont,16)<<20)).replace("0x","")
        except:
            pass
        return item

    def _get_dec_addr(self,item):
        # Attemps to reformat an item from NAME@X000000Y to NAME@X,Y
        try:
            name,addr = item.split("@")
            if len(addr)<5:
                return "{}@{},0".format(name,addr)
            port = int(addr,16) & 0xFFFF
            cont = int(addr,16) >> 20 & 0xFFFF
            item = name+"@"+hex(cont).replace("0x","")
            if port:
                item += ","+hex(port).replace("0x","")
        except:
            pass
        return item

    def get_ioreg(self,**kwargs):
        force = kwargs.get("force",False)
        plane = kwargs.get("plane","IOService")
        if force or not self.ioreg.get(plane,None):
            self.ioreg[plane] = self.r.run({"args":["ioreg", "-l", "-p", plane, "-w0"]})[0].split("\n")
        return self.ioreg[plane]

    def get_devices(self,dev_list = None, **kwargs):
        force = kwargs.get("force",False)
        plane = kwargs.get("plane","IOService")
        # Iterate looking for our device(s)
        # returns a list of devices@addr
        if dev_list == None:
            return []
        if not isinstance(dev_list, list):
            dev_list = [dev_list]
        if force or not self.ioreg.get(plane,None):
            self.ioreg[plane] = self.r.run({"args":["ioreg", "-l", "-p", plane, "-w0"]})[0].split("\n")
        dev = []
        for line in self.ioreg[plane]:
            if any(x for x in dev_list if x in line) and "+-o" in line:
                dev.append(line.split("+-o ")[1].split("  ")[0])
        return dev

    def get_device_info(self, dev_search = None, **kwargs):
        force = kwargs.get("force",False)
        plane = kwargs.get("plane","IOService")
        isclass = kwargs.get("isclass",False)
        parent = kwargs.get("parent",None)
        # Returns a list of all matched classes and their properties
        if not dev_search:
            return []
        if force or not self.ioreg.get(plane,None):
            self.ioreg[plane] = self.r.run({"args":["ioreg", "-l", "-p", plane, "-w0"]})[0].split("\n")
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

    def _walk_path(self,path):
        # Got a path - walk backward
        out = []
        prefix = None
        # Work in reverse to find our path
        for x in path[::-1]:
            parts = x.split("+-o ")
            if prefix == None or len(parts[0]) < len(prefix):
                # Path length changed, must be parent?
                item = parts[1].split("  ")[0]
                prefix = parts[0]
                out.append(self._get_hex_addr(item))
        # Reverse the path
        out = out[::-1]
        return "/".join(out)

    def get_acpi_path(self, device, **kwargs):
        force = kwargs.get("force",False)
        plane = kwargs.get("plane","IOService")
        parent = kwargs.get("parent",None)
        if not device:
            return ""
        if force or not self.ioreg.get(plane,None):
            self.ioreg[plane] = self.r.run({"args":["ioreg", "-l", "-p", plane, "-w0"]})[0].split("\n")
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

    def get_device_path(self, device, **kwargs):
        path = self.get_acpi_path(device, **kwargs)
        if not path:
            return ""
        out = path.split("/")
        dev_path = ""
        for x in out:
            if not "@" in x:
                continue
            if not len(dev_path):
                # First entry
                dev_path = "PciRoot(0x{})".format(x.split("@")[1])
            else:
                # Not first
                x = self._get_dec_addr(x)
                outs = x.split("@")[1].split(",")
                d = outs[0]
                f = 0 if len(outs) == 1 else outs[1]
                dev_path += "/Pci(0x{},0x{})".format(d,f)
        return dev_path
