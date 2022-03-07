import os, sys, re, json, binascii, shutil, subprocess
from Scripts import run, utils, ioreg, plist, reveal
from collections import OrderedDict
from datetime import datetime

class USBMap:
    def __init__(self):
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        self.output = "./Results"
        self.w = 80
        self.h = 24
        if os.name == "nt":
            self.w = 120
            self.h = 30
            os.system("color") # Run this once on Windows to enable ansi colors
        self.u = utils.Utils("USBMap Injector Edit")
        self.plist_path = None
        self.plist_data = None
        self.smbios = self.current_smbios()
        self.cs = u"\u001b[32;1m"
        self.ce = u"\u001b[0m"
        self.bs = u"\u001b[36;1m"
        self.rs = u"\u001b[31;1m"
        self.nm = u"\u001b[35;1m"

    # Helper methods
    def check_hex(self, value):
        # Remove 0x
        return re.sub(r'[^0-9A-Fa-f]+', '', value.lower().replace("0x", ""))

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

    def hex_data(self, hex_str):
        hex_str = self.check_hex(hex_str)
        try: return plist.wrap_data(binascii.unhexlify(hex_str.encode("utf-8")))
        except: return None

    def port_to_num(self, value, pad_to=2):
        value = self.check_hex(value)
        try: return str(int(self.hex_swap(value),16)).rjust(pad_to)
        except: pass
        return "-1".rjust(pad_to)

    def print_types(self):
        self.u.resize(self.w, self.h)
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
        return self.u.grab("Press [enter] to return to the menu...")

    def current_smbios(self):
        if not sys.platform.lower() == "darwin": return None
        try: return subprocess.Popen(["system_profiler","SPHardwareDataType"],stdout=subprocess.PIPE).stdout.read().decode("utf-8").split("Model Identifier: ")[1].split("\n")[0].strip()
        except: pass
        return None

    def choose_smbios(self,current=None,allow_return=True,prompt=None):
        self.u.resize(self.w, self.h)
        while True:
            self.u.head("Choose SMBIOS Target")
            print("")
            if current:
                print("Current: {}".format(current))
                print("")
            if prompt: print(prompt+"\n")
            if self.smbios: print("C. Use Current Machine's SMBIOS ({})".format(self.smbios))
            if allow_return: print("M. Return to Menu")
            print("Q. Quit")
            print("")
            menu = self.u.grab("Please type the new target SMBIOS (eg. iMac18,1):  ")
            if not len(menu): continue
            elif menu.lower() == "c" and self.smbios: return self.smbios
            elif menu.lower() == "m" and allow_return: return
            elif menu.lower() == "q": self.u.custom_quit()
            else: return menu

    def save_plist(self):
        # Ensure the lists are the same
        try:
            with open(self.plist_path,"wb") as f:
                plist.dump(self.plist_data,f,sort_keys=False)
            return True
        except Exception as e:
            self.show_error("Error Saving","Could not save to {}! {}".format(os.path.basename(self.plist_path),e))
        return False

    def change_personality_name(self,personality):
        self.u.resize(self.w, self.h)
        while True:
            pad = 4
            print_text = [""]
            print_text.append("Existing Personalities:")
            print_text.append("")
            print_text.extend(["  - {}{}{}{}".format(
                self.bs if x==personality else "",
                x,
                self.ce if x==personality else "",
                " (Currently Editing)" if x == personality else ""
            ) for x in self.plist_data["IOKitPersonalities"]])
            print_text.append("")
            print_text.append("M. Return to Menu")
            print_text.append("Q. Quit")
            print_text.append("")
            w_adj = max((len(x) for x in print_text))
            h_adj = len(print_text) + pad
            self.u.resize(w_adj if w_adj>self.w else self.w, h_adj if h_adj>self.h else self.h)
            self.u.head("Change IOKitPersonality Name")
            print("\n".join(print_text))
            menu = self.u.grab("Please type the new IOKitPersonality name:  ")
            if not len(menu): continue
            elif menu.lower() == "m" or menu == personality: return personality
            elif menu.lower() == "q": self.u.custom_quit()
            elif menu in self.plist_data["IOKitPersonalities"]:
                self.u.resize(self.w, self.h)
                self.u.head("Personality Exists")
                print("")
                print("The following IOKitPersonality already exists:\n\n  - {}".format(menu))
                print("")
                self.u.grab("Press [enter] to return...")
                continue
            # Should have a valid name - let's pop our current value into the new one
            self.plist_data["IOKitPersonalities"][menu] = self.plist_data["IOKitPersonalities"].pop(personality,None)
            return menu

    def edit_ports(self,personality):
        pers = self.plist_data["IOKitPersonalities"][personality]
        if not pers.get("IOProviderMergeProperties",{}).get("ports",{}):
            return self.show_error("No Ports Defined","There are no ports defined for {}!".format(personality))
        ports = pers["IOProviderMergeProperties"]["ports"]
        port_list = list(ports)
        next_class = "AppleUSBHostMergeProperties"
        while True:
            pad = 4
            enabled = 0
            highest = b"\x00\x00\x00\x00"
            print_text = [""]
            for i,x in enumerate(ports,start=1):
                port = ports[x]
                try:
                    addr = binascii.hexlify(plist.extract_data(port.get("port",port.get("#port")))).decode("utf-8")
                except Exception as e:
                    print(str(e))
                    continue
                if "port" in port:
                    enabled += 1
                    if self.hex_dec(self.hex_swap(addr)) > self.hex_dec(self.hex_swap(binascii.hexlify(highest).decode("utf-8"))):
                        highest = plist.extract_data(port["port"])
                line = "[{}] {}. {} | {} ({}) | Type {}".format(
                    "#" if "port" in port else " ",
                    str(i).rjust(2),
                    x,
                    self.port_to_num(addr),
                    addr,
                    port.get("UsbConnector",-1),
                )
                print_text.append("{}{}{}".format(
                    self.bs if "port" in port else "",
                    line,
                    self.ce if "port" in port else ""
                ))
                comment = port.get("Comment",port.get("comment",None))
                if comment:
                    print_text.append("    {}{}{}".format(self.nm,comment,self.ce))
            # Update the highest selected
            pers["IOProviderMergeProperties"]["port-count"] = plist.wrap_data(highest)
            print_text.append("")
            print_text.append("Total Enabled: {}{:,}{}".format(
                self.cs if 0 < enabled < 16 else self.rs,
                enabled,
                self.ce
            ))
            if "model" in pers:
                print_text.append("Target SMBIOS: {}".format(pers["model"]))
            if "IOClass" in pers:
                print_text.append("Target Class:  {}".format(pers["IOClass"]))
            print_text.append("")
            print_text.append("I. Change IOKitPersonality Name")
            if "model" in pers:
                print_text.append("S. Change SMBIOS Target")
            if "IOClass" in pers:
                next_class = "AppleUSBMergeNub" if pers["IOClass"] == "AppleUSBHostMergeProperties" else "AppleUSBHostMergeProperties"
                print_text.append("C. Toggle IOClass to {}".format(next_class))
            print_text.append("")
            print_text.append("A. Select All")
            print_text.append("N. Select None")
            print_text.append("T. Show Types")
            print_text.append("M. IOKitPersonality Menu")
            print_text.append("Q. Quit")
            print_text.append("")
            print_text.append("- Select ports to toggle with comma-delimited lists (eg. 1,2,3,4,5)")
            print_text.append("- Set a range of ports using this formula R:1-15:On/Off")
            print_text.append("- Change types using this formula T:1,2,3,4,5:t where t is the type")
            print_text.append("- Set custom names using this formula C:1,2:Name - Name = None to clear")
            print_text.append("")
            self.save_plist()
            w_adj = max((len(x) for x in print_text))
            h_adj = len(print_text) + pad
            self.u.resize(w_adj if w_adj>self.w else self.w, h_adj if h_adj>self.h else self.h)
            self.u.head("{} Ports".format(personality))
            print("\n".join(print_text))
            menu = self.u.grab("Please make your selection:  ")
            if not len(menu): continue
            elif menu.lower() == "m": return
            elif menu.lower() == "q":
                self.u.resize(self.w, self.h)
                self.u.custom_quit()
            elif menu.lower() == "i":
                personality = self.change_personality_name(personality)
                pers = self.plist_data["IOKitPersonalities"][personality]
            elif menu.lower() == "s" and "model" in pers:
                smbios = self.choose_smbios(pers["model"])
                if smbios: pers["model"] = smbios
            elif menu.lower() == "c" and "IOClass" in pers:
                pers["IOClass"] = next_class
                pers["CFBundleIdentifier"] = "com.apple.driver."+next_class
            elif menu.lower() in ("a","n"):
                find,repl = ("#port","port") if menu.lower() == "a" else ("port","#port")
                for x in ports:
                    if find in ports[x]: ports[x][repl] = ports[x].pop(find)
            elif menu.lower() == "t":
                self.print_types()
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
                    find,repl = ("#port","port") if toggle == "on" else ("port","#port")
                    for x in range(a,b+1):
                        if find in ports[port_list[x]]: ports[port_list[x]][repl] = ports[port_list[x]].pop(find)
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
                        ports[port_list[x]]["UsbConnector"] = t
                except:
                    continue
            elif menu[0].lower() == "c":
                # We should have a new name
                try:
                    nums = [int(x) for x in menu.split(":")[1].replace(" ","").split(",")]
                    name = menu.split(":")[-1]
                    for x in nums:
                        x -= 1
                        if not 0 <= x < len(ports): continue # Out of bounds, skip
                        # Valid index - let's pop any lowercase comments first
                        ports[port_list[x]].pop("comment",None)
                        if name.lower() == "none": ports[port_list[x]].pop("Comment",None)
                        else: ports[port_list[x]]["Comment"] = name
                except:
                    continue
            else:
                # At this point, check for indexes and toggle
                try:
                    nums = [int(x) for x in menu.replace(" ","").split(",")]
                    for x in nums:
                        x -= 1
                        if not 0 <= x < len(ports): continue # Out of bounds, skip
                        find,repl = ("#port","port") if "#port" in ports[port_list[x]] else ("port","#port")
                        ports[port_list[x]][repl] = ports[port_list[x]].pop(find)
                except:
                    continue

    def pick_personality(self):
        if not self.plist_path or not self.plist_data: return
        while True:
            pad = 4
            print_text = [""]
            pers = list(self.plist_data["IOKitPersonalities"])
            for i,x in enumerate(pers,start=1):
                personality = self.plist_data["IOKitPersonalities"][x]
                ports = personality.get("IOProviderMergeProperties",{}).get("ports",{})
                enabled = len([p for p in ports if "port" in ports[p]])
                print_text.append("{}. {} - {}{:,}{}/{:,} enabled".format(
                    str(i).rjust(2),
                    x,
                    self.cs if 0 < enabled < 16 else self.rs,
                    enabled,
                    self.ce,
                    len(ports)
                ))
                if "model" in personality:
                    print_text.append("    {}SMBIOS: {}{}".format(self.bs,personality["model"],self.ce))
                if "IOClass" in personality:
                    print_text.append("    {}Class:  {}{}".format(self.bs,personality["IOClass"],self.ce))
            print_text.append("")
            print_text.append("S. Set All SMBIOS Targets")
            print_text.append("C. Set All Classes to AppleUSBHostMergeProperties")
            print_text.append("L. Set All Classes to AppleUSBMergeNub (Legacy)")
            print_text.append("M. Return To Injector Selection Menu")
            print_text.append("Q. Quit")
            print_text.append("")
            w_adj = max((len(x) for x in print_text))
            h_adj = len(print_text) + pad
            self.u.resize(w_adj if w_adj>self.w else self.w, h_adj if h_adj>self.h else self.h)
            self.u.head("Available IOKitPersonalities")
            print("\n".join(print_text))
            menu = self.u.grab("Please select an IOKitPersonality to edit (1-{:,}):  ".format(len(pers)))
            if not len(menu): continue
            elif menu.lower() == "m": return
            elif menu.lower() == "q":
                self.u.resize(self.w, self.h)
                self.u.custom_quit()
            elif menu.lower() == "s":
                smbios = self.choose_smbios()
                if smbios:
                    for x in pers:
                        self.plist_data["IOKitPersonalities"][x]["model"] = smbios
                self.save_plist()
            elif menu.lower() in ("c","l"):
                next_class = "AppleUSBHostMergeProperties" if menu.lower() == "c" else "AppleUSBMergeNub"
                for x in pers:
                    self.plist_data["IOKitPersonalities"][x]["IOClass"] = next_class
                    self.plist_data["IOKitPersonalities"][x]["CFBundleIdentifier"] = "com.apple.driver."+next_class
                self.save_plist()
            else:
                # Cast as int and ensure we're in range
                try:
                    menu = int(menu)-1
                    assert 0 <= menu < len(pers)
                except:
                    continue
                self.edit_ports(pers[menu])

    def show_error(self,header,error):
        self.u.head(header)
        print("")
        print(str(error))
        print("")
        return self.u.grab("Press [enter] to continue...")

    def parse_usb_txt(self,raw):
        model = self.choose_smbios(current=None,prompt="Please enter the target SMBIOS for this injector.")
        if not model: return
        self.u.head("Parsing USB Info")
        print("")
        print("Got SMBIOS: {}".format(model))
        print("Walking UsbDumpEfi output...")
        try:
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
                "IOKitPersonalities": {},
                "OSBundleRequired": "Root"
            }
            controllers = output_plist["IOKitPersonalities"]
            types = {"0":"OHCI","1":"OHCI","2":"EHCI","3":"XHCI"} # Use OHCI as a placeholder for 0, and 1
            info = raw.split("UsbDumpEfi start")[1]
            last_name = None
            for line in info.split("\n"):
                line = line.strip()
                if not line: continue
                if line.startswith("Found"): # Got a controller
                    addr = ":".join([str(int(x,16)) for x in line.split(" @ ")[-1].replace(".",":").split(":")])
                    t = types.get(line.split("speed ")[1].split(")")[0],"Unknown")
                    last_name = t
                    if last_name in controllers:
                        n = 1
                        while True:
                            temp = "{}-{}".format(last_name,n)
                            if not temp in controllers:
                                last_name = temp
                                break
                            n += 1
                    controllers[last_name] = {
                        "CFBundleItentifier": "com.apple.driver.AppleUSBHostMergeProperties",
                        "IOClass": "AppleUSBHostMergeProperties",
                        "IOParentMatch": {"IOPropertyMatch":{"pcidebug":addr}},
                        "IOProviderClass":"AppleUSB{}PCI".format(t),
                        "IOProviderMergeProperties": {
                            "port-count": self.hex_data(self.hex_swap(hex(int(line.split("(")[1].split(" ports")[0]))[2:].upper().rjust(8,"0"))),
                            "ports": {}
                        },
                        "model": model
                    }
                    if t == "XHCI": controllers[last_name]["IOProviderMergeProperties"]["kUSBMuxEnabled"] = True
                elif line.startswith("Port") and last_name != None:
                    usb_connector = 3 if "XHCI" in controllers[last_name]["IOProviderClass"] else 0
                    num = int(line.split("Port ")[1].split(" status")[0])+1
                    name = "UK{}".format(str(num).rjust(2,"0"))
                    hex_num = self.hex_data(self.hex_swap(hex(num)[2:].upper().rjust(8,"0")))
                    controllers[last_name]["IOProviderMergeProperties"]["ports"][name] = {"UsbConnector":usb_connector,"port":hex_num}
        except Exception as e:
            return self.show_error("Error Parsing".format(os.path.basename(path)),e)
        print("Generating kexts...")
        if not os.path.exists(self.output): os.mkdir(self.output)
        for k,t in (("USBMap.kext","AppleUSBHostMergeProperties"),("USBMapLegacy.kext","AppleUSBMergeNub")):
            print(" - {}".format(k))
            kp = os.path.join(self.output,k)
            if os.path.exists(kp):
                print(" --> Located existing {} - removing...".format(k))
                shutil.rmtree(kp,ignore_errors=True)
            print(" --> Creating bundle structure...")
            os.makedirs(os.path.join(kp,"Contents"))
            print(" --> Setting IOClass types...")
            for c in controllers:
                controllers[c]["CFBundleItentifier"] = "com.apple.driver.{}".format(t)
                controllers[c]["IOClass"] = t
            print(" --> Writing Info.plist...")
            with open(os.path.join(kp,"Contents","Info.plist"),"wb") as f:
                plist.dump(output_plist,f)
            print(" - Saved to: {}".format(kp))
        print("")
        print("Done.")
        print("")
        self.u.grab("Press [enter] to return...")

    def main(self,path=None):
        if path is None:
            self.u.resize(self.w, self.h)
            self.u.head()
            print("")
            print("NOTE:  All changes are done in-place, and happen immediately.")
            print("       Please make sure you keep backups.")
            print("")
            print("Q. Quit")
            print("")
            print("Please drag and drop a USBMap(Legacy).kext, Info.plist,")
            menu = self.u.grab("or UsbDumpEfi.efi output here to continue:  ")
            if not len(menu): return
            if menu.lower() == "q": self.u.custom_quit()
        else:
            menu = path
        # Check the path
        path = self.u.check_path(menu)
        try:
            # Ensure we have a valid path
            if not path: raise Exception("{} does not exist!".format(menu))
            if os.path.isdir(path): path = os.path.join(path,"Contents","Info.plist")
            if not os.path.exists(path): raise Exception("{} does not exist!".format(path))
            if not os.path.isfile(path): raise Exception("{} is a directory!".format(path))
        except Exception as e:
            return self.show_error("Error Selecting Target",e)
        try:
            # Load it and ensure the plist is valid
            with open(path,"rb") as f:
                raw = f.read().replace(b"\x00",b"").decode("utf-8",errors="ignore")
                if "UsbDumpEfi start" in raw:
                    return self.parse_usb_txt(raw)
                else:
                    f.seek(0)
                    plist_data = plist.load(f,dict_type=OrderedDict)
        except Exception as e:
            return self.show_error("Error Loading {}".format(os.path.basename(path)),e)
        if not len(plist_data.get("IOKitPersonalities",{})):
            return self.show_error("Missing Personalities","No IOKitPersonalities found in {}!".format(os.path.basename(path)))
        self.plist_path = path
        self.plist_data = plist_data
        self.pick_personality()

if __name__ == '__main__':
    u = USBMap()
    path = sys.argv[1] if len(sys.argv)>1 else None
    while True:
        u.main(path=path)
        path = None # Prevent a loop on exception
