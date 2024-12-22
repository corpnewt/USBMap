import os, sys, re, json, binascii, shutil
from Scripts import run, utils, ioreg, plist, reveal
from collections import OrderedDict
from datetime import datetime

class USBMap:
    def __init__(self):
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        self.u = utils.Utils("USBMap")
        # Verify running os
        if not sys.platform.lower() == "darwin":
            self.u.head("Wrong OS!")
            print("")
            print("USBMap can only be run on macOS!")
            print("")
            self.u.grab("Press [enter] to exit...")
            exit()
        self.r = run.Run()
        self.i = ioreg.IOReg()
        self.re = reveal.Reveal()
        self.map_hubs = True # Enable to show hub ports/devices in mapping
        self.controllers = None
        self.smbios = None
        self.os_build_version = "Unknown"
        self.os_version = "0.0.0"
        self.usb_port = re.compile(r"Apple[a-zA-Z0-9]*USB\d*[A-Z]+Port,")
        self.usb_cont = re.compile(r"Apple[a-zA-Z0-9]*USB[0-9A-Z]+,")
        self.usb_hub  = re.compile(r"Apple[a-zA-Z0-9]*USB\d+[a-zA-Z]*Hub,")
        self.usb_hubp = re.compile(r"Apple[a-zA-Z0-9]*USB\d+[a-zA-Z]*HubPort,")
        self.usb_ext  = [
            re.compile(r"<class [a-zA-Z0-9]*BluetoothHostControllerUSBTransport,"),
            re.compile(r"^(?!.*IOUSBHostDevice@).*<class IOUSBHostDevice,") # Matches IOUSBHostDevice classes that are *not* named IOUSBHostDevice (avoids entry spam in discovery)
        ] # List of extra objects to match against
        self.discover_wait = 5
        self.default_names = ("XHC1","EHC1","EHC2")
        self.cs = u"\u001b[32;1m"
        self.ce = u"\u001b[0m"
        self.bs = u"\u001b[36;1m"
        self.rs = u"\u001b[31;1m"
        self.nm = u"\u001b[35;1m"
        self.ioreg = self.populate_ioreg()
        self.local_ioreg = False # Switched to true if we're reading from a local ioreg.txt file
        self.by_ioreg = None
        self.usb_list = "./Scripts/USB.plist"
        self.output   = "./Results"
        self.ssdt_path = os.path.join(self.output,"SSDT-USB-Reset.dsl")
        self.rsdt_path = os.path.join(self.output,"SSDT-RHUB-Reset.dsl")
        self.kext_path = os.path.join(self.output,"USBMap.kext")
        self.info_path = os.path.join(self.kext_path,"Contents","Info.plist")
        self.legacy_kext_path = os.path.join(self.output,"USBMapLegacy.kext")
        self.legacy_info_path = os.path.join(self.legacy_kext_path,"Contents","Info.plist")
        self.dummy_kext_path = os.path.join(self.output,"USBMapDummy.kext")
        self.dummy_info_path = os.path.join(self.dummy_kext_path,"Contents","Info.plist")
        self.dummy_legacy_kext_path = os.path.join(self.output,"USBMapLegacyDummy.kext")
        self.dummy_legacy_info_path = os.path.join(self.dummy_legacy_kext_path,"Contents","Info.plist")
        self.oc_patches = os.path.join(self.output,"patches_OC.plist")
        self.clover_patches = os.path.join(self.output,"patches_Clover.plist")
        self.merged_list = OrderedDict()
        # Load the USB list as needed
        if os.path.exists(self.usb_list):
            try:
                with open(self.usb_list,"rb") as f:
                    self.merged_list = plist.load(f,dict_type=OrderedDict)
            except: pass
        if not isinstance(self.merged_list,dict):
            self.merged_list = OrderedDict()
        # Populate the controllers and initialize our addresses list
        self.connected_controllers = self.check_controllers()
        self.all_addrs = []
        # Get illegal names
        self.plugin_path = "/System/Library/Extensions/IOUSBHostFamily.kext/Contents/PlugIns"
        self.illegal_names = self.get_illegal_names()

    def get_illegal_names(self):
        if not self.smbios or not os.path.exists(self.plugin_path):
            return [x for x in self.default_names] # No SMBIOS, fall back on defaults
        illegal_names = []
        for plugin in os.listdir(self.plugin_path):
            plug_path = os.path.join(self.plugin_path,plugin)
            info_path = os.path.join(plug_path,"Contents","Info.plist")
            if plugin.startswith(".") or not os.path.isdir(plug_path): continue # Skip invisible or non-directories
            # Got a valid directory - let's check the Info.plist
            if not os.path.exists(info_path): continue # Doesn't exist
            # Try to load, then walk the structure
            try:
                with open(info_path,"rb") as f:
                    plist_data = plist.load(f)
            except: continue # Borked Info.plist - skip
            for key in plist_data:
                if not key.startswith("IOKitPersonalities"): continue
                # Got the proper key, let's walk the structure
                walk_dict = plist_data[key]
                for k in walk_dict:
                    # Find out if we have a model and IONameMatch here
                    smbios_entry = walk_dict[k]
                    if not all((x in smbios_entry for x in ("model","IONameMatch"))): continue # No matches
                    # Got both - let's see if the SMBIOS is ours
                    if not smbios_entry["model"] == self.smbios: continue # Mismatch, skip
                    # Take note of the IONameMatch, and add it to the illegal_names list
                    illegal_names.append(smbios_entry["IONameMatch"])
        return sorted(list(set(illegal_names)))

    def get_map_list(self):
        map_list = [self.usb_cont,self.usb_port,self.usb_hub]+self.get_usb_ext_list()
        if self.map_hubs: map_list.append(self.usb_hubp)
        return map_list

    def get_port_map_list(self):
        map_list = [self.usb_port]
        if self.map_hubs: map_list.append(self.usb_hubp)
        return map_list

    def get_usb_ext_list(self):
        usb_ext_list = [x for x in self.usb_ext] # Ensure we only take a copy of the list
        if self.map_hubs: usb_ext_list.append(self.usb_hubp) # Get hub ports if we're mapping hubs
        return usb_ext_list

    def get_matching_controller(self,controller_name,from_cont=None,into_cont=None):
        self.check_controllers()
        from_cont = from_cont if from_cont != None else self.controllers
        into_cont = into_cont if into_cont != None else self.merged_list
        assert controller_name in from_cont # Can't match if it doesn't exist!
        # We try matching by most specific to most general, location -> pcidebug -> ioservice -> acpi -> name@addr -> name
        for check in ("locationid","pci_debug","ioservice_path","acpi_path"):
            cont_adj = next((x for x in into_cont if from_cont[controller_name].get(check,None) == into_cont[x].get(check,"Unknown")),None)
            if cont_adj: return cont_adj
        # Didn't match - we can't rely on just names as there might be multiple PXSX devices
        return None

    def merge_controllers(self,from_cont=None,into_cont=None):
        self.check_controllers()
        from_cont = from_cont if from_cont != None else self.controllers
        into_cont = into_cont if into_cont != None else self.merged_list
        # Helper function to combine from_cont's settings with into_cont's
        for cont in from_cont:
            # Skip any that don't exist - controllers don't materialize out of nothing
            # They do apparently change addresses though - so try to match by name... this *hopes* that
            # the users has setup unique names for all controllers first.
            cont_adj = self.get_matching_controller(cont,from_cont,into_cont)
            if not cont_adj: cont_adj = cont
            # Ensure we have a ports dict
            last_step = into_cont
            for step in (cont_adj,"ports"):
                if not step in last_step: last_step[step] = {}
                last_step = last_step[step]
            # Pull any missing information in
            for key in from_cont[cont]:
                if key == "ports": continue # Handle ports separately
                into_cont[cont_adj][key] = from_cont[cont][key]
            # Only pull saved items into the new dict
            for port_num in from_cont[cont]["ports"]:
                port = from_cont[cont]["ports"][port_num]
                mort = into_cont[cont_adj]["ports"].get(port_num,{})
                # Let's walk the keys
                for key in port:
                    # Merge item lists as sets to avoid duplicates
                    if key == "items":
                        new_items = []
                        for x in mort.get("items",[])+port.get("items",[]):
                            if not x in new_items: new_items.append(x)
                        mort["items"] = new_items
                    elif key == "enabled":
                        # Don't override explicit settings from the edit screen
                        if port.get(key,None) != None and mort.get(key,None) == None:
                            mort[key] = port[key]
                    elif key in ("name","id") and key in mort: continue # Skip the name and id to always use the most recent
                    else: mort[key] = port[key]
                # Reset the into_cont port
                into_cont[cont_adj]["ports"][port_num] = mort
        return into_cont

    def save_plist(self,controllers=None):
        if controllers == None: controllers = self.merged_list
        self.sanitize_controllers(controllers)
        # Ensure the lists are the same
        try:
            with open(self.usb_list,"wb") as f:
                plist.dump(controllers,f,sort_keys=False)
            return True
        except Exception as e:
            print("Could not save to USB.plist! {}".format(e))
        return False

    def sanitize_controllers(self, controllers=None):
        if controllers is None: controllers = self.merged_list
        # Walk each controller and strip any red ansi escapes from the names
        for controller in controllers:
            if not "ports" in controllers[controller]: continue
            for port in controllers[controller]["ports"]:
                controllers[controller]["ports"][port]["items"] = [x.replace(self.rs,"").replace(self.ce,"") for x in controllers[controller]["ports"][port]["items"]]

    def sanitize_ioreg(self,ioreg):
        # Walks the passed ioreg and attempts to fix devices with newlines in their names
        # by replacing them with spaces
        return_list = isinstance(ioreg,list)
        if return_list: ioreg = "\n".join(ioreg)
        new_ioreg = ""
        combine_last = False
        for line in ioreg.split("\n"):
            new_ioreg += line+(" " if "+-o" in line and not "  <class" in line else "\n")
        return new_ioreg.split("\n") if return_list else new_ioreg

    def populate_ioreg(self):
        if os.path.exists("ioreg.txt"):
            with open("ioreg.txt","rb") as f:
                ioreg = f.read().decode("utf-8",errors="ignore").split("\n")
                self.i.ioreg = {"IOService":ioreg}
            self.local_ioreg = True
        else:
            ioreg = self.i.get_ioreg()
        return self.sanitize_ioreg(ioreg)

    def check_controllers(self):
        if not self.controllers: self.controllers = self.populate_controllers()
        assert self.controllers # Error if it's not populated after forcing
        # Ensure we're returning a copy
        controller_copy = {}
        for key in self.controllers:
            controller_copy[key] = self.controllers[key]
        return controller_copy

    def check_by_ioreg(self,force=False):
        if force or not self.by_ioreg: self.by_ioreg = self.get_by_ioreg()
        assert self.by_ioreg # Error if it's not populated after updating
        return self.by_ioreg

    def get_obj_from_line(self, line):
        # Breaks a line into usable components - returns a dict on success, None on error
        try:
            return {
                "line":line,
                "indent":len(line)-len(line.lstrip()),
                "id":line.split("id ")[-1],
                "name":line.lstrip().split("  <class")[0],
                "type":line.split("<class ")[1].split(",")[0],
                "items":{}
            }
        except Exception as e:
            print(e)
        return None # Bad values - bail

    def get_by_ioreg(self):
        # Get a dict of all populated ports and their AppleUSBDevices
        if os.path.exists("ioreg.txt"):
            with open("ioreg.txt","rb") as f:
                ioreg = f.read().decode("utf-8",errors="ignore")
            self.local_ioreg = True
        else:
            ioreg = self.r.run({"args":["ioreg","-c","IOUSBDevice","-w0"]})[0]
        ioreg = self.sanitize_ioreg(ioreg)
        port_map = self.get_port_map_list()
        # Trim the list down to only what we want
        valid = [x.replace("|"," ").replace("+-o ","").split(", registered")[0] for x in ioreg.split("\n") if any((y.search(x) for y in self.get_map_list()))]
        # Initialize our dict and a list for all addresses
        ports = {"items":{}}
        addrs = []
        path  = []
        for line in valid:
            # Check each line to pull addresses for later use if not a controller/mapped hub
            if not (self.usb_cont.search(line) or (self.map_hubs and self.usb_hub.search(line))):
                try:
                    addr = line.split("@")[-1].split("<class ")[0].strip()
                    if not addr in addrs:
                        addrs.append(addr)
                except:
                    pass
            # Resolve the line to an object
            obj = self.get_obj_from_line(line)
            if not obj:
                continue # borked
            if path:
                # Walk our path in reverse and remove any entry
                # whose indent is >= our current object as none can
                # be its parent
                for p in path[::-1]:
                    if p["indent"] >= obj["indent"]:
                        del path[-1]
                    else:
                        break
            # Let's see if we got a controller
            if self.usb_cont.search(line):
                # Reset the path to the new controller
                path = [obj]
                continue
            if not path:
                continue
            # Check if we're mapping hubs, matched the hub regex, and the root controller is EHCI
            path.append(obj)
            if any((x.search(line) for x in self.get_usb_ext_list())):
                map_hub = True # Assume we map unless a parent is XHCI - then aggregate XHCI hubs under the parent ports
                if any(("XHCI" in x["type"] for x in path)):
                    # Let's omit USB hub ports from XHCI controller outputs as we do not map these and they just add clutter
                    if self.usb_hubp.search(path[-1]["line"]): continue # Ends on a hub port - bail
                    # Strip out any other hub ports
                    path = [x for x in path if not self.usb_hubp.search(x["line"])]
                    map_hub = False
                # Walk the paths, and add them by id to the ports dict
                last_root = ports
                # Iterate each path element and ensure it exists in the ports dict
                for p in path:
                    # Check the type to see if we got a device - if so, disable
                    # map_hub to avoid mapping external device hubs
                    if p["type"] == "IOUSBHostDevice": map_hub = False
                    p["map_hub"] = map_hub
                    if not p["id"] in last_root["items"]:
                        # Add it if it doesn't exist
                        last_root["items"][p["id"]] = p
                    # Reset our reference to the current scope
                    last_root = last_root["items"][p["id"]]
        # Update a local copy of addresses
        self.all_addrs = addrs
        return ports  

    def get_sp_usb(self,indent="    "):
        # Gather a top-level array of USB devices plugged in per system_profiler
        sp_usb_list = []
        try:
            if self.local_ioreg: # Only consider the system_profiler.txt if we have a local ioreg.txt
                if os.path.exists("system_profiler.txt"):
                    with open("system_profiler.txt","rb") as f:
                        sp_usb_xml = plist.load(f)
                else: # Not found - just return the empty list to avoid merging improper info
                    return sp_usb_list
            else:
                sp_usb_xml = plist.loads(self.r.run({"args":["system_profiler","-xml","-detaillevel","mini","SPUSBDataType"]})[0])
        except:
            return sp_usb_list
        items_list = []
        for top in sp_usb_xml:
            if "_items" in top:
                items_list.extend(top["_items"])
        while items_list:
            item = items_list.pop()
            if "location_id" in item:
                try: item["location_id_adjusted"] = item["location_id"][2:].split()[0]
                except: continue # Broken
                if not "indent" in item:
                    item["indent"] = ""
                sp_usb_list.append(item)
            if "_items" in item:
                new_items = item.pop("_items")
                for i in new_items:
                    i["indent"] = item.get("indent","")+indent
                items_list.extend(new_items)
        return sp_usb_list

    def map_inheritance(self,top_level,level=1,indent="    "):
        # Iterates through all "items" entries in the top_level dict
        # and returns a formatted string showing inheritance
        if not "items" in top_level: return []
        text = []
        for v in top_level["items"]:
            check_entry = top_level["items"][v]
            is_hub = self.usb_hub.search(check_entry.get("line","Unknown"))
            try: name,addr = check_entry.get("name","Unknown").split("@")
            except:
                addr = "Unknown"
                name = check_entry.get("name",check_entry.get("type","Unknown"))
            value = (indent * level) + "- {}{}".format(name, " (HUB-{})".format(addr) if is_hub and check_entry.get("map_hub",False) and self.map_hubs else "")
            text.append((value,name))
            # Verify if we're on a hub and mapping those
            if is_hub and check_entry.get("map_hub",False) and self.map_hubs:
                # Got a hub - this will be mapped elsewhere
                continue
            # Check if we have items to map
            if len(check_entry.get("items",[])):
                # We have items!
                text.extend(self.map_inheritance(check_entry,level+1))
        return text

    def get_port_from_dict(self,port_id,top_level):
        if port_id in top_level["items"]: return top_level["items"][port_id]
        for port in top_level["items"]:
            test_port = self.get_port_from_dict(port_id,top_level["items"][port])
            if test_port: return test_port
        return None

    def get_items_for_port(self,port_id,indent="    "):
        port = self.get_port_from_dict(port_id,self.check_by_ioreg())
        if not port: return [] # No items, or the port wasn't found?
        return self.map_inheritance(port)

    def get_ports_and_devices_for_controller(self,controller,sp_usb_list=[],indent="    "):
        self.check_controllers()
        assert controller in self.controllers # Error if the controller doesn't exist
        port_dict = OrderedDict()
        # Gather a list of any duplicate port addresses
        port_addrs = [self.controllers[controller]["ports"][p]["address"] for p in self.controllers[controller]["ports"]]
        dupe_addrs = [x for x in port_addrs if port_addrs.count(x)>1]
        # Walk the ports
        for port_num in sorted(self.controllers[controller]["ports"]):
            port = self.controllers[controller]["ports"][port_num]
            # The name of each entry should be "PortName - PortNum (Controller)"
            port_num = self.hex_dec(self.hex_swap(port["port"]))
            entry_name = "{} | {} | {} | {} | {} | {} | {}".format(port["name"],port["type"],port["port"],port["address"],port.get("connector",-1),controller,self.controllers[controller]["parent"])
            inheritance = self.get_items_for_port(port["id"],indent=indent)
            port_dict[entry_name] = [x[0] for x in inheritance] # Get the values
            names = [x[1] for x in inheritance] # Get the original names for comparing
            # Check if we're missing any items from the system_profiler output for that port
            for item in sp_usb_list:
                try:
                    l_id = item["location_id_adjusted"]
                    name = item["_name"].lstrip() # Strip leading spaces to match the ioreg info
                except: continue # Broken?
                # Get the closest address - if any
                if l_id in self.all_addrs:
                    closest_addr = l_id
                else:
                    l_id_strip = l_id.rstrip("0")
                    closest_addr = None
                    for addr in self.all_addrs:
                        addr_strip = addr.rstrip("0")
                        if l_id_strip == addr_strip:
                            # Got an exact match - save it
                            closest_addr = addr
                            break
                        if l_id_strip.startswith(addr_strip) and (not closest_addr or len(addr_strip) > len(closest_addr.rstrip("0"))):
                            # We got a *closer* address - save it
                            closest_addr = addr
                if closest_addr != port["address"]:
                    continue # Not our port
                if name in names:
                    continue # Already have it
                # Adjust the indent as needed - useful for formatting nested HUB ports
                ind = item.get("indent",indent)[len(indent)*self.controllers[controller].get("nest_level",0):]
                # We found one that we didn't have - check if it's potentially on a duplicate
                # address and highlight it
                port_dict[entry_name].append("{}* {}{}{}".format(
                    ind,
                    self.rs if port["address"] in dupe_addrs else "",
                    name,
                    self.ce if port["address"] in dupe_addrs else ""
                ))
        return port_dict

    def get_ports_and_devices(self,indent="    "):
        # Returns a dict of all ports and their connected devices
        self.check_controllers()
        port_dict = OrderedDict()
        # Get the system_profiler USB output
        sp_usb_list = self.get_sp_usb()
        for x in self.controllers:
            port_dict.update(self.get_ports_and_devices_for_controller(x,sp_usb_list=sp_usb_list,indent=indent))
        return port_dict

    def get_populated_count_for_controller(self,controller):
        port_dict = self.get_ports_and_devices_for_controller(controller)
        return len([x for x in port_dict if len(port_dict[x])])

    def get_ioservice_path(self,check_line):
        line_id = "id "+check_line.split(", registered")[0].split("id ")[-1]
        for index,line in enumerate(self.ioreg):
            if not line_id in line: continue
            # Walk backwards, keeping track of any stepped up path elements
            indent = -1
            path = []
            for l in self.ioreg[index::-1]:
                if not "  <class" in l: continue # Only consider classes
                l_check = l.replace("|"," ").replace("+-o","")
                i_check = len(l_check) - len(l_check.lstrip())
                if i_check < indent or indent == -1: # Got a step up - add it
                    entry = l_check.lstrip().split("  <class")[0]
                    if entry == self.smbios: break # We got our SMBIOS - bail
                    path.append(entry)
                    indent = i_check
            return "IOService:/"+"/".join(path[::-1])
        return None

    def populate_controllers(self):
        assert self.ioreg != None # Error if we have no ioreg to iterate
        self.smbios = None
        port_map = self.get_port_map_list()
        controllers = OrderedDict()
        # Trim the list down to only what we want - and the indexes in self.ioreg where they show up
        map_list = self.get_map_list()
        map_list.extend([
            re.compile("<class IOPlatformExpertDevice,"), # Catch SMBIOS info
            re.compile("<class IOPCIDevice,") # Get parent devices
        ])
        valid = [(x.replace("|"," ").replace("+-o ","").split(", registered")[0],i) for i,x in enumerate(self.ioreg) if any((y.search(x) for y in map_list))]
        controllers = {}
        cont_list = []
        last_port = None
        last_pci  = None
        for line,i in valid:
            if "<class IOPlatformExpertDevice," in line:
                # Retain the SMBIOS
                self.smbios = line.split("<class")[0].strip()
                continue
            elif "<class IOPCIDevice," in line:
                # Retain the last PCI device found
                last_pci = (line,i)
                continue
            # Try to extract the object info from the line
            obj = self.get_obj_from_line(line)
            if not obj:
                continue # Borked
            # Reorganize the dict slightly
            obj["full_name"] = obj["name"]
            obj["name"]      = obj["full_name"].split("@")[0]
            obj["address"]   = obj["full_name"].split("@")[-1]
            obj["items"]     = []
            # Let's see if we've jumped scope
            if cont_list:
                # Walk our cont_list in reverse and remove any entry
                # whose indent is >= our current object as none can
                # be its parent
                for c in cont_list[::-1]:
                    if controllers[c]["indent"] >= obj["indent"]:
                        del cont_list[-1]
                    else:
                        break
            if self.usb_cont.search(line):
                # Got a controller match
                last_controller = obj["full_name"]
                # Update and add the controller to the controllers dict
                obj["ports"]   = OrderedDict()
                obj["index"]   = i
                controllers[last_controller] = obj
                # We cannot nest controllers, only hubs (apparently) - so we start our
                # cont_list over with the current controller
                cont_list = [last_controller]
                last_port = None # Reset this as well to prevent cross-controller mistakes
                # Let's try to scrape other info about the controller here
                if not last_pci or last_pci[1]+1 >= len(self.ioreg):
                    continue # wut... missing the PCI parent, or out of range somehow
                # Set some info based on the PCI parent
                obj["parent"] = last_pci[0].strip().split("  <class")[0]
                obj["parent_name"],temp_addr = obj["parent"].split("@")
                obj["parent_index"] = last_pci[1]
                try:
                    major,minor = temp_addr.split(",") if "," in temp_addr else temp_addr,"0"
                    acpi_addr = "0x{}{}".format(major.rjust(4,"0"),minor.rjust(4,"0"))
                    obj["acpi_address"] = "Zero" if acpi_addr == "0x00000000" else acpi_addr
                except: pass
                for line in self.ioreg[last_pci[1]+1:]:
                    if line.replace("|","").strip() == "}":
                        break # We hit the end of that PCI device
                    elif '"acpi-path"' in line:
                        try: obj["acpi_path"] = line.split('"')[-2]
                        except: pass
                    elif '"pcidebug"' in line:
                        try: obj["pci_debug"] = line.split('"')[-2]
                        except: pass
                    if obj.get("acpi_path") and obj.get("pci_debug"):
                        break # Got what we needed, no need to keep searching
            elif not cont_list:
                # We don't have any top level controllers, and the current line wasn't one - skip it
                continue
            # Check if we're mapping hubs, matched the hub regex, and the root controller is EHCI
            elif self.map_hubs and self.usb_hub.search(line) and "EHCI" in controllers[cont_list[0]]["type"]:
                # Gather our hub info and push it to the cont_list
                last_controller = "HUB-{}".format(obj["address"])
                # Update and add the hub to the controllers dict
                obj["ports"]       = OrderedDict()
                obj["index"]       = i
                obj["is_hub"]      = True
                obj["locationid"]  = self.hex_dec(obj["address"])
                obj["parent"]      = last_controller
                obj["parent_name"] = controllers[cont_list[0]]["name"]
                obj["nest_level"]  = len(cont_list)
                controllers[last_controller] = obj
                # Check if we have a last port - and update that it contains a hub
                if last_port: last_port["contains_hub"] = True
                # Update controller pathing
                cont_list.append(last_controller)
            elif any((x.search(line) for x in port_map)):
                # We got a port - make sure that if it's an XHCI hub port we don't map it
                if self.usb_hubp.search(line) and not "EHCI" in controllers[cont_list[0]]["type"]:
                    continue
                if i+1 >= len(self.ioreg):
                    continue # wut... out of range somehow
                # Let's walk the ioreg list and gather info about the port specifically
                for line in self.ioreg[i+1:]:
                    if line.replace("|","").strip() == "}":
                        break # We hit the end of that port
                    elif '"port" = ' in line:
                        obj["port"] = line.split("<")[1].split(">")[0]
                    elif '"UsbConnector" = ' in line:
                        try: obj["connector"] = int(line.split(" = ")[1].strip())
                        except: obj["connector"] = -1 # Unknown
                    elif '"comment" = "' in line.lower():
                        try: obj["ioreg_comment"] = line.split('"')[-2]
                        except: pass
                    if all((obj.get(x) for x in ("port","connector","ioreg_comment"))):
                        break # Got what we needed, no need to keep searching
                # Save what we found
                controllers[cont_list[-1]]["ports"][obj["port"]] = obj
                last_port = obj # Retain this so we can note if it contains a hub
        # Let's get the IOService path for each controller
        for controller in controllers:
            if controllers[controller].get("is_hub"):
                continue # Skip hubs
            path = self.get_ioservice_path(controllers[controller]["line"])
            if not path:
                continue
            controllers[controller]["ioservice_path"] = path
        return controllers

    def build_kext(self,modern=True,legacy=False,dummy=False,padded_to=0,skip_disabled=False,force_matching=None):
        if not modern and not legacy: return # wut - shouldn't happen
        self.u.resize(80, 24)
        empty_controllers = []
        skip_empty = True
        if padded_to <= 0: # Only check if we're not padding
            for x in self.merged_list:
                ports = self.merged_list[x]["ports"]
                if all((ports[y].get("enabled",False) == False for y in ports)):
                    empty_controllers.append(x)
            if len(empty_controllers):
                if all((x in empty_controllers for x in self.merged_list)):
                    # No ports selected at all... silly people
                    self.u.head("No Ports Selected")
                    print("")
                    print("There are no ports enabled!")
                    print("Please enable at least one port and try again.")
                    print("")
                    self.u.grab("Press [enter] to return to the menu...")
                    return
                while True:
                    self.u.head("Controller Validation")
                    print("")
                    print("Found empty controllers!")
                    print("The following controllers have no enabled ports:\n")
                    for x in empty_controllers:
                        print(" - {}".format(x))
                    print("")
                    e = self.u.grab("Choose whether to (i)gnore or (d)isable them: ")
                    if not len(e): continue
                    if e.lower() in ("i","ignore","d","disable"):
                        skip_empty = e.lower() in ("i","ignore")
                        break
        # Build the kext
        title = []
        if modern: title.append(os.path.basename(self.dummy_kext_path if dummy else self.kext_path))
        if legacy: title.append(os.path.basename(self.dummy_legacy_kext_path if dummy else self.legacy_kext_path))
        self.u.head("Build {}".format(" and ".join(title)))
        print("")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        print("Generating Info.plist{}...".format("" if len(title)==1 else "s"))
        reveal = None
        if modern:
            reveal = self.dummy_kext_path if dummy else self.kext_path
            self.check_and_build(
                reveal,
                self.dummy_info_path if dummy else self.info_path,
                skip_empty=skip_empty,
                legacy=False,
                skip_disabled=skip_disabled,
                padded_to=padded_to,
                force_matching=force_matching
            )
        if legacy:
            if not reveal:
                reveal = self.dummy_legacy_kext_path if dummy else self.legacy_kext_path
            self.check_and_build(
                self.dummy_legacy_kext_path if dummy else self.legacy_kext_path,
                self.dummy_legacy_info_path if dummy else self.legacy_info_path,
                skip_empty=skip_empty,
                legacy=True,
                skip_disabled=skip_disabled,
                padded_to=padded_to,
                force_matching=force_matching
            )
        print("Done.")
        print("")
        if reveal:
            self.re.reveal(reveal,True)
        self.u.grab("Press [enter] to return to the menu...")

    def check_and_build(self,kext_path,info_path,skip_empty=True,legacy=False,skip_disabled=False,padded_to=0,force_matching=None):
        info_plist = self.build_info_plist(skip_empty=skip_empty,legacy=legacy,skip_disabled=skip_disabled,padded_to=padded_to,force_matching=force_matching)
        if os.path.exists(kext_path):
            print("Located existing {} - removing...".format(os.path.basename(kext_path)))
            shutil.rmtree(kext_path,ignore_errors=True)
        print("Creating bundle structure...")
        os.makedirs(os.path.join(kext_path,"Contents"))
        print("Writing Info.plist...")
        with open(info_path,"wb") as f:
            plist.dump(info_plist,f,sort_keys=False)

    def build_info_plist(self,skip_empty=True,legacy=False,skip_disabled=False,padded_to=0,force_matching=None):
        output_plist = {
            "CFBundleDevelopmentRegion": "English",
            "CFBundleGetInfoString": "v1.0",
            "CFBundleIdentifier": "com.corpnewt.USBMap",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "USBMap",
            "CFBundlePackageType": "KEXT",
            "CFBundleShortVersionString": "1.0",
            "CFBundleSignature": "????",
            "CFBundleVersion": "1.0",
            "IOKitPersonalities": {}, # Consider IOKitPersonalities_x86_64 on 10.15+
            "OSBundleRequired": "Root"
        }
        for x in self.merged_list:
            if padded_to > 0: # Generate fake ports for a guessed-injector
                padded_to = 30 if padded_to > 30 else padded_to
                ports = {}
                original_ports = self.merged_list[x]["ports"]
                for a in range(padded_to):
                    addr = self.hex_swap(hex(a+1)[2:].rjust(8,"0"))
                    ports[addr] = {"type":"Unknown","port":addr,"enabled":True}
                    if original_ports.get(addr,{}).get("contains_hub"):
                        ports[addr]["contains_hub"] = True
            else:
                ports = self.merged_list[x]["ports"]
            if all((ports[y].get("enabled",False) == False for y in ports)) and skip_empty:
                # Got an empty controller, bail
                continue
            top_port = hs_port = ss_port = uk_port = 0
            top_data = self.hex_to_data("00000000")
            new_entry = {
                "CFBundleIdentifier": "com.apple.driver.AppleUSBMergeNub" if legacy else "com.apple.driver.AppleUSBHostMergeProperties",
                "IOClass": "AppleUSBMergeNub" if legacy else "AppleUSBHostMergeProperties", # Consider AppleUSBHostMergeProperties on 10.15+
                "IONameMatch": self.merged_list[x].get("parent_name"),
                "IOPathMatch": self.merged_list[x].get("ioservice_path"),
                "IOParentMatch": {
                    "IOPropertyMatch": {
                        "pcidebug": self.merged_list[x].get("pci_debug")
                    }
                },
                # Pull the provider directly from the detected class
                "IOProviderClass": self.merged_list[x]["type"],
                "IOProviderMergeProperties": {
                    "kUSBMuxEnabled": False,
                    "port-count": 0,
                    "ports": OrderedDict()
                },
                "model": self.smbios
            }
            pop_keys = ("IONameMatch","locationID","IOPathMatch","IOParentMatch")
            save_key = "IONameMatch"
            if "locationid" in self.merged_list[x]:
                # We have a hub - save the loc id and up the IOProbeScore
                new_entry["locationID"] = self.merged_list[x]["locationid"]
                new_entry["IOProviderClass"] = "AppleUSB20InternalHub"
                new_entry["IOProbeScore"] = 5000
                save_key = "locationID"
            elif force_matching and force_matching in pop_keys:
                # Override any other detection
                save_key = force_matching
            elif "pci_debug" in self.merged_list[x]:
                # Better matching than IONameMatch and IOPathMatch
                save_key = "IOParentMatch"
            elif "ioservice_path" in self.merged_list[x]:
                # We have a more elegant way to match than the ham-fisted IONameMatch
                save_key = "IOPathMatch"
            # Pop any keys we won't use
            for key in pop_keys:
                if key == save_key: continue
                new_entry.pop(key,None)
            if "XHCI" in self.merged_list[x]["type"]:
                # Only add the kUSBMuxEnabled property to XHCI controllers
                new_entry["IOProviderMergeProperties"]["kUSBMuxEnabled"] = True
            for port_num in sorted(ports):
                port = ports[port_num]
                # Increment values
                if port["type"] == "Unknown":
                    # Unknown port - we're padding
                    uk_port += 1
                    port_name = self.get_numbered_name("UK00",uk_port,False)
                elif "USB3" in port["type"]:
                    # All USB 3+ ports are SSxx
                    ss_port += 1
                    port_name = self.get_numbered_name("SS00",ss_port,False)
                else:
                    # USB 2 personalties of XHCI are HSxx, otherwise PRTx
                    hs_port += 1
                    port_name = self.get_numbered_name("HS00" if "XHCI" in self.merged_list[x]["type"] else "PRT0",hs_port,False)
                # Make sure the port is enabled
                if not port.get("enabled",False) and skip_disabled: continue # Disabled, skip it
                # Check port number
                port_number = self.hex_dec(self.hex_swap(port["port"]))
                if port.get("enabled") and port_number > top_port:
                    top_port = port_number
                    top_data = self.hex_to_data(port["port"])
                # Check port type prioritizing overrides if found
                usb_connector = port.get("type_override",255 if port.get("contains_hub") else port.get("connector",-1))
                if usb_connector == -1: usb_connector = 3 if "XHCI" in self.merged_list[x]["type"] else 0
                # Add the port with the connector type and port number
                new_entry["IOProviderMergeProperties"]["ports"][port_name] = {
                    "UsbConnector": usb_connector,
                    "port" if port.get("enabled") else "#port": self.hex_to_data(port["port"])
                }
                # Retain any comments
                if "comment" in port:
                    new_entry["IOProviderMergeProperties"]["ports"][port_name]["Comment"] = port["comment"]
            new_entry["IOProviderMergeProperties"]["port-count"] = top_data # Keep track of the highest port number used
            # Ensure we have a unique entry name
            entry_name = self.smbios+"-"+x.split("@")[0]
            entry_num = 0
            while True:
                test_name = entry_name
                if entry_num > 0: test_name += "-{}".format(entry_num)
                if not test_name in output_plist["IOKitPersonalities"]:
                    entry_name = test_name
                    break
                entry_num += 1
            output_plist["IOKitPersonalities"][entry_name]= new_entry
        return output_plist

    # Helper methods
    def check_hex(self, value):
        # Remove 0x
        return re.sub(r'[^0-9A-Fa-f]+', '', value.lower().replace("0x", ""))

    def hex_to_data(self, value):
        return plist.wrap_data(binascii.unhexlify(self.check_hex(value).encode("utf-8")))

    def hex_swap(self, value):
        input_hex = self.check_hex(value)
        if not len(input_hex): return None
        # Normalize hex into pairs
        input_hex = list("0"*(len(input_hex)%2)+input_hex)
        hex_pairs = [input_hex[i:i + 2] for i in range(0, len(input_hex), 2)]
        hex_rev = hex_pairs[::-1]
        hex_str = "".join(["".join(x) for x in hex_rev])
        return hex_str.upper()

    def hex_dec(self, value):
        value = self.check_hex(value)
        try: dec = int(value, 16)
        except: return None
        return dec

    def port_to_num(self, value, pad_to=2):
        value = self.check_hex(value)
        try: return str(int(self.hex_swap(value),16)).rjust(pad_to)
        except: pass
        return "-1".rjust(pad_to)

    def discover_ports(self):
        # Iterates every 5 seconds showing any newly populated ports
        self.check_controllers()
        self.merged_list = self.merge_controllers()
        total_ports = OrderedDict()
        last_ports  = OrderedDict()
        last_list   = []
        while True:
            extras = index = 0
            last_w = 80
            self.check_by_ioreg(force=True)
            self.u.head("Discover USB Ports")
            print("")
            check_ports = self.get_ports_and_devices()
            # Walk them and check for differences
            new_last_list = []
            for i,x in enumerate(check_ports):
                if len(check_ports[x]) > len(total_ports.get(x,[])): # Only append to keep track of all the items plugged in
                    total_ports[x] = [y for y in check_ports[x]]
                if last_ports and len(check_ports[x]) > len(last_ports.get(x,[])):
                    new_last_list.append((i+1,x))
            if new_last_list: last_list = [x for x in new_last_list] # Migrate the list over as needed
            # Snapshot the last seen ports to last_ports
            for x in check_ports:
                last_ports[x] = [y for y in check_ports[x]]
            # Enumerate the ports
            last_cont = None
            cont_count = {}
            show_red_warning = False
            pad = 11
            for index,port in enumerate(check_ports):
                n,t,p,a,e,c,r = port.split(" | ")
                if len(total_ports.get(port,[])): cont_count[c] = cont_count.get(c,0)+1
                if last_cont != c:
                    print("    ----- {}{} Controller{} -----".format(self.cs,r,self.ce))
                    last_cont = c
                    extras += 1
                line = "{}. {} | {} | {} ({}) | {} | Type {}".format(str(index+1).rjust(2),n,t,self.port_to_num(p),p,a,e)
                if len(line) > last_w: last_w = len(line)
                print("{}{}{}".format(
                        self.cs if any((port==x[1] for x in last_list)) else self.bs if len(total_ports.get(port,[])) else "",
                        line,
                        self.ce if len(total_ports.get(port,[])) else ""
                    ))
                # Initialize the last controller seen
                if last_cont == None: last_cont = c
                original = self.controllers[c]["ports"][p]
                merged_c = self.get_matching_controller(c,self.controllers,self.merged_list) # Try to get the merged version for comments, if possible
                if not merged_c: merged_c = c # Ensure we have a controller if there wasn't a matching one
                # Ensure we have self.merged_list[merged_c]["ports"][p] == {} at least
                last_step = self.merged_list
                for step in (merged_c,"ports",p):
                    if not step in last_step: last_step[step] = {}
                    last_step = last_step[step]
                merged_p = self.merged_list[merged_c]["ports"][p]
                # Save the items if there were any
                if len(total_ports.get(port,[])):
                    new_items = original.get("items",[])
                    new_items.extend([x for x in total_ports[port] if not x in original.get("items",[])])
                    original["items"] = new_items
                    original["enabled"] = True
                if merged_p.get("comment"):
                    extras += 1
                    print("    {}{}{}".format(self.nm, merged_p["comment"], self.ce))
                if merged_p.get("ioreg_comment") and merged_p["ioreg_comment"] != merged_p.get("comment"):
                    extras += 1
                    print("    {}{}{} (from ioreg)".format(self.nm, merged_p["ioreg_comment"], self.ce))
                if len(check_ports[port]):
                    extras += len(check_ports[port])
                    print("\n".join(check_ports[port]))
                    if any((self.rs in red_check for red_check in check_ports[port])):
                        show_red_warning = True
            print("")
            if show_red_warning:
                pad = 13
                print("- Items in {}RED{} do not have accurate addressing\n".format(self.rs,self.ce))
            # List the controllers and their port counts
            print("Populated:")
            pop_list = []
            for cont in self.controllers:
                try: parent = self.controllers[cont]["parent"]
                except: parent = cont # Fall back on the original name
                count = cont_count.get(cont,0)
                pop_list.append("{}{}: {:,}{}".format(
                    self.cs if 0 < count < 16 else self.rs,
                    parent.split("@")[0],
                    count,
                    self.ce
                ))
            print(", ".join(pop_list))
            temp_h = index+1+extras+pad+(1 if last_list else 0)
            h = temp_h if temp_h > 24 else 24
            self.u.resize(last_w, h)
            print("Press Q then [enter] to stop")
            if last_list:
                print("Press N then [enter] to nickname port{} {}".format(
                    "" if len(last_list)==1 else "s",
                    ", ".join([str(x[0]) for x in last_list])
                ))
            print("")
            out = self.u.grab("Waiting {:,} second{}:  ".format(self.discover_wait,"" if self.discover_wait == 1 else "s"), timeout=self.discover_wait)
            if not out or not len(out):
                continue
            if out.lower() == "q":
                break
            if out.lower() == "n" and last_list:
                # Let's set a nickname for this port
                self.get_name(last_list)
        self.merged_list = self.merge_controllers()
        self.save_plist()

    def get_name(self, port_list):
        # Helper method to add a custom name ("comment") to the passed ports
        # Gather the originals first
        originals = []
        name_list = []
        pad = 11
        # Iterate the ports
        for index,port in port_list:
            n,t,p,a,e,c,r = port.split(" | ")
            merged_c = self.get_matching_controller(c,self.controllers,self.merged_list) # Try to get the merged version for comments, if possible
            if merged_c: c = merged_c # Ensure we have a controller if there wasn't a matching one
            assert c in self.merged_list # Verify the controller is there
            assert p in self.merged_list[c]["ports"] # Verify the port is also there
            # Locate the original
            original = self.merged_list[c]["ports"][p]
            originals.append(original)
            nickname = original.get("comment",None)
            # Format and color the entry
            name_list.append("{}{}. {}{} = {}:\n{}".format(
                self.cs,
                index,
                n,
                self.ce,
                self.nm+nickname+self.ce if nickname else "None",
                "\n".join(original.get("items",[]))
            ))
        name_text = "\n".join(name_list)
        # Get the target window height
        temp_h = len(name_text.split("\n"))+pad
        h = temp_h if temp_h > 24 else 24
        self.u.resize(80, h)
        while True:
            # Display all the ports we intend to rename
            self.u.head("Port Nickname")
            print("")
            print("Current Port Numbers, Names, Nicknames and Devices:\n")
            print(name_text)
            print("")
            print("C. Clear Custom Names")
            print("Q. Return to Discovery")
            print("")
            menu = self.u.grab("Please type a nickname for port{} {}:  ".format(
                "" if len(port_list)==1 else "s",
                ", ".join([str(x[0]) for x in port_list])
            ))
            if not len(menu):
                continue
            if menu.lower() in ("c","none"):
                for original in originals:
                    original.pop("comment",None)
                return
            elif menu.lower() == "q":
                return
            for original in originals:
                original["comment"] = menu
            return

    def print_types(self):
        self.u.resize(80, 24)
        self.u.head("USB Types")
        print("")
        types = "\n".join([
            "0: Type A connector",
            "1: Mini-AB connector",
            "2: ExpressCard",
            "3: USB 3 Standard-A connector",
            "4: USB 3 Standard-B connector",
            "5: USB 3 Micro-B connector",
            "6: USB 3 Micro-AB connector",
            "7: USB 3 Power-B connector",
            "8: Type C connector - USB2-only",
            "9: Type C connector - USB2 and SS with Switch",
            "10: Type C connector - USB2 and SS without Switch",
            "11 - 254: Reserved",
            "255: Proprietary connector"
        ])
        print(types)
        print("")
        print("Per the ACPI 6.2 Spec.")
        print("")
        self.u.grab("Press [enter] to return to the menu...")
        return

    def edit_plist(self):
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        pad = 29
        path_match = False
        while True:
            self.u.resize(80, 24) # Resize smaller to force proper positioning
            self.save_plist()
            ports = [] # An empty list for index purposees
            extras = 0
            last_w = 80
            self.u.head("Edit USB Ports")
            print("")
            if not self.merged_list:
                print("No ports have been discovered yet!".format(self.usb_list))
                print("Use the discovery mode from main menu first.")
                print("")
                return self.u.grab("Press [enter] to return to the menu...")
            custom_name = ioreg_name = False
            index = 0
            counts = OrderedDict()
            for cont in self.merged_list:
                print("    ----- {}{} Controller{} -----".format(self.cs,self.merged_list[cont]["parent"],self.ce))
                extras += 1
                counts[cont] = 0
                for port_num in sorted(self.merged_list[cont]["ports"]):
                    index += 1
                    port = self.merged_list[cont]["ports"][port_num]
                    ports.append(port)
                    if port.get("enabled",False): counts[cont] += 1 # Increment the port counter for the selected controller
                    usb_connector = port.get("type_override",255 if port.get("contains_hub") else port.get("connector",-1))
                    if usb_connector == -1: usb_connector = 3 if "XHCI" in self.merged_list[cont]["type"] else 0
                    line = "[{}] {}. {} | {} | {} ({}) | {} | Type {}".format(
                        "#" if port.get("enabled",False) else " ",
                        str(index).rjust(2),
                        port["name"],
                        port["type"],
                        self.port_to_num(port["port"]),
                        port["port"],
                        port["address"],
                        usb_connector,
                    )
                    if len(line) > last_w: last_w = len(line)
                    print("{}{}{}".format(
                        self.bs if port.get("enabled",False) else "",
                        line,
                        self.ce if port.get("enabled",False) else ""
                    ))
                    if port.get("comment",None):
                        extras += 1
                        print("    {}{}{}".format(self.nm, port["comment"], self.ce))
                    if port.get("ioreg_comment") and port["ioreg_comment"] != port.get("comment"):
                        ioreg_name = True
                        extras += 1
                        print("    {}{}{} (from ioreg)".format(self.nm, port["ioreg_comment"], self.ce))
                    if len(port.get("items",[])):
                        extras += len(port["items"])
                        print("\n".join(port["items"]))
            print("")
            # List the controllers and their port counts
            print("Populated:")
            pop_list = []
            for cont in counts:
                try: parent = self.merged_list[cont]["parent"]
                except: parent = cont # Fall back on the original name
                pop_list.append("{}{}: {:,}{}".format(
                    self.cs if 0 < counts[cont] < 16 else self.rs,
                    parent.split("@")[0],
                    counts[cont],
                    self.ce
                ))
            print(", ".join(pop_list))
            print("")
            print("K. Build USBMap.kext (Catalina And Newer)")
            print("   - AppleUSBHostMergeProperties, MinKernel=19.0.0")
            print("L. Build USBMapLegacy.kext (Mojave And Older)")
            print("   - AppleUSBMergeNub, MaxKernel=18.9.9")
            print("B. Build Both USBMap.kext and USBMapLegacy.kext")
            print("A. Select All")
            print("N. Select None")
            print("P. Enable All Populated Ports")
            print("D. Disable All Empty Ports")
            print("C. Clear Detected Items")
            print("T. Show Types")
            if path_match:
                print("H. Use IOParentMatch (Currently IOPathMatch)")
            else:
                print("H. Use IOPathMatch (Currently IOParentMatch)")
            if ioreg_name:
                extras += 1
                print("I. Use All IOReg Custom Names")
            print("")
            print("M. Main Menu")
            print("Q. Quit")
            print("")
            print("- Select ports to toggle with comma-delimited lists (eg. 1,2,3,4,5)")
            print("- Set a range of ports using this formula R:1-15:On/Off")
            print("- Change types using this formula T:1,2,3,4,5:t where t is the type")
            print("- Set custom names using this formula C:1,2:Name - Name = None to clear")
            temp_h = index+1+extras+pad
            h = temp_h if temp_h > 24 else 24
            self.u.resize(last_w, h)
            menu = self.u.grab("Please make your selection:  ")
            if not len(menu):
                continue
            elif menu.lower() == "q":
                self.u.resize(80, 24)
                self.u.custom_quit()
            elif menu.lower() == "m":
                return
            elif menu.lower() == "k":
                self.build_kext(modern=True,legacy=False,force_matching="IOPathMatch" if path_match else None)
            elif menu.lower() == "l":
                self.build_kext(modern=False,legacy=True,force_matching="IOPathMatch" if path_match else None)
            elif menu.lower() == "b":
                self.build_kext(modern=True,legacy=True,force_matching="IOPathMatch" if path_match else None)
            elif menu.lower() in ("n","a"):
                # Iterate all ports and deselect them
                for port in ports:
                    port["enabled"] = True if menu.lower() == "a" else False
            elif menu.lower() == "p":
                # Select all populated ports
                for port in ports:
                    if port.get("items",[]): port["enabled"] = True
            elif menu.lower() == "d":
                # Deselect any empty ports
                for port in ports:
                    if not port.get("items",[]): port["enabled"] = False
            elif menu.lower() == "c":
                # Clear items from all ports
                for port in ports: port["items"] = []
            elif menu.lower() == "t":
                self.print_types()
            elif menu.lower() == "h":
                path_match ^= True
            elif menu.lower() == "i" and ioreg_name:
                # Iterate all the ports and set "comment" to "ioreg_comment"
                for cont in self.merged_list:
                    for port_num in sorted(self.merged_list[cont]["ports"]):
                        port = self.merged_list[cont]["ports"][port_num]
                        if port.get("ioreg_comment"):
                            port["comment"] = port["ioreg_comment"]
            elif menu[0].lower() == "r":
                # Should be a range
                try:
                    nums = [int(x) for x in menu.split(":")[1].replace(" ","").split("-")]
                    a,b = nums[0]-1,nums[-1]-1 # Get the first and last - then determine which is larger
                    if b < a: a,b = b,a # Flip them around if need be
                    if not all((0 <= x < len(ports) for x in (a,b))): continue # Out of bounds, skip
                    # Ge the on/off value
                    toggle = menu.split(":")[-1].lower()
                    if not toggle in ("on","off"): continue # Invalid - skip
                    for x in range(a,b+1):
                        ports[x]["enabled"] = toggle == "on"
                except:
                    continue
            # Check if we need to toggle
            elif menu[0].lower() == "t":
                # We should have a type
                try:
                    nums = [int(x) for x in menu.split(":")[1].replace(" ","").split(",")]
                    t = int(menu.split(":")[-1])
                    for x in nums:
                        x -= 1
                        if not 0 <= x < len(ports): continue # Out of bounds, skip
                        # Valid index
                        ports[x]["type_override"] = t
                except:
                    continue
            elif menu[0].lower() == "c":
                # We should have a new name
                try:
                    nums = [x.lower() for x in menu.split(":")[1].replace(" ","").split(",")]
                    if "all" in nums:
                        nums = list(range(len(ports)))
                    else:
                        nums = [int(x) for x in nums]
                    name = menu.split(":")[-1]
                    for x in nums:
                        x -= 1
                        if not 0 <= x < len(ports): continue # Out of bounds, skip
                        # Valid index
                        if name.lower() == "none": ports[x].pop("comment",None)
                        else: ports[x]["comment"] = name
                except:
                    continue
            else:
                # Maybe a list of numbers?
                try:
                    nums = [int(x) for x in menu.replace(" ","").split(",")]
                    for x in nums:
                        x -= 1
                        if not 0 <= x < len(ports): continue # Out of bounds, skip
                        ports[x]["enabled"] = not ports[x].get("enabled",False)
                except:
                    continue

    def get_safe_acpi_path(self, path):
        return None if path == None else ".".join([x.split("@")[0] for x in path.split("/") if len(x) and not ":" in x])

    def get_numbered_name(self, base_name, number, use_hex=True):
        if use_hex: number = hex(number).replace("0x","").upper()
        else: number = str(number)
        return base_name[:-1*len(number)]+number

    def generate_renames(self, cont_list):
        used_names = [x for x in self.illegal_names]
        used_names.extend([self.connected_controllers[x]["parent_name"].upper() for x in self.connected_controllers if self.connected_controllers[x].get("parent_name",None)])
        self.u.head("Rename Conflicting Controllers")
        print("")
        oc_patches = {"ACPI":{"Patch":[]}}
        clover_patches = {"ACPI":{"DSDT":{"Patches":[]}}}
        zero = plist.wrap_data(binascii.unhexlify("00000000"))
        for cont in cont_list:
            con_type = "XHCI"
            print("Checking {}...".format(cont))
            c_type = self.connected_controllers[cont]["type"]
            if "XHCI" in c_type:
                print(" - XHCI device")
            elif "EHCI" in c_type:
                print(" - EHCI device")
                con_type = "EH01"
            else: print(" - Unknown type - using XHCI")
            print(" - Gathering unique name...")
            # Now we have the base - let's increment!
            starting_number = 1 if con_type == "EH01" else 2
            while True:
                name = self.get_numbered_name(con_type,starting_number)
                if not name in used_names:
                    used_names.append(name)
                    break
                starting_number += 1
            # We should have a unique name here, add the info
            print(" --> Got {}".format(name))
            cname = cont.split("@")[0].ljust(4,"_")
            find = plist.wrap_data(cname.encode("utf-8"))
            repl = plist.wrap_data(name.encode("utf-8"))
            comm = "Rename {} to {}".format(cname,name)
            c_patch = {
                "Comment":comm,
                "Disabled":False,
                "Find":find,
                "Replace":repl
            }
            oc_patch = {
                "Base":"",
                "BaseSkip":0,
                "Comment":comm,
                "Count":0,
                "Enabled":True,
                "Find":find,
                "Limit":0,
                "Mask":plist.wrap_data(b""),
                "OemTableId": zero,
                "Replace":repl,
                "ReplaceMask":plist.wrap_data(b""),
                "Skip":0,
                "TableLength":0,
                "TableSignature":zero
            }
            clover_patches["ACPI"]["DSDT"]["Patches"].append(c_patch)
            oc_patches["ACPI"]["Patch"].append(oc_patch)
        print("Saving patches_OC.plist...")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if not os.path.exists(self.output): os.mkdir(self.output)
        with open(self.oc_patches,"wb") as f:
            plist.dump(oc_patches,f)
        print("Saving patches_Clover.plist...")
        with open(self.clover_patches,"wb") as f:
            plist.dump(clover_patches,f)
        self.re.reveal(self.oc_patches,True)
        print("")
        print("Done.")
        print("")
        self.u.grab("Press [enter] to return to the menu...")

    def generate_acpi_renames(self, cont_list):
        used_names = [x for x in self.illegal_names]
        used_names.extend([self.connected_controllers[x]["parent_name"].upper() for x in self.connected_controllers if self.connected_controllers[x].get("parent_name",None)])
        self.u.head("Rename Devices")
        print("")
        ssdt = """//
// SSDT to rename PXSX, XHC1, EHC1, EHC2, and other conflicting device names
//
DefinitionBlock ("", "SSDT", 2, "CORP", "UsbReset", 0x00001000)
{
    /*
     * Start copying here if you're adding this info to an SSDT-USB-Reset!
     */

"""
        parents = []
        devices = []
        for cont in cont_list:
            con_type = "XHCI"
            print("Checking {}...".format(cont))
            c_type = self.connected_controllers[cont]["type"]
            acpi_path = self.get_safe_acpi_path(self.connected_controllers[cont]["acpi_path"])
            if not acpi_path:
                print(" - ACPI path not found - skipping.")
                continue
            acpi_parent = ".".join(acpi_path.split(".")[:-1])
            acpi_addr = self.connected_controllers[cont]["acpi_address"]
            if "XHCI" in c_type:
                print(" - XHCI device")
            elif "EHCI" in c_type:
                print(" - EHCI device")
                con_type = "EH01"
            else: print(" - Unknown type - using XHCI")
            print(" - ACPI Path: {}".format(acpi_path))
            print(" --> ACPI Parent Path: {}".format(acpi_parent))
            print(" - ACPI _ADR: {}".format(acpi_addr))
            print(" - Gathering unique name...")
            # Now we have the base - let's increment!
            starting_number = 1 if con_type == "EH01" else 2
            while True:
                name = self.get_numbered_name(con_type,starting_number)
                if not name in used_names:
                    used_names.append(name)
                    break
                starting_number += 1
            # We should have a unique name here, add the info
            print(" --> Got {}".format(name))
            parents.append(acpi_parent)
            devices.append((acpi_path,name,acpi_addr,acpi_parent))
        if not len(devices):
            print("No valid devices - nothing to build.")
            print("")
            return self.u.grab("Press [enter] to return to the menu...")
        print("Building SSDT-USB-Reset.dsl...")
        # Add the parents as needed
        for parent in sorted(list(set(parents))):
            ssdt += "    External ({}, DeviceObj)\n".format(parent)
        if len(parents): ssdt+="\n" # Add a newline after the parents for formatting
        for device in devices:
            # Get the info and build the SSDT
            acpi_path, name, acpi_addr, acpi_parent = device
            ssdt += "    External ({}, DeviceObj)\n".format(acpi_path)
            ssdt += """
    Scope([[device]])
    {
        Method (_STA, 0, NotSerialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }
            Else
            {
                Return (0x0F)
            }
        }
    }

    Scope([[parent]])
    {
        Device ([[new_device]])
        {
            Name (_ADR, [[address]])  // _ADR: Address
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If (_OSI ("Darwin"))
                {
                    Return (0x0F)
                }
                Else
                {
                    Return (Zero)
                }
            }
        }
    }

""".replace("[[device]]",acpi_path).replace("[[parent]]",acpi_parent).replace("[[new_device]]",name).replace("[[address]]",acpi_addr)
        # Add the footer
        ssdt += """    /*
     * End copying here if you're adding this info to an SSDT-USB-Reset!
     */
}"""
        print("Saving to SSDT-USB-Reset.dsl...")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if not os.path.exists(self.output): os.mkdir(self.output)
        with open(self.ssdt_path,"w") as f:
            f.write(ssdt)
        self.re.reveal(self.ssdt_path,True)
        print("")
        print("Done.")
        print("")
        self.u.grab("Press [enter] to return to the menu...")

    def reset_rhubs(self,rhub_paths):
        self.u.head("Reset RHUBs")
        print("")
        ssdt = """//
// SSDT to reset RHUB devices on XHCI controllers to force hardware querying of ports
//
// WARNING: May conflict with existing SSDT-USB-Reset!  Verify names and paths before
//          merging!
//
DefinitionBlock ("", "SSDT", 2, "CORP", "RHBReset", 0x00001000)
{
    /*
     * Start copying here if you're adding this info to an existing SSDT-USB-Reset!
     */

"""
        print("Building SSDT-RHUB-Reset.dsl...")
        for rhub in sorted(list(set(rhub_paths))):
            print("Resetting {}...".format(rhub))
            ssdt += "    External ({}, DeviceObj)\n".format(rhub)
            ssdt += """
    Scope([[device]])
    {
        Method (_STA, 0, NotSerialized)  // _STA: Status
        {
            If (_OSI ("Darwin"))
            {
                Return (Zero)
            }
            Else
            {
                Return (0x0F)
            }
        }
    }

""".replace("[[device]]",rhub)
        # Add the footer
        ssdt += """    /*
     * End copying here if you're adding this info to an SSDT-USB-Reset!
     */
}"""
        print("Saving to SSDT-RHUB-Reset.dsl...")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if not os.path.exists(self.output): os.mkdir(self.output)
        with open(self.rsdt_path,"w") as f:
            f.write(ssdt)
        self.re.reveal(self.rsdt_path,True)
        print("")
        print("Done.")
        print("")
        self.u.grab("Press [enter] to return to the menu...")

    def main(self):
        self.u.resize(80, 24)
        self.u.head("USBMap")
        print("")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        print("Current Controllers:")
        print("")
        needs_rename = []
        rhub_paths   = []
        c_check      = [x for x in self.connected_controllers if not self.connected_controllers[x].get("is_hub",False)]
        if not len(c_check): print(" - {}None{}".format(self.rs,self.ce))
        else:
            # We have controllers - let's show them
            pad = max(len(self.connected_controllers[x]["parent"]) for x in c_check)
            names = [self.connected_controllers[x]["parent_name"] for x in c_check]
            for x in c_check:
                if "locationid" in self.connected_controllers[x]: continue # don't show hubs in this list
                acpi = self.get_safe_acpi_path(self.connected_controllers[x].get("acpi_path",None))
                name = self.connected_controllers[x]["parent_name"]
                par  = self.connected_controllers[x]["parent"]
                if name in self.illegal_names:
                    needs_rename.append(x)
                    self.controllers.pop(x,None) # Remove it from the controllers to map
                    print(" - {}{}{} @ {} ({}{}{})".format(self.rs,par.rjust(pad),self.ce,acpi if acpi else "Unknown ACPI Path",self.rs,"Needs Rename" if name in self.illegal_names else "Not Unique",self.ce))
                    continue
                print(" - {}{}{} @ {}".format(self.cs,par.rjust(pad),self.ce,acpi if acpi else "Unknown ACPI Path"))
                if not "XHCI" in self.connected_controllers[x]["type"]:
                    continue # Only check legally named XHCI controllers for RHUB paths
                # Get the RHUB name - mirrors the controller name if actually "RHUB"
                if acpi:
                    rhub_name = "RHUB" if x.split("@")[0].upper() == self.connected_controllers[x]["parent_name"] else x.split("@")[0].upper()
                    rhub_path = ".".join([acpi,rhub_name])
                    rhub_paths.append(rhub_path)
                    print("  \\-> {}RHUB{} @ {}".format(self.bs,self.ce,rhub_path))
        print("")
        print("{}D. Discover Ports{}{}".format(
            self.rs if needs_rename else "",
            " (Will Ignore Invalid Controllers)" if needs_rename else "",
            self.ce
        ))
        print("{}P. Edit & Create USBMap.kext{}{}".format(
            "" if self.merged_list else self.rs,
            "" if self.merged_list else " (Must Discover Ports First)",
            self.ce
        ))
        print("{}K. Create USBMapDummy.kext{}{}".format(
            "" if self.merged_list else self.rs,
            "" if self.merged_list else " (Must Discover Ports First)",
            self.ce
        ))
        print("R. Reset All Detected Ports")
        if os.path.exists(self.usb_list):
            print("B. Backup Detected Port Plist")
        if needs_rename:
            print("A. Generate ACPI Renames For Conflicting Controllers")
            print("L. Generate Plist Renames For Conflicting Controllers")
        if rhub_paths:
            print("H. Generate ACPI To Reset RHUBs ({}May Conflict With Existing SSDT-USB-Reset.aml!{})".format(self.rs,self.ce))
        print("")
        print("Q. Quit")
        print("")
        menu = self.u.grab("Please select an option:  ")
        if not len(menu):
            return
        if menu.lower() == "q":
            self.u.resize(80, 24)
            self.u.custom_quit()
        if menu.lower() == "k" and self.merged_list:
            self.build_kext(modern=True,legacy=True,dummy=True,padded_to=26)
        elif menu.lower() == "r":
            try:
                # Reset the merged_list and repopulate the controllers
                self.merged_list = OrderedDict()
                if os.path.exists(self.usb_list):
                    os.remove(self.usb_list)
            except Exception as e:
                print("Failed to remove USB.plist! {}".format(e))
            return
        elif menu.lower() == "b" and os.path.exists(self.usb_list):
            if not os.path.exists(self.output): os.mkdir(self.output)
            output = os.path.join(self.output,"USB-{}.plist".format(datetime.today().strftime("%Y-%m-%d %H.%M")))
            try: shutil.copyfile(self.usb_list,output)
            except: pass
            if os.path.exists(output): self.re.reveal(output,True)
        elif menu.lower() == "d":
            if not len(self.controllers):
                self.u.head("No Valid Controllers")
                print("")
                print("No valid controllers found for port discovery!")
                print("You may need plist/ACPI renames in order to discover.")
                print("")
                return self.u.grab("Press [enter] to return...")
            self.discover_ports()
        elif menu.lower() == "p" and self.merged_list:
            self.edit_plist()
        elif menu.lower() == "a" and needs_rename:
            self.generate_acpi_renames(needs_rename)
        elif menu.lower() == "l" and needs_rename:
            self.generate_renames(needs_rename)
        elif menu.lower() == "h" and rhub_paths:
            self.reset_rhubs(rhub_paths)

if __name__ == '__main__':
    u = USBMap()
    while True:
        u.main()
