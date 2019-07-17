#!/usr/bin/env python
import os, sys, re, pprint, binascii, plistlib, shutil, tempfile, zipfile, base64, plistlib, json
from Scripts import *

class USBMap:
    def __init__(self):
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        self.u = utils.Utils("USBMap")
        self.r = run.Run()
        self.d = downloader.Downloader()
        self.k = disk.Disk()
        self.iasl_url = "https://bitbucket.org/RehabMan/acpica/downloads/iasl.zip"
        self.iasl = None
        self.re = reveal.Reveal()
        self.ec = True # True = yes, False = no, None = force fake
        self.usbx = True # True = yes, False = no, a string with a model number will pull that data from Info.plist
        self.usb_overrides = {} # Dict of key/value pairs for power overrides
        self.sep_ssdt = True # True = separate EC/USBX/UIAC SSDTs, False = All in one SSDT
        self.scripts = "Scripts"
        self.output  = "Results"
        self.usb_re = re.compile("(SS|SSP|HS|HP|PR|USR)[a-fA-F0-9]{1,2}@[a-fA-F0-9]{1,}")
        self.usb_dict = {}
        self.xhc_devid = self.get_xhc_devid()
        
        self.xhc_addr = self.get_addr()
        self.eh01_addr = self.get_addr(" EH01@")
        self.eh02_addr = self.get_addr(" EH02@")

        self.min_uia_v = "0.7.0"
        self.plist = "./Scripts/USB.plist"
        self.disc_wait = 5
        self.cs = u"\u001b[32;1m"
        self.ce = u"\u001b[0m"
        self.bs = u"\u001b[36;1m"
        self.rs = u"\u001b[31;1m"
        self.nm = u"\u001b[35;1m"
        # Following values from RehabMan's USBInjectAll.kext:
        # https://github.com/RehabMan/OS-X-USB-Inject-All/blob/master/USBInjectAll/USBInjectAll-Info.plist
        self.usb_plist = { 
            "XHC": {
                "IONameMatch" : "XHC",
                "IOProviderClass" : "AppleUSBXHCIPCI",
                "CFBundleIdentifier" : "com.apple.driver.AppleUSBHostMergeProperties"
                # "kConfigurationName" : "XHC",
                # "kIsXHC" : True
            }, 
            "EH01": {
                "IONameMatch" : "EH01",
                "IOProviderClass" : "AppleUSBEHCIPCI",
                "CFBundleIdentifier" : "com.apple.driver.AppleUSBHostMergeProperties"
                # "kConfigurationName" : "EH01"
            },
            "EH02": {
                "IONameMatch" : "EH02",
                "IOProviderClass" : "AppleUSBEHCIPCI",
                "CFBundleIdentifier" : "com.apple.driver.AppleUSBHostMergeProperties"
                # "kConfigurationName" : "EH02"
            },
            "EH01-internal-hub": {
                "IOProbeScore" : 5000,
                "IOProviderClass" : "AppleUSB20InternalHub",
                "kConfigurationName" : "HUB1",
                "locationID" : 487587840
            },
            "EH02-internal-hub": {
                "IOProbeScore" : 5000,
                "IOProviderClass" : "AppleUSB20InternalHub",
                "kConfigurationName" : "HUB2",
                "locationID" : 437256192
            }
        }
        self.load_settings()

    def load_settings(self):
        if os.path.exists("./{}/settings.json".format(self.scripts)):
            self.settings = json.load(open("./{}/settings.json".format(self.scripts)))
        else:
            # Set up defaults
            self.settings = {
                "separate_ssdts" : True,
                "check_ec" : True,
                "check_usbx" : True,
                "usb_overrides" : {}
            }

    def flush_settings(self):
        json.dump(self.settings, open("./{}/settings.json".format(self.scripts), "w"))

    def get_model(self):
        return self.r.run({"args":["sysctl", "hw.model"]})[0].split(": ")[1].strip()

    def loop_dict(self, item, matched = []):
        # Check for _items, and if we have it, attach it to our dict
        if isinstance(item, list):
            # Just return a list of items
            new_list = []
            for i in item:
                new_list.append(self.loop_dict(i, matched))
            return new_list
        # Assume it's a dict
        i = {}
        if "_items" in item:
            i["items"] = self.loop_dict(item["_items"], matched)
        # At this point - we *should* have a device - add the name
        # and resolve wich object it's matched
        i["name"] = item.get("_name", "Unknown")
        i["location"] = ""
        if item.get("location_id", ""):
            loc = item.get("location_id", "").split("0x")[1].split(" ")[0]
            i["location"] = loc
            for m in matched:
                n = m["name"]
                if n.split("@")[-1].lower() == loc:
                    i["device"] = os.path.basename(n).split("@")[0]
        return i

    def gen_dict_extract(self, value, var):
        if hasattr(var,'iteritems'):
            for k, v in var.iteritems():
                if k == "location" and value.replace("0","") in v.replace("0",""):
                    yield var.get("name","Unknown")
                if isinstance(v, dict):
                    for result in self.gen_dict_extract(value, v):
                        yield result
                elif isinstance(v, list):
                    for d in v:
                        for result in self.gen_dict_extract(value, d):
                            yield result

    def get_xhc_devid(self):
        # attempts to get the xhc dev id
        ioreg_text = self.r.run({"args":["ioreg","-p","IODeviceTree", "-n", "XHC@14"]})[0]
        for line in ioreg_text.split("\n"):
            if "device-id" in line:
                try:
                    i = line.split("<")[1].split(">")[0][:4]
                    return "8086_"+i[-2:]+i[:2]
                except:
                    # Issues - break
                    break
        # Not found, or issues - return generic
        return "8086_xxxx"

    def get_addr(self,dev=" XHC@",c_name="  <class AppleUSB"):
        ioreg_text = self.r.run({"args":["ioreg","l","-p","IOService","-w0"]})[0]
        for line in ioreg_text.split("\n"):
            if dev in line and c_name in line:
                # Probably got it?  Split it
                try:
                    return line.split(dev)[1].split(c_name)[0]
                except:
                    return None
        return None

    def get_port_addr(self, port, controller):
        # Attempts to extract just the port number
        # Bits should be:
        #
        #   device   port   ??      ??        ??
        # [00000000][0000][0000][00000000][00000000]
        #
        # So we should shift both >> 20 and subtract
        #
        # First try to get the number in CTRLR@0000000
        try:
            port = port.split("@")[1]
        except:
            pass
        try:
            controller = controller.split("@")[1]
        except:
            pass
        # Now try to move/subtract them
        try:
            return (int(port,16)>>20)-(int(controller,16)>>20)
        except:
            return None

    def get_ports(self, ioreg_text = None):
        if os.path.exists("usb.txt"):
            with open ("usb.txt", "r") as f:
                ioreg_text = f.read()
        if not ioreg_text:
            ioreg_text = self.r.run({"args":["ioreg","-c","IOUSBDevice", "-w", "0"]})[0]
        matched = []
        for line in ioreg_text.split("\n"):
            match = self.usb_re.search(line)
            if match and "@1" in line and "USB" in line and not "HS15" in line:
                # format the line
                l = line.split("+-o ")[1].split(" ")[0]
                c = line.split("<class ")[1].split(",")[0]
                matched.append({"name":l, "type":c})
        return matched

    def get_by_device(self, matched = None):
        if not matched:
            matched = self.get_ports()
        # Get the system_profiler output, load as plist data, and search for addresses
        d = self.r.run({"args":["system_profiler", "-xml", "-detaillevel", "mini", "SPUSBDataType"]})[0]
        system_usb = plist.loads(d)
        # Loop through all the _items and build a dict
        return self.loop_dict(system_usb, matched)

    def map_inheritance(self, top, test, level = 1):
        # Iterates through each item in test, and returns a string with children
        # indented per level
        text = []
        for v in test:
            # Let's see if v matches our top
            if top.replace("0","") in v.get("location","unknown").replace("0",""):
                value = ("    " * level) + "- " + v.get("name","Unknown")
                text.append(value)
                if "items" in v:
                    # We have items!
                    text.extend(self.map_inheritance(v["location"],v["items"],level+1))
        return text

    def get_by_port(self):
        p = self.get_ports()
        d = self.get_by_device(p)
        usb = {}
        for n in p:
            m = n["name"]
            name = m.split("@")[0]
            ct = None
            # Check if hub based
            if name.startswith("HP"):
                nameint = int(name.replace("HP",""))
                if nameint < 20:
                    # 11-18 is EH01 Hub 1
                    ct = "EH01-internal-hub"
                    port = nameint-10
                    ty = 0
                else:
                    # 21-28 is EH02 Hub 2
                    ct = "EH02-internal-hub"
                    port = nameint-20
                    ty = 0
            else:
                # XHC  starts at 0x14
                # EH02 starts at 0x1A
                # EH01 starts at 0x1D
                xhc_start = int("0x140", 16)
                eh2_start = int("0x1A0", 16)
                eh1_start = int("0x1D0", 16)
                # Get the hex value - but limit to 3 spaces
                pnum = int(m.split("@")[1][:3], 16)
                # Find out which controller we're on
                if pnum > xhc_start and pnum < eh2_start:
                    # XHC Controller
                    ct = "XHC"
                    port = pnum - xhc_start
                    ty = 3
                elif pnum > eh2_start and pnum < eh1_start:
                    # EH02 Controller
                    ct = "EH02"
                    port = pnum - eh2_start
                    ty = 0
                else:
                    # EH01 Controller
                    ct = "EH01"
                    port = pnum - eh1_start
                    ty = 0
            if not name in usb:
                usb[name] = {
                    "selected": False,
                    "port": port,
                    "type": ty,
                    "controller": ct
                }
            t = usb[name]["type"]
            items = []
            for x in d:
                for y in x.get("items",[]):
                    items.extend(self.map_inheritance(m.split("@")[-1], y.get("items",[])))
                # items.extend(list(self.gen_dict_extract(m.split("@")[-1], x)))
            usb[name]["items"] = items
            if len(items):
                usb[name]["selected"] = True
        return usb

    def discover(self):
        # Let's enter discovery mode
        # Establish a baseline
        original = self.get_by_port()
        # Get names too
        try:
            with open(self.plist, "rb") as f:
                p = plist.load(f)
        except:
            p = None
        if p:
            for port in p:
                if not port in original:
                    # not available right now - skip
                    continue
                if p[port].get("name",None):
                    original[port]["name"] = p[port]["name"]
        if not len(original):
            self.u.head("Something's Not Right")
            print("")
            print("Was unable to locate any valid ports.")
            print("Please ensure you have XHC/EH01/EH02 in your IOReg")
            print("")
            self.u.grab("Press [enter] to return")
            return None
        last     = self.get_by_port()
        # Now we loop - and show each device that's got something
        # as selected - never deselect.  Let the user do that
        # in the following steps
        #
        # Wait for user input "q" to be sent, and we'll bail
        #
        last_added = None
        while True:
            self.u.head("Detecting Ports")
            print("")
            # Get the current ports - and compare them to the original
            # Only enabling those that aren't selected
            new = self.get_by_port()
            count  = 0
            extras = 0
            pad    = 10
            sel    = {
                "EH01":{
                    "total":0,
                    "selected":0
                },
                "EH02":{
                    "total":0,
                    "selected":0
                },
                "HUB1":{
                    "total":0,
                    "selected":0
                },
                "HUB2":{
                    "total":0,
                    "selected":0
                },
                "XHC":{
                    "total":0,
                    "selected":0
                }
            }
            for port in self.sort(new):
                count += 1
                # Extract missing items
                missing_items = [x for x in new[port]["items"] if not x in original[port]["items"]]
                if new[port]["selected"] and not original[port]["selected"]:
                    original[port]["selected"] = True
                    # original[port]["items"] = new[port]["items"]
                if len(new[port]["items"]) > len(last[port]["items"]):
                    # New item in this run
                    last_added = port
                    # Make sure we have an extra line for the rename info
                    extras += 1
                # Merge missing items if need be
                original[port]["items"].extend(missing_items)
                # Print out the port
                s = original[port]["selected"]
                p = original[port]["port"]
                n = port
                t = original[port]["type"]
                c = original[port]["controller"]
                if c in ["EH01-internal-hub","EH02-internal-hub"]:
                    c = "HUB"+c[3]
                sel[c]["total"] += 1
                # Removing the type output in discovery to avoid confusion, as it's
                # only guessed, and doesn't reflect any types set.
                #
                # ptext = "{}. {} - Type {} - Controller {}".format(count, n, t, c)
                ptext = "{}. {} - Controller {}".format(count, n, c)
                if port == last_added:
                    sel[c]["selected"] += 1
                    ptext = self.cs + ptext + self.ce
                elif s:
                    sel[c]["selected"] += 1
                    ptext = self.bs + ptext + self.ce
                print(ptext)
                if original[port].get("name",None):
                    extras += 1
                    print("    {}{}{}".format(self.nm, original[port]["name"], self.ce))
                if len(new[port]["items"]):
                    extras += len(new[port]["items"])
                    # print("\n".join(["     - {}".format(x.encode("utf-8")) for x in new[port]["items"]]))
                    print("\n".join([x.encode("utf-8") if not type(x) is str else x for x in new[port]["items"]]))
            seltext = []
            print("")
            for x in sel:
                if not sel[x]["total"]:
                    continue
                if sel[x]["selected"] < 1 or sel[x]["selected"] > 15:
                    seltext.append("{}{}:{}{}".format(self.rs, x, sel[x]["selected"], self.ce))
                else:
                    seltext.append("{}{}:{}{}".format(self.cs, x, sel[x]["selected"], self.ce))
            ptext = "Populated:  {}".format(", ".join(seltext))
            print(ptext)
            h = count+extras+pad if count+extras+pad > 24 else 24
            self.u.resize(80, h)
            print("Press Q then [enter] to stop")
            if last_added:
                print("Press N then [enter] to add a custom name to {}".format(last_added))
            print("")
            out = self.u.grab("Waiting {} seconds:  ".format(self.disc_wait), timeout=self.disc_wait)
            if not out or not len(out):
                continue
            if out.lower() == "q":
                break
            elif out.lower() == "n":
                # We're going to name the last selected port
                if not last_added:
                    # Nothing to name - keep going
                    continue
                out = self.get_name(original,last_added)
                if out:
                    # We got a name - set it
                    original[last_added]["name"] = out
                elif out == None:
                    # We need to clear the name
                    del original[last_added]["name"]
        return original

    def get_name(self, ports, port_name):
        self.u.resize(80, 24)
        self.u.head("Custom Name for {}".format(port_name))
        print("")
        print("Current Custom Name:\n\n    {}\n".format(ports[port_name].get("name","None")))
        if len(ports[port_name]["items"]):
            print("Items:\n\n{}".format("\n".join([x.encode("utf-8") if not type(x) is str else x for x in ports[port_name]["items"]])))
        else:
            print("Items:\n\n    None")
        print("")
        print("C. Clear Custom Name")
        print("R. Return to Discovery")
        print("")
        menu = self.u.grab("Please type a name for {}:  ".format(port_name))
        if not len(menu):
            return self.get_name(ports, port_name)
        if menu.lower() == "c":
            return None
        elif menu.lower() == "r":
            return False
        # Got something
        return menu

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
        self.u.grab("Press [enter] to return")
        return

    def hex_to_data(self, number):
        # Takes a number, converts it to hex
        # pads to 8 chars, swaps the bytes, and
        # converts to data
        hextest = hex(number).replace("0x","")
        hextest = "0"*(8-len(hextest)) + hextest
        # Swap the bytes
        hextest = list("0"*(len(hextest)%2)+hextest)
        hex_pairs = [hextest[i:i + 2] for i in range(0, len(hextest), 2)]
        hex_rev = hex_pairs[::-1]
        hex_str = "".join(["".join(x) for x in hex_rev])
        # Convert to data!
        hex_bytes = binascii.unhexlify(hex_str.encode("utf-8"))
        return plistlib.Data(hex_bytes)

    def build_kext(self):
        self.u.resize(80, 24)
        self.u.head("Creating USBMap.kext")
        print("")
        print("Loading plist")
        # Builds the kext itself
        with open(self.plist, "rb") as f:
            p = plist.load(f)
        print("Generating Info.plist")
        # Get the model number
        m = self.get_model()
        # Separate by types and build the proper setups
        ports = {}
        # Count up per channel
        sel = {
                "EH01":{
                    "top":0
                },
                "EH02":{
                    "top":0
                },
                "EH01-internal-hub":{
                    "top":0
                },
                "EH02-internal-hub":{
                    "top":0
                },
                "XHC":{
                    "top":0
                }
            }
        for u in self.sort(p,True):
            # Skip if HS15 - phantom port
            if u == "HS15":
                # Increment the XHC count
                sel["XHC"]["top"] += 1
                continue
            c = p[u]["controller"]
            if not c in ["XHC","EH01","EH02","EH01-internal-hub","EH02-internal-hub"]:
                # Not valid - skip
                continue
            # Count up
            sel[c]["top"] += 1
            # Map the HUBs into the EH01/02 chipsets for the kext
            if len(c) > 4:
                c = c[:4]
            # Skip if it's skipped
            if not p[u]["selected"]:
                continue
            # Figure out which controller each port is on
            # and map them in
            if not m+"-"+c in ports:
                ports[m+"-"+c] = {}
                for x in self.usb_plist.get(c, []):
                    # Setup defaults
                    ports[m+"-"+c][x] = self.usb_plist[c][x]
                # Add the necessary info for all of them
                ports[m+"-"+c]["IOClass"] = "AppleUSBHostMergeProperties"
                ports[m+"-"+c]["model"] = m
                # ports[m+"-"+c]["IOClass"] = "USBInjectAll"
                ports[m+"-"+c]["IOProviderMergeProperties"] = {
                    "port-count" : 0,
                    "ports" : {},
                }
            t_var = "portType" if len(p[u]["controller"]) > 4 else "UsbConnector"
            ports[m+"-"+c]["IOProviderMergeProperties"]["ports"][u] = {
                "port" : self.hex_to_data(sel[p[u]["controller"]]["top"]),
                t_var : p[u]["type"]
            }
            ports[m+"-"+c]["IOProviderMergeProperties"]["port-count"] = self.hex_to_data(sel[p[u]["controller"]]["top"])

        # Let's add our initial vars too
        final_dict = {
            "CFBundleDevelopmentRegion" : "English",
            "CFBundleGetInfoString" : "v1.0",
            "CFBundleIdentifier" : "com.corpnewt.USBMap",
            "CFBundleInfoDictionaryVersion" : "6.0",
            "CFBundleName" : "USBMap",
            "CFBundlePackageType" : "KEXT",
            "CFBundleShortVersionString" : "1.0",
            "CFBundleSignature" : "????",
            "CFBundleVersion" : "1.0",
            "IOKitPersonalities" : ports,
            "OSBundleRequired" : "Root"
        }
        print("Writing to USBMap.kext")
        # Remove if exists
        if os.path.exists("./{}/USBMap.kext".format(self.output)):
            shutil.rmtree("./{}/USBMap.kext".format(self.output), ignore_errors=True)
        # Make folder structure
        os.makedirs("./{}/USBMap.kext/Contents".format(self.output))
        # Add the Info.plist
        with open("./{}/USBMap.kext/Contents/Info.plist".format(self.output), "wb") as f:
            plist.dump(final_dict, f)
        print(" - Created USBMap.kext!")
        out = self.validate_power(False)
        out.append("USBMap.kext")
        self.prompt_install_ssdt(out,["USBInjectAll.kext"])
        print("")
        self.u.grab("Press [enter] to return")
        self.re.reveal("./{}/USBMap.kext".format(self.output))

    def check_iasl(self):
        target = os.path.join(os.path.dirname(os.path.realpath(__file__)), self.scripts, "iasl")
        if not os.path.exists(target):
            # Need to download
            temp = tempfile.mkdtemp()
            try:
                self._download_and_extract(temp,self.iasl_url)
            except:
                print("An error occurred :(")
            shutil.rmtree(temp, ignore_errors=True)
        if os.path.exists(target):
            return target
        return None

    def _download_and_extract(self, temp, url):
        ztemp = tempfile.mkdtemp(dir=temp)
        zfile = os.path.basename(url)
        print("Downloading {}".format(os.path.basename(url)))
        self.d.stream_to_file(url, os.path.join(ztemp,zfile), False)
        print(" - Extracting")
        btemp = tempfile.mkdtemp(dir=temp)
        # Extract with built-in tools \o/
        with zipfile.ZipFile(os.path.join(ztemp,zfile)) as z:
            z.extractall(os.path.join(temp,btemp))
        script_dir = os.path.join(os.path.dirname(os.path.realpath(__file__)), self.scripts)
        for x in os.listdir(os.path.join(temp,btemp)):
            if "iasl" in x.lower():
                # Found one
                print(" - Found {}".format(x))
                print("   - Chmod +x")
                self.r.run({"args":["chmod","+x",os.path.join(btemp,x)]})
                print("   - Copying to {} directory".format(os.path.basename(script_dir)))
                shutil.copy(os.path.join(btemp,x), os.path.join(script_dir,x))

    def compile(self, filename):
        # Verifies that iasl is present - downloads it if not
        # then attempts to compile
        # Returns the resulting aml file on success - or None
        # on failure
        if not self.iasl:
            self.iasl = self.check_iasl()
        if not self.iasl:
            # Didn't download
            return None
        # Run it!
        out = self.r.run({"args":[self.iasl, filename]})
        if out[2] != 0:
            return None
        aml_name = filename[:-3]+"aml" if filename.lower().endswith(".dsl") else filename+".aml"
        if os.path.exists(aml_name):
            return aml_name
        return None

    def al(self, totext, addtext, indent = 0, itext = "    "):
        return totext + (itext*indent) + addtext + "\n"

    def prompt_rename(self, ec_check):
        # Provide rename data if needed
        if not ec_check in [1,2,3]:
            return
        # Gather our rename vars
        name = ["EC0_","H_EC","ECDV"][ec_check-1]
        fhex = ["4543305f","485f4543","45434456"][ec_check-1]
        fb64 = ["RUMwXw==","SF9FQw==","RUNEVg=="][ec_check-1]
        # Print the rename info
        print("")
        print(self.rs+"The following is required for EC in config.plist -> ACPI -> Patches:"+self.ce)
        print("")
        print(self.bs+"Comment:"+self.cs+"  Rename {} to EC__".format(name)+self.ce)
        print(self.rs+"Hex Values:"+self.ce)
        print(self.bs+" - Find:"+self.cs+"  {}".format(fhex)+self.ce)
        print(self.bs+" - Repl:"+self.cs+"  45435f5f"+self.ce)
        print(self.rs+"Base64 Values:"+self.ce)
        print(self.bs+" - Find:"+self.cs+"  {}".format(fb64)+self.ce)
        print(self.bs+" - Repl:"+self.cs+"  RUNfXw=="+self.ce)
        print("")
        while True:
            # Find out if we should auto-apply the rename
            rename = self.u.grab("Apply automatically to booted EFI's config.plist? (y/n):  ")
            if not len(rename):
                continue
            if rename[0].lower() == "n":
                break
            if rename[0].lower() == "y":
                # Apply the rename
                print("Applying {} to EC__ rename".format(name))
                print(" - Locating EFI")
                try:
                    efi = self.k.get_efi(bdmesg.get_clover_uuid())
                    is_mounted = self.k.is_mounted(efi)
                    if is_mounted:
                        print(" --> Found at {}".format(efi))
                    else:
                        print(" --> Found at {}, mounting".format(efi))
                        out = self.k.mount_partition(efi)
                except:
                    # Failed to mount
                    print(" --> Failed, aborting.")
                    break
                if not self.k.get_mount_point(efi):
                    print(" --> Failed to mount, aborting.")
                    break
                # Locate the config.plist
                print(" - Locating config.plist")
                config = os.path.join(self.k.get_mount_point(efi), "EFI", "CLOVER", "config.plist")
                if not os.path.exists(config):
                    print(" --> Not found - aborting.")
                    break
                # Load the config
                print(" --> Located - loading")
                try:
                    with open(config,"rb") as f:
                        plist_data = plist.load(f)
                except:
                    print(" --> Failed to load, aborting.")
                    break
                # Add the value
                print(" --> Validating config.plist -> ACPI -> Patches")
                patches = plist_data.get("ACPI",{}).get("DSDT",{}).get("Patches",[])
                found_patch = changes_made = False
                if len(patches):
                    print(" --> Checking for existing {} -> EC__ Rename".format(name))
                    for x in patches:
                        if not ("Find" in x and "Replace" in x):
                            # Doesn't have all parts - avoid
                            continue
                        # Get the raw bytes if they exist
                        if x["Find"] == name.encode("utf-8") and x["Replace"] == "EC__".encode("utf-8"):
                            # Found a match
                            print(" ----> Found match!")
                            found_patch = True
                            if x.get("Disabled",False):
                                print(" ----> Enabling")
                                x["Disabled"] = False
                                changes_made = True
                            else:
                                print(" ----> Already enabled (may just need to reboot)")
                if not found_patch:
                    changes_made = True
                    print(" --> Adding {} -> EC__ Rename".format(name))
                    f = name.encode("utf-8") if sys.version_info >= (3, 0) else plistlib.Data(name.encode("utf-8"))
                    r = "EC__".encode("utf-8") if sys.version_info >= (3, 0) else plistlib.Data("EC__".encode("utf-8"))
                    plist_data["ACPI"]["DSDT"]["Patches"].append({
                        "Comment" : "Rename {} to EC__".format(name),
                        "Disabled" : False,
                        "Find" : f,
                        "Replace" : r
                    })
                if changes_made:
                    print(" --> Writing plist")
                    try:
                        with open(config,"wb") as f:
                            plist.dump(plist_data, f)
                        print(" --> !! Reboot needed for changes to take effect !!")
                    except:
                        print(" --> Failed to write, aborting.")
                        break
                else:
                    print(" --> No changes made to config.plist")
                if not is_mounted:
                    print(" --> Unmounting EFI")
                    try:
                        self.k.unmount_partition(efi)
                    except:
                        print(" --> Failed to unmount.")
                break

    def prompt_install_ssdt(self, ssdts = [], remove = []):
        # Gather the .aml files in our output folder - only if not provided
        if not len(ssdts):
            ssdts = []
            for f in os.listdir(self.output):
                if f.lower().endswith(".aml"):
                    ssdts.append(f)
        if not len(ssdts):
            # Nothing to do
            return
        print(self.bs+"Created the following file{}:".format("" if len(ssdts) == 1 else "s")+self.ce)
        print("")
        print("\n".join(ssdts))
        print("")
        while True:
            # Find out if we should auto-apply the rename
            apply = self.u.grab("Copy automatically to booted EFI? (y/n):  ")
            if not len(apply):
                continue
            if apply[0].lower() == "n":
                break
            if not apply[0].lower() == "y":
                continue
            # We should be able to apply now
            print("")
            print("Locating EFI")
            try:
                efi = self.k.get_efi(bdmesg.get_clover_uuid())
                is_mounted = self.k.is_mounted(efi)
                if is_mounted:
                    print(" - Found at {}".format(efi))
                else:
                    print(" - Found at {}, mounting".format(efi))
                    out = self.k.mount_partition(efi)
            except:
                # Failed to mount
                print(" - Failed, aborting.")
                break
            if not self.k.get_mount_point(efi):
                print(" - Failed to mount, aborting.")
                break
            # Locate the config.plist
            print("Locating patched folder")
            patched = os.path.join(self.k.get_mount_point(efi), "EFI", "CLOVER", "ACPI", "patched")
            if not os.path.exists(patched):
                print(" - Not found - aborting.")
                break
            if any(x for x in ssdts if x.lower().endswith(".kext")):
                # Have at least one kext we're copying
                print("Locating Other folder")
                other = os.path.join(self.k.get_mount_point(efi), "EFI", "CLOVER", "kexts", "Other")
                if not os.path.exists(other):
                    print(" - Not found - aborting.")
                    break
            if len(remove):
                print(" - Verifying removals...")
                removelist = {}
                for x in remove:
                    if not x in removelist:
                        removelist[x] = []
                    if x.lower().endswith(".kext"):
                        # Is a kext - let's check the .kext folders
                        for d in sorted(os.listdir(os.path.join(self.k.get_mount_point(efi),"EFI","CLOVER","kexts"))):
                            p = os.path.join(self.k.get_mount_point(efi), "EFI","CLOVER","kexts",d,x)
                            if os.path.exists(p):
                                # Found it - save
                                removelist[x].append(os.path.join(self.k.get_mount_point(efi),"EFI","CLOVER","kexts",d))
                    else:
                        # Assume it's an .efi driver
                        for d in ["drivers32","drivers64","drivers32UEFI","drivers64UEFI"]:
                            p = os.path.join(self.k.get_mount_point(efi),"EFI","CLOVER",d,x)
                            if os.path.exists(p):
                                # Found it - save
                                removelist[x].append(os.path.join(self.k.get_mount_point(efi),"EFI","CLOVER","kexts",d))
                exists = [x for x in removelist if len(removelist[x])]
                if len(exists):
                    print(" - Located the following:")
                    for x in exists:
                        print(" --> {} at:".format(x))
                        for p in removelist[x]:
                            print(" ----> {}".format(p))
                    print("")
                    while True:
                        apply = self.u.grab("Remove? (y/n):  ")
                        if not len(apply):
                            continue
                        if apply[0].lower() == "n":
                            print("")
                            break
                        if not apply[0].lower() == "y":
                            continue
                        print("")
                        # Remove them
                        print(" - Removing:")
                        for x in exists:
                            for p in removelist[x]:
                                path = os.path.join(p,x)
                                print(" --> {}".format(path))
                                try:
                                    if os.path.isdir(path):
                                        shutil.rmtree(path)
                                    else:
                                        os.remove(path)
                                except:
                                    pass
                        # Leave the loop
                        break
            # Iterate and copy
            print(" - Copying Files")
            for s in ssdts:
                if s.lower().endswith(".kext"):
                    target = other
                else:
                    target = patched
                print(" --> {} to:".format(s))
                print(" ----> {}".format(target))
                if os.path.exists(os.path.join(target, s)):
                    print(" ------> Already exists, removing")
                    try:
                        if os.path.isdir(os.path.join(target,s)):
                            shutil.rmtree(os.path.join(target,s))
                        else:
                            os.remove(os.path.join(target,s))
                    except:
                        pass
                try:
                    if os.path.isdir("./{}/{}".format(self.output, s)):
                        shutil.copytree("./{}/{}".format(self.output, s), os.path.join(target,s))
                    else:
                        shutil.copy("./{}/{}".format(self.output, s), os.path.join(target,s))
                except:
                    print(" ------> Failed to copy!")
            if not is_mounted:
                print(" - Unmounting EFI")
                try:
                    self.k.unmount_partition(efi)
                except:
                    print(" --> Failed to unmount.")
            break

    def build_ec_ssdt(self):
        # Once we've validated that we need this, we can auto-build it
        dsl = """
// SSDT-EC.dsl
//
// Injects a fake EC device
//
// Formatting credits: RehabMan - https://github.com/RehabMan/Intel-NUC-DSDT-Patch/blob/master/SSDT-EC.dsl
//

DefinitionBlock ("", "SSDT", 2, "hack", "_EC", 0)
{
    // Inject Fake EC device
    Device(_SB.EC)
    {
        Name(_HID, "EC000000")
    }
}
"""
        # Ensure our Results folder exists
        if not os.path.exists(self.output):
            os.mkdir(self.output)
        # Create the SSDT
        print("Writitng SSDT-EC.dsl")
        with open("./{}/SSDT-EC.dsl".format(self.output), "w") as f:
            f.write(dsl)
        print("Compiling SSDT-EC.dsl")
        # Try to compile
        out = self.compile("./{}/SSDT-EC.dsl".format(self.output))
        if not out:
            print(" - Created SSDT-EC.dsl - but could not compile!")
        else:
            print(" - Created SSDT-EC.aml!")
            return out
        return None

    def build_usbx_ssdt(self, uxm_data, m):
        # Once we know that we need the USBX ssdt - we can auto-build
        dsl = """
// SSDT-USBX.dsl
//
// USB Power Properties for Sierra+
//
// Formatting credits: RehabMan - https://github.com/RehabMan/Intel-NUC-DSDT-Patch/blob/master/SSDT-USBX.dsl
//

DefinitionBlock ("", "SSDT", 2, "hack", "_USBX", 0)
{
    // USB power properties via USBX device
    Device(_SB.USBX)
    {
        Name(_ADR, 0)
        Method (_DSM, 4)
        {
            If (!Arg2) { Return (Buffer() { 0x03 } ) }
            Return (Package()
            {
                // these values """ + m + "\n"
        for x in uxm_data:
            v = uxm_data[x]
            print(" -- {} --> {}".format(x, v))
            dsl += '                "{}", {},\n'.format(x, v)
        # Add the footer
        dsl += """
            })
        }
    }
}
"""
        # Ensure our Results folder exists
        if not os.path.exists(self.output):
            os.mkdir(self.output)
        # Create the SSDT
        print("Writitng SSDT-USBX.dsl")
        with open("./{}/SSDT-USBX.dsl".format(self.output), "w") as f:
            f.write(dsl)
        print("Compiling SSDT-USBX.dsl")
        # Try to compile
        out = self.compile("./{}/SSDT-USBX.dsl".format(self.output))
        if not out:
            print(" - Created SSDT-USBX.dsl - but could not compile!")
        else:
            print(" - Created SSDT-USBX.aml!")
            return out
        return None

    def build_ssdt(self, **kwargs):
        # Builds an SSDT-UIAC.dsl with the supplied info
        # Structure should be fairly easy - just need to supply info
        # programmatically with some specifics

        # We're also going to roll in the EC device checking, USBX info
        # and AppleBusPowerController stuffs from our power SSDT

        # See if we need to check/force EC and USBX
        # and see if we need a power override based on model
        # or manual values.
        #
        # EC Values
        check_ec = kwargs.get("check_ec",False) # True = Yes, False = No, None = Force
        # USBX Values
        check_ux = kwargs.get("check_ux",True) # Needed for the others
        ux_model = kwargs.get("ux_model", self.get_model()) # USBX Model selected, if any - to check for presence in Info.plist - should be provided
        uxm_data = kwargs.get("uxm_data",None)  # Dict of data to override with - or None for no override

        # Ensure our Results folder exists
        if not os.path.exists(self.output):
            os.mkdir(self.output)
        # Clear out everything in that folder
        for f in os.listdir(self.output):
            try:
                os.remove("./{}/{}".format(self.output, f))
            except:
                pass

        log = "" # Keep trac of our progress in case we interrupt this menu
        self.u.resize(80, 24)
        self.u.head("Creating SSDTs")
        print("")
        if self.sep_ssdt:
            print("!! Creating separate SSDTs as needed !!")
            log += "\n!! Creating separate SSDTs as needed !!\n"
        else:
            print("!! All SSDT data will go into SSDT-UIAC !!")
            log += "\n!! All SSDT data will go into SSDT-UIAC !!\n"
        print("")
        print("Loading plist")
        log += "\nLoading plist\n"
        with open(self.plist, "rb") as f:
            p = plist.load(f)
        print("Generating SSDT-UIAC.dsl")
        log += "Generating SSDT-UIAC.dsl\n"
        dsl = """
// SSDT-UIAC.dsl
//
// This SSDT contains all ports selected via USBMap per CorpNewt's script.
// It is to be used in conjunction wtih USBInjectAll.kext.
//
// Note:
// portType=0 seems to indicate normal external USB2 port (as seen in MacBookPro8,1)
// portType=2 seems to indicate "internal device" (as seen in MacBookPro8,1)
// portType=4 is used by MacBookPro8,3 (reason/purpose unknown)
//
// Formatting credits: RehabMan - https://github.com/RehabMan/OS-X-USB-Inject-All/blob/master/SSDT-UIAC-ALL.dsl
//

DefinitionBlock ("", "SSDT", 2, "hack", "_UIAC", 0)
{
"""

        ########################################################################
        #                           EC Device Setup                            #
        ########################################################################
        # EC checks - just in case
        # Add the EC device if we don't have one
        if check_ec in [True,None]:
            print("Checking EC")
            log += "Checking EC\n"
            # We're checking EC - get the return
            ec_check = 0 if check_ec == None else self.check_ec()
            if ec_check == 0:
                # We failed some check, need to make the SSDT
                print(" - EC SSDT required")
                log += " - EC SSDT required\n"
                if self.sep_ssdt:
                    self.build_ec_ssdt()
                else:
                    dsl += """
    // Inject Fake EC device
    Device(_SB.EC)
    {
        Name(_HID, "EC000000")
    }
"""
            elif ec_check == 4:
                print(" - EC is properly setup")
                log += " - EC is properly setup\n"
            else:
                print(" - EC SSDT not required, but EC requires rename")
                log += " - EC SSDT not required, but EC requires rename\n"
                # Provide rename data if needed
                self.prompt_rename(ec_check)
                        

        ########################################################################
        #                          USBX Power Setup                            #
        ########################################################################
        # Check for check_ux, ux_model in Info.plist, and uxm_data
        # if all three line up, then we need an AppleBusPowerController override
        if check_ux:
            print("Checking USBX requirements")
            log += "Checking USBX requirements"
            # We're actively checking power - we need to check if our currently
            # selected model is in the IOUSBHostFamily.kext's Info.plist - and
            # if so, we need to pull that info *unless* we have uxm_data already
            # provided for us - then we override with that regardless.
            usb_data = self.get_usb_info()
            # Let's see if our model is in here
            m = self.get_closest_smbios(usb_data, ux_model)
            if not m:
                m = self.user_pick_smbios(True, False)
                # Re-display the logs
                self.u.head("Creating SSDTs")
                print(log)
            if not m:
                # We somehow bailed or quit or something
                return
            if ux_model == m and not uxm_data:
                print(" - Found {} in IOUSBHostFamily.kext".format(m))
                print(" --> No user overrides provided")
                dsl += """
    // USB Ports Mapped
    Device(UIAC)
    {
        Name(_HID, "UIA00000")
    
        Name(RMCF, Package()
        {
"""
            elif ux_model == m and uxm_data:
                print(" - Found {} in IOUSBHostFamily.kext".format(m))
                print(" --> User overrides provided")
                # Our model exists in the Info.plist - and we have an override!
                # Add the header, and start off with this data
                dsl += """
    // USB Ports Mapped
    Device(UIAC)
    {
        Name(_HID, "UIA00000")
    
        Name(RMCF, Package()
        {
            // USB Power Properties for Sierra+ (using USBInjectAll injection)
            "AppleBusPowerController", Package()
            {
                // these values are user supplied""" + "\n"
                for x in uxm_data:
                    v = uxm_data[x]
                    print(" -- {} --> {}".format(x, v))
                    dsl += '                "{}", {},\n'.format(x, v)
                # Add the footer:
                dsl += "            },\n"
            elif ux_model != m:
                if uxm_data:
                    print(" - {} not found in IOUSBHostFamily.kext".format(ux_model))
                    print(" --> User overrides provided")
                    from_text = "were user-provided"
                else:
                    print(" - {} not found in IOUSBHostFamily.kext".format(ux_model))
                    print(" --> Using properties from {}".format(m))
                    uxm_data = usb_data[m]["IOProviderMergeProperties"]
                    from_text = "from "+m
                # Our model was not found in the Info.plist - add our own
                # USBX device followed by the UIAC device
                if self.sep_ssdt:
                    self.build_usbx_ssdt(uxm_data, from_text)
                    dsl += """
    // USB Ports Mapped
    Device(UIAC)
    {
        Name(_HID, "UIA00000")
    
        Name(RMCF, Package()
        {
"""
                else:
                    dsl += """
    // USB power properties via USBX device
    Device(_SB.USBX)
    {
        Name(_ADR, 0)
        Method (_DSM, 4)
        {
            If (!Arg2) { Return (Buffer() { 0x03 } ) }
            Return (Package()
            {
                // these values """ + from_text + "\n"
                    for x in uxm_data:
                        v = uxm_data[x]
                        print(" -- {} --> {}".format(x, v))
                        dsl += '                "{}", {},\n'.format(x, v)
                    # Add the footer
                    dsl += """
            })
        }
    }

    // USB Ports Mapped
    Device(UIAC)
    {
        Name(_HID, "UIA00000")
    
        Name(RMCF, Package()
        {
"""
        else:
            dsl += """
    // USB Ports Mapped
    Device(UIAC)
    {
        Name(_HID, "UIA00000")
    
        Name(RMCF, Package()
        {
"""

        ########################################################################
        #                          UIAC Ports Setup                            #
        ########################################################################
        # Initialize and format the data
        ports = {}
        excluded = []
        # Count up per channel
        sel = {
                "EH01":{
                    "top":0
                },
                "EH02":{
                    "top":0
                },
                "EH01-internal-hub":{
                    "top":0
                },
                "EH02-internal-hub":{
                    "top":0
                },
                "XHC":{
                    "top":0
                }
            }
        for u in self.sort(p,True):
            # Skip if HS15 - phantom port
            if u == "HS15":
                if "HS15" in p:
                    # Port was actually found - exclude it
                    excluded.append(u)
                sel["XHC"]["top"] += 1
                continue
            c = p[u]["controller"]
            if not c in ["XHC","EH01","EH02","EH01-internal-hub","EH02-internal-hub"]:
                # Not valid - skip
                continue
            # Count up
            sel[c]["top"] += 1
            # Gather a list of enabled ports
            # populates XHC, EH01, EH02, HUB1, and HUB2
            # Skip if it's skipped
            if not p[u]["selected"]:
                excluded.append(u)
                continue
            if not c in ports:
                # Setup a default
                ports[c] = {
                    "ports": {}
                }
            '''if u.startswith("HP"):
                nameint = int(u.replace("HP",""))
                if nameint < 20:
                    # 11-18 is EH01 Hub 1
                    top = nameint-10
                else:
                    # 21-28 is EH02 Hub 2
                    top = nameint-20'''
            ports[c]["port-count"] = sel[c]["top"]
            # Add the port itself
            ports[c]["ports"][u] = {
                "UsbConnector": p[u]["type"],
                "port": sel[c]["top"]
            }
        # All ports should be mapped correctly - let's walk
        # the controllers and format accordingly
        for c in self.sort(ports):
            # Got a controller, let's add it
            d = c if not c == "XHC" else self.xhc_devid
            # Set controller to HUB1/2 if needed
            if d in ["EH01-internal-hub","EH02-internal-hub"]:
                d = "HUB"+c[3]
            # Build the header
            dsl = self.al(dsl, '"{}", Package()'.format(d), 3)
            dsl = self.al(dsl, '{', 3)
            dsl = self.al(dsl, '"port-count", Buffer() { '+str(ports[c]["port-count"])+', 0, 0, 0 },', 4)
            dsl = self.al(dsl, '"ports", Package()', 4)
            dsl = self.al(dsl, '{', 4)
            # Add the ports
            for p in self.sort(ports[c]["ports"]):
                port = ports[c]["ports"][p]
                # Port header
                dsl = self.al(dsl, '"{}", Package()'.format(p), 5)
                dsl = self.al(dsl, "{", 5)
                # UsbConnector/portType
                if d in ["HUB1","HUB2"]:
                    # Comment out UsbConnector
                    dsl = self.al(dsl, '//"UsbConnector", {},'.format(port["UsbConnector"]), 6)
                    # Use portType instead
                    dsl = self.al(dsl, '"portType", 0,', 6)
                else:
                    # UsbConnector
                    dsl = self.al(dsl, '"UsbConnector", {},'.format(port["UsbConnector"]), 6)
                # Add the port
                dsl = self.al(dsl, '"port", Buffer() { '+str(port["port"])+', 0, 0, 0 },', 6)
                # dsl = self.al(dsl, '"port", Buffer() { '+str(count)+', 0, 0, 0 },', 6)
                # Close the package
                dsl = self.al(dsl, "},", 5)
            # Close the port-count buffer
            dsl = self.al(dsl, "},", 4)
            # Close the ports package
            dsl = self.al(dsl, "},", 3)
        # Close out the rest of the dsl
        dsl = self.al(dsl, "})", 2)
        dsl = self.al(dsl, "}", 1)

        ########################################################################
        #                           Finalize SSDT                              #
        ########################################################################
        dsl = self.al(dsl, "}")
        dsl = self.al(dsl, "//EOF")
        # Save the output - then try to compile it
        print("Writitng SSDT-UIAC.dsl")
        with open("./{}/SSDT-UIAC.dsl".format(self.output), "w") as f:
            f.write(dsl)
        print("Compiling SSDT-UIAC.dsl")
        # Try to compile
        out = self.compile("./{}/SSDT-UIAC.dsl".format(self.output))
        if not out:
            print(" - Created SSDT-UIAC.dsl - but could not compile!")
        else:
            print(" - Created SSDT-UIAC.aml!")
        if len(excluded):
            # Create a text file with the boot arg
            print("Writing Exclusion-Arg.txt")
            arg = "uia_exclude={}".format(",".join(excluded))
            with open("Exclusion-Arg.txt", "w") as f:
                f.write(arg)
            print(" - Created Exclusion-Arg.txt!")
        print("")
        # Gather the resulting SSDTs and ask the user if they'd like them installed
        self.prompt_install_ssdt()
        print("")
        self.u.grab("Press [enter] to return")
        if not out:
            self.re.reveal("./{}/SSDT-UIAC.dsl".format(self.output))
        else:
            self.re.reveal(out)

    def edit_plist(self):
        self.u.head("Edit USB.plist")
        print("")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if not os.path.exists(self.plist):
            print("Missing {}!".format(self.plist))
            print("Use the discovery mode to create one.")
            print("")
            self.u.grab("Press [enter] to exit")
            return
        # Load the plist
        try:
            with open(self.plist, "rb") as f:
                p = plist.load(f)
        except:
            p = None
        if not p:
            print("Plist malformed or empty!")
            print("")
            self.u.grab("Press [enter] to exit")
            return
        # At this point, we have a working plist
        # let's serve up the options, and let the user adjust
        # as needed.
        while True:
            self.u.head("Edit USB.plist")
            print("")
            count  = 0
            pad    = 29
            extras = 0
            #sel    = 0
            sel    = {
                "EH01":{
                    "total":0,
                    "selected":0
                },
                "EH02":{
                    "total":0,
                    "selected":0
                },
                "HUB1":{
                    "total":0,
                    "selected":0
                },
                "HUB2":{
                    "total":0,
                    "selected":0
                },
                "XHC":{
                    "total":0,
                    "selected":0
                }
            }
            for u in self.sort(p):
                count += 1
                # Print out the port
                s = p[u]["selected"]
                r = p[u]["port"]
                n = u
                t = p[u]["type"]
                c = p[u]["controller"]
                if c in ["EH01-internal-hub","EH02-internal-hub"]:
                    c = "HUB"+c[3]
                sel[c]["total"] += 1
                ptext = "[{}] {}. {} - Type {} - Controller {}".format("#" if s else " ", count, n, t, c)
                if s:
                    sel[c]["selected"] += 1
                    #sel += 1
                    ptext = self.bs + ptext + self.ce
                print(ptext)
                if p[u].get("name",None):
                    extras += 1
                    print("    {}{}{}".format(self.nm, p[u]["name"], self.ce))
                if len(p[u]["items"]):
                    extras += len(p[u]["items"])
                    # print("\n".join(["     - {}".format(x.encode("utf-8")) for x in p[u]["items"]]))
                    print("\n".join([x.encode("utf-8") if not type(x) is str else x for x in p[u]["items"]]))
            print("")
            seltext = []
            for x in sel:
                if not sel[x]["total"]:
                    continue
                if sel[x]["selected"] < 1 or sel[x]["selected"] > 15:
                    seltext.append("{}{}:{}{}".format(self.rs, x, sel[x]["selected"], self.ce))
                else:
                    seltext.append("{}{}:{}{}".format(self.cs, x, sel[x]["selected"], self.ce))
            ptext = "Selected:  {}".format(", ".join(seltext))
            print(ptext)
            h = count+extras+pad if count+extras+pad > 24 else 24
            self.u.resize(80, h)
            # Let's display some defaults with the ability to change them for USB power stuffs
            ec = self.bs+"Force Fake"+self.ce
            if self.settings["check_ec"] == True:
                ec = self.cs+"Yes"+self.ce
            elif self.settings["check_ec"] == False:
                ec = self.rs+"No"+self.ce
            usbx = self.cs+"Yes"+self.ce
            if len(self.settings["usb_overrides"]):
                # We have overrides
                usbx = self.cs+"Yes"+self.bs+", With 1 Custom Override"+self.ce if len(self.settings["usb_overrides"]) == 1 else self.cs+"Yes"+self.bs+", With {} Custom Overrides".format(len(self.settings["usb_overrides"]))+self.ce
            else:
                usbx = self.rs+"No"+self.ce if self.settings["check_usbx"] == False else self.cs+"Yes"+self.ce
            print("Check EC:    {}".format(ec))
            print("Check USBX:  {}".format(usbx))
            print("One SSDT:    {}".format(self.cs+"No - Separate SSDT-EC, SSDT-USBX, and SSDT-UIAC"+self.ce if self.sep_ssdt else self.bs+"Yes - Joined EC and USBX inside SSDT-UIAC"+self.ce))
            print("")
            print("E. Toggle EC (Yes, No, Force)")
            print("U. Toggle USBX (Yes, No){}".format(" - Removes Overrides!" if len(self.settings["usb_overrides"]) else ""))
            print("D. Toggle One SSDT")
            print("O. Set USB Overrides")
            print("")
            print("M. Main Menu")
            print("A. Select All")
            print("N. Select None")
            print("K. Build USBMap.kext")
            print("S. Build SSDT-UIAC")
            print("T. Show Types")
            print("Q. Quit")
            print("")
            print("Select ports to toggle with comma-delimited lists (eg. 1,2,3,4,5)")
            print("Change types using this formula T:1,2,3,4,5:t where t is the type")
            print("Set custom names using this formula C:1:Name - Name = None to clear")
            print("")
            menu = self.u.grab("Please make your selection:  ")
            if not len(menu):
                continue
            if menu.lower() == "q":
                self.u.resize(80, 24)
                self.u.custom_quit()
            elif menu.lower() == "m":
                return
            elif menu.lower() == "e":
                if self.settings["check_ec"] == True:
                    self.settings["check_ec"] = False
                elif self.settings["check_ec"] == False:
                    self.settings["check_ec"] = None
                else:
                    self.settings["check_ec"] = True
                self.flush_settings()
                continue
            elif menu.lower() == "u":
                self.settings["usb_overrides"] = {}
                if not self.settings["check_usbx"] in [True,False]:
                    self.settings["check_usbx"] = True
                elif self.settings["check_usbx"] == True:
                    self.settings["check_usbx"] = False
                else:
                    self.settings["check_usbx"] = True
                self.flush_settings()
                continue
            elif menu.lower() == "d":
                self.sep_ssdt ^= True
                continue
            elif menu.lower() == "o":
                self.get_overrides()
                if len(self.settings["usb_overrides"]):
                    self.settings["check_usbx"] = True
                self.flush_settings()
                continue
            elif menu.lower() == "t":
                self.print_types()
                continue
            elif menu.lower() == "k":
                self.build_kext()
                return
            elif menu.lower() == "s":
                # Gather args
                args = {"check_ec":self.settings["check_ec"]}
                if self.settings["check_usbx"]:
                    # On or off - just pass that along
                    args["check_ux"] = self.settings["check_usbx"]
                if len(self.settings["usb_overrides"]):
                    # We have custom overrides
                    args["uxm_data"] = self.settings["usb_overrides"]
                self.build_ssdt(**args)
                return
            elif menu.lower() in ["a","n"]:
                setto = (menu.lower() == "a")
                for u in self.sort(p):
                    p[u]["selected"] = setto
                # Flush changes
                with open(self.plist, "wb") as f:
                    plist.dump(p, f)
                continue
            # Check if we need to toggle
            if menu[0].lower() == "t":
                # We should have a type
                try:
                    nums = [int(x) for x in menu.split(":")[1].replace(" ","").split(",")]
                    t = int(menu.split(":")[-1])
                    for x in nums:
                        if x < 1 or x > len(p):
                            # Out of bounds - skip
                            continue
                        # Valid index
                        p[self.sort(p)[x-1]]["type"] = t
                except:
                    # Didn't work - something didn't work - bail
                    pass
            elif menu[0].lower() == "c":
                # We should have a new name
                try:
                    nums = [int(x) for x in menu.split(":")[1].replace(" ","").split(",")]
                    name = menu.split(":")[-1]
                    for x in nums:
                        if x < 1 or x > len(p):
                            # Out of bounds - skip
                            continue
                        # Valid index
                        if name.lower() == "none" and p[self.sort(p)[x-1]].get("name",None):
                            # Has a name, and we want to remove it
                            del p[self.sort(p)[x-1]]["name"]
                        else:
                            # Adding a name
                            p[self.sort(p)[x-1]]["name"] = name
                except:
                    # Didn't work
                    pass
            else:
                # Maybe a list of numbers?
                try:
                    nums = [int(x) for x in menu.replace(" ","").split(",")]
                    for x in nums:
                        p[self.sort(p)[x-1]]["selected"] ^= True
                except:
                    pass
            # Flush changes
            with open(self.plist, "wb") as f:
                plist.dump(p, f)

    def get_overrides(self):
        while True:
            self.u.resize(80,24)
            self.u.head("USB Overrides")
            pad = 13
            print("")
            if not len(self.settings["usb_overrides"]):
                count = 1
                print(self.rs+"No USB overrides set."+self.ce)
            else:
                count = 0
                for x in self.settings["usb_overrides"]:
                    count += 1
                    print("{}. {}{}{}:{}{}{}".format(count, self.bs, x, self.ce, self.cs, self.settings["usb_overrides"][x], self.ce))
            print("")
            print("You can add a new override by typing name:value (eg. kUSBWakePowerSupply:5100)")
            print("or you can remove existing values by typing their number.")
            print("")
            print("S. Copy From SMBIOS (located in IOUSBHostFamily.kext's Info.plist)")
            print("C. Clear All")
            print("M. Return to Menu")
            print("Q. Quit")
            h = count+pad if count+pad > 24 else 24
            self.u.resize(80, h)
            menu = self.u.grab("Please select an option:  ")
            if not len(menu):
                continue
            elif menu.lower() == "m":
                return
            elif menu.lower() == "c":
                self.settings["usb_overrides"] = {}
                self.flush_settings()
                continue
            elif menu.lower() == "q":
                self.u.resize(80,24)
                self.u.custom_quit()
            elif menu.lower() == "s":
                out = self.user_pick_smbios(False)
                if out:
                    # Got a valid SMBIOS version
                    usb_data = self.get_usb_info()
                    self.settings["usb_overrides"] = usb_data[out]["IOProviderMergeProperties"]
                    self.flush_settings()
                continue
            # Check if we have an int - and if it's in our list
            try:
                # Pop the key at index of menu-1 from our usb_overrides
                self.settings["usb_overrides"].pop(list(self.settings["usb_overrides"])[int(menu)-1])
                self.flush_settings()
                continue
            except:
                pass
            # Well, not an int - let's try to split by : and get the values
            try:
                parts = menu.split(":")
                k,v = parts[0], parts[1]
                self.settings["usb_overrides"][k] = v
                self.flush_settings()
            except:
                # Not formatted right
                continue

    def get_kb_ms(self):
        p = self.get_by_port()
        if not len(p):
            self.u.head("Something's Not Right")
            print("")
            print("Was unable to locate any valid ports.")
            print("Please ensure you have XHC/EH01/EH02 in your IOReg")
            print("")
            self.u.grab("Press [enter] to return")
            return
        # Auto select those that are populated
        for u in p:
            if len(p[u]["items"]):
                p[u]["selected"] = True
        while True:
            self.u.head("Select Keyboard And Mouse")
            print("")
            print("Please adjust the following selections to reflect only your keyboard")
            print("and mouse.  This is to prevent them being excluded on reboot (or else")
            print("they wouldn't work).  You can select none if your kb/mouse are not USB.")
            print("")
            count  = 0
            pad    = 20
            extras = 0
            sel    = 0
            for u in self.sort(p):
                count += 1
                # Print out the port
                s = p[u]["selected"]
                r = p[u]["port"]
                n = u
                t = p[u]["type"]
                ptext = "[{}] {}. {} - Type {}".format("#" if s else " ", count, n, t)
                if s:
                    sel += 1
                    ptext = self.bs + ptext + self.ce
                print(ptext)
                if len(p[u]["items"]):
                    extras += len(p[u]["items"])
                    # print("\n".join(["     - {}".format(x.encode("utf-8")) for x in p[u]["items"]]))
                    print("\n".join([x.encode("utf-8") if not type(x) is str else x for x in p[u]["items"]]))
            print("")
            if sel < 1 or sel > 2:
                ptext = "{}Selected: {}{}".format(self.rs, sel, self.ce)
            else:
                ptext = "{}Selected: {}{}".format(self.cs, sel, self.ce)
            print(ptext)
            h = count+extras+pad if count+extras+pad > 24 else 24
            self.u.resize(80, h)
            print("C. Confirm")
            print("A. Select All")
            print("N. Select None")
            print("M. Main Menu")
            print("Q. Quit")
            print("")
            print("Select ports to toggle with comma-delimited lists (eg. 1,2,3,4,5)")
            print("")
            menu = self.u.grab("Please make your selection:  ")
            if not len(menu):
                continue
            if menu.lower() == "q":
                self.u.custom_quit()
            elif menu.lower() == "m":
                return None
            elif menu.lower() == "a":
                for u in p:
                    p[u]["selected"] = True
                continue
            elif menu.lower() == "n":
                for u in p:
                    p[u]["selected"] = False
                continue
            elif menu.lower() == "c":
                return self.sort([x for x in p if p[x]["selected"]])
            else:
                # Maybe a list of numbers?
                try:
                    nums = [int(x) for x in menu.replace(" ","").split(",")]
                    for x in nums:
                        p[self.sort(p)[x-1]]["selected"] ^= True
                except:
                    pass

    def get_uia_args(self):
        bootargs = self.r.run({"args":"nvram -p | grep boot-args", "shell":True})[0]
        if not len(bootargs):
            return []
        arglist = bootargs.split("\t")[1].strip("\n").replace('"',"").replace("'","").split(" ") # split by space
        uia = []
        for arg in arglist:
            if "uia_" in arg:
                uia.append(arg)
        return uia

    def get_non_uia_args(self):
        bootargs = self.r.run({"args":"nvram -p | grep boot-args", "shell":True})[0]
        if not len(bootargs):
            return []
        arglist = bootargs.split("\t")[1].strip("\n").replace('"',"").replace("'","").split(" ") # split by space
        uia = []
        for arg in arglist:
            if not "uia_" in arg:
                uia.append(arg)
        uia = [x for x in uia if len(x)]
        return uia

    def sort(self, usblist, check_phantom = False):
        # Custom sorting based on prefixes
        #
        # Prefix order needed = HSxx, USRx, SSxx
        newlist = []
        hslist  = []
        usrlist = []
        sslist  = []
        rest    = []
        hplist  = []
        for x in usblist:
            if x.startswith("HS"):
                hslist.append(x)
            elif x.startswith("SS"):
                sslist.append(x)
            elif x.startswith("USR"):
                usrlist.append(x)
            elif x.startswith("HP"):
                hplist.append(x)
            else:
                rest.append(x)
        # Check if we have HS14 in our list and our xhci device id starts with 8
        # then add a phantom HS15 port to preserve proper numbering
        if check_phantom and self.xhc_devid.startswith("8086_8") and "HS14" in hslist:
            if not "HS15" in hslist:
                hslist.append("HS15")
        newlist.extend(sorted(hslist))
        newlist.extend(sorted(usrlist))
        newlist.extend(sorted(sslist))
        newlist.extend(sorted(rest))
        newlist.extend(sorted(hplist))
        return newlist

    def check_uia(self):
        # Checks for the presence of USBInjectAll and gets the version number
        # will also make sure it's new enough to use the exclude all args
        out = self.r.run({"args":["kextstat"]})[0]
        for line in out.split("\n"):
            if "usbinjectall" in line.lower():
                # Found it!
                try:
                    v = line.split("(")[1].split(")")[0]
                except:
                    return None
                return v
        return None

    def check_ec(self):
        # Let's look for a couple of things
        # 1. We check for the existence of AppleBusPowerController in ioreg -> IOService
        #    If it exists, then we don't need any SSDT or renames
        # 2. We want to see if we have ECDT in ACPI and if so, we force a fake EC SSDT
        #    as renames and such can interfere
        # 3. We check for EC, EC0, H_EC, or ECDV in ioreg - and if found, we check
        #    if the _STA is 0 or not - if it's not 0, and not EC, we prompt for a rename
        #    We match that against the PNP0C09 name in ioreg
        #
        # Output values are:
        #
        # 0 = create EC SSDT
        # 1 = rename EC0 to EC
        # 2 = rename H_EC to EC
        # 3 = rename ECDV to EC
        # 4 = No SSDT or user interaction required - already working

        # Check for AppleBusPowerController first - that means our current
        # EC is correct
        abpc = self.r.run({"args":["ioreg", "-l", "-p", "IOService", "-w0"]})[0].split("\n")
        for line in abpc:
            if "IOClass" in line and "AppleBusPowerController" in line:
                # Found it!
                return 4
        
        # At this point - we know AppleBusPowerController isn't loaded - let's look at renames and such
        # Check for ECDT in ACPI - if this is present, all bets are off
        # and we need to avoid any EC renames and such
        b = bdmesg.bdmesg()
        primed = False
        for line in b.split("\n"):
            if "GetAcpiTablesList" in line:
                primed = True
                continue
            if "GetUserSettings" in line:
                primed = False
                break
            if primed:
                if "ECDT" in line:
                    # We found ECDT - baaaaiiiillllll
                    return 0

        # No ECDT in bdmesg - or bdmesg isn't around, let's check for EC0 or H_EC
        pnp = self.r.run({"args":["ioreg", "-l", "-p", "IODeviceTree", "-w0"]})[0].split("\n")
        primed = False
        sta = 0
        waspnp = False
        rename = 0
        for line in pnp:
            # We're looking for "EC " in the line - and that the name is <"PNP0C09"> - then we'll check the _STA value
            if "EC " in line or "EC0 " in line or "H_EC " in line or "ECDV " in line:
                if "H_EC " in line:
                    rename = 2
                elif "EC0 " in line:
                    rename = 1
                elif "ECDV " in line:
                    rename = 3
                # should be the right device
                primed = True
                continue
            # Let's skip everything else unless we're primed
            if not primed:
                # Everything after here 
                continue
            # Check if we hit a closing bracket
            if line.replace(" ","").replace("|","") == "}":
                # if we close, and somehow set our _STA, we need to unset
                # if it was the wrong device
                if waspnp:
                    break
                sta = 0
                primed = False
                continue
            # At this point, we check if we're primed, and look for <"PNP0C09">
            if '<"PNP0C09">' in line:
                # We got the right device at least - flag it
                waspnp = True
                continue
            if '"_STA"' in line:
                # Got the _STA value - set it
                try:
                    sta = int(line.split(" = ")[1])
                except:
                    # Not an int, reset
                    sta = 0
        if waspnp:
            # We found our device - let's check the values
            if sta == 0:
                # No need to rename, avoid it - add a fake
                return 0
            # We found pnp - but we need to rename it seems
            return rename
        
        # If we got here, then we didn't find EC, and didn't need to rename it
        # so we return 0 to prompt for an EC fake SSDT to be made
        return 0

    def get_usb_info(self):
        # Moved in 10.15
        os_version = self.r.run({"args":["sw_vers","-productVersion"]})[0].strip()
        if (os_version < "10.15"):
            path = "/System/Library/Extensions/IOUSBHostFamily.kext/Contents/Info.plist"
            key  = "IOKitPersonalities"
        else:
            path = "/System/Library/Extensions/IOUSBHostFamily.kext/Contents/PlugIns/AppleUSBHostPlatformProperties.kext/Contents/Info.plist"
            key  = "IOKitPersonalities_x86_64"
        try:
            with open(path,"rb") as f:
                usb_plist = plist.load(f)
            usb_list = usb_plist.get(key,None)
        except:
            return None
        return usb_list

    def get_closest_smbios(self, info = {}, smbios = None):
        if not smbios:
            smbios = self.get_model()
        if info == {}:
            info = self.get_usb_info()
        if smbios in info:
            # Already there - just return it
            return smbios
        # Get the model we have without the numbers
        mn = "".join([x for x in smbios if not x in "0123456789,"])
        n1=n2=0
        newest = None
        for x in info:
            if x.startswith("AppleUSBHostResources"):
                # Skip - not a model
                continue
            xn = "".join([y for y in x if not y in "0123456789,"])
            if xn == mn:
                # Found a match - let's compare the numbers
                try:
                    x1,x2 = x.replace(xn,"").split(",")
                    if int(x1) > n1 or (int(x1) == n1 and int(x2) > n2):
                        # Larger either primary or sub
                        n1 = int(x1)
                        n2 = int(x2)
                        newest = x
                except:
                    pass
        # Return newest - it will be None if no match is found
        return newest

    def user_pick_smbios(self, close=True, allow_return=True):
        # Didn't find a match - have the user pick from the list
        usb_list = self.get_usb_info()
        m = self.get_model()
        if usb_list == None:
            print(" - Failed to open IOUSBHostFamily.kext's Info.plist!")
            print("Aborting")
            print("")
            self.u.grab("Press [enter] to return")
            return None
        model_list = sorted([x for x in usb_list if not x.startswith("AppleUSBHostResources") and not "-" in x])
        pad = 12
        h = len(model_list)+pad if len(model_list)+pad > 24 else 24
        self.u.resize(80, h)
        while True:
            if close:
                self.u.head("Select Close SMBIOS")
                print("")
                print("{} not found in IOUSBHostFamily's Info.plist please pick".format(m))
                print("the closest match in age/form factor from below:\n")
            else:
                self.u.head("Select SMBIOS")
                print("")
                print("Current SMBIOS:  {}".format(m))
                print("Please select the target SMBIOS from the following list:\n")
            count = 0
            for x in model_list:
                count +=1 
                print("{}. {}".format(count, x))
            print("")
            if allow_return:
                print("M. Return to previous menu")
            print("Q. Quit")
            print("")
            menu = self.u.grab("Please select an option:  ")
            if not len(menu):
                continue
            if menu.lower() == "m" and allow_return:
                return None
            elif menu.lower() == "q":
                self.u.resize(80,24)
                self.u.custom_quit()
            # attempt to select from the list
            try:
                self.u.resize(80,24)
                u = int(menu)
                return model_list[u-1]
            except:
                # Not a valid number
                continue

    def validate_power(self, display = True):
        log = ""
        if display:
            self.u.resize(80, 24)
            self.u.head("Validating USB Power Settings")
            print("")
        print("Checking EC")
        log += "Checking EC\n"
        ec_check = self.check_ec()
        ec_good = False
        ssdts = []
        if ec_check == 0:
            print(" - EC SSDT required")
            log += " - EC SSDT required\n"
            out = self.build_ec_ssdt()
            if out:
                ssdts.append(os.path.basename(out))
        elif ec_check == 4:
            ec_good = True
            print(" - EC is properly setup")
            log += " - EC is properly setup\n"
        else:
            print(" - EC SSDT not required, but EC requires rename")
            log += " - EC SSDT not required, but EC requires rename\n"
            self.prompt_rename(ec_check)

        print("Checking USBX requirements")
        log += "Checking USBX requirements\n"
        usbx_good = False
        usb_data = self.get_usb_info()
        # Let's see if our model is in here
        ux_model = self.get_model()
        m = self.get_closest_smbios(usb_data, ux_model)
        if ux_model == m:
            print(" - Found {} in IOUSBHostFamily.kext - no USBX needed".format(m))
            usbx_good = True
        else:
            print(" - {} not found in IOUSBHostFamily.kext - checking for USBX".format(ux_model))
            log += " - {} not found in IOUSBHostFamily.kext - checking for USBX".format(ux_model)
            usbx = self.r.run({"args":["ioreg", "-l", "-p", "IOACPIPlane", "-w0"]})[0].split("\n")
            found = False
            for line in usbx:
                if "USBX" in line and "<class" in line:
                    found = True
                    usbx_good = True
                    try:
                        usbxaddr = ": " + line.split("+-o ")[1].split(" ")[0]
                    except:
                        usbxaddr = ""
                    print(" --> USBX device found{}".format(usbxaddr))
                    break
            if not found:
                print(" --> USBX device NOT found!")
                if len(self.settings["usb_overrides"]):
                    print(" ----> {} not found in IOUSBHostFamily.kext".format(ux_model))
                    print(" ------> User overrides provided")
                    uxm_data = self.settings["usb_overrides"]
                    from_text = "were user-provided"
                else:
                    if not m:
                        m = self.user_pick_smbios(True, False)
                        if display:
                            self.u.head("Validating USB Power Settings")
                            print("")
                        print(log)
                    if not m:
                        # We failed somewhere
                        return []
                    print(" ---> {} not found in IOUSBHostFamily.kext".format(ux_model))
                    print(" ------> Using properties from {}".format(m))
                    usb_data = self.get_usb_info()
                    uxm_data = usb_data[m]["IOProviderMergeProperties"]
                    from_text = "from "+m
                out = self.build_usbx_ssdt(uxm_data, from_text)
                if out:
                    ssdts.append(os.path.basename(out))
        print("")
        if display:
            print("EC Setup Properly:   {}{}{}".format(self.cs if ec_good else self.rs, ec_good, self.ce))
            print("USBX Setup Properly: {}{}{}".format(self.cs if usbx_good else self.rs, usbx_good, self.ce))
            print("")
        if len(ssdts):
            if display:
                self.prompt_install_ssdt(ssdts)
                print("")
            else:
                return ssdts
        if display:
            self.u.grab("Press [enter] to return")
        return []

    def main(self):
        self.u.resize(80, 24)
        self.u.head("USBMap")
        print("")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if os.path.exists(self.plist):
            print("Plist:          "+self.bs+"{}".format(os.path.basename(self.plist))+self.ce)
        else:
            print("Plist:          "+self.rs+"None"+self.ce)
        args = self.get_uia_args()
        if len(args):
            print("UIA Boot Args:  "+self.cs+"{}".format(" ".join(args))+self.ce)
        else:
            print("UIA Boot Args:  "+self.rs+"None"+self.ce)
        uia_version = self.check_uia()
        uia_text = "USBInjectAll:   "
        if not uia_version:
            # Not loaded
            uia_text += self.rs+"Not Loaded - NVRAM boot-args WILL NOT WORK"+self.ce
        else:
            # Loaded - check if v is enough
            v = self.u.compare_versions(uia_version, self.min_uia_v)
            if v:
                # Under minimum version
                uia_text += self.cs+"v"+uia_version+" Loaded -"+self.bs+" HSxx/SSxx Exclude"+self.rs+" WILL NOT WORK"+self.bs+" (0.7.0 min)"+self.ce
            else:
                # Equal to, or higher than the min version
                uia_text += self.cs+"v{} Loaded".format(uia_version)+self.ce
        print(uia_text)
        aptio_loaded = self.bs+"Unknown"+self.ce
        aptio = next((x for x in bdmesg.bdmesg().split("\n") if "aptiomemoryfix" in x.lower()), None)
        if aptio:
            aptio_loaded = self.cs+"Loaded"+self.ce if "success" in aptio.lower() else self.rs+"Not Loaded"+self.ce
        print("AptioMemoryFix: {}{}".format(aptio_loaded, "" if not "Not Loaded" in aptio_loaded else self.rs+" - NVRAM boot-args MAY NOT WORK."+self.ce))
        print("")
        print("NVRAM Arg Options:")
        if os.path.exists("Exclusion-Arg.txt"):
            print("  E. Apply Exclusion-Arg.txt")
        print("  H. Exclude HSxx Ports ("+self.bs+"-uia_exclude_hs"+self.ce+")")
        print("  S. Exclude SSxx Ports ("+self.bs+"-uia_exclude_ss"+self.ce+")")
        print("  C. Clear Exclusions")
        print("")
        print("R.  Remove USB.plist from Scripts Folder")
        print("T.  Reset Settings to Defaults")
        print("P.  Edit Plist & Create SSDT/Kext")
        print("D.  Discover Ports")
        print("U.  Validate USB Power Settings")
        print("Q.  Quit")
        print("")
        menu = self.u.grab("Please select an option:  ")
        if not len(menu):
            return
        if menu.lower() == "q":
            self.u.custom_quit()
        # Check what else we've got!
        if menu.lower() == "d":
            p = self.discover()
            if os.path.exists(self.plist):
                # It exists - we need to merge
                with open(self.plist, "rb") as f:
                    po = plist.load(f)
                for u in p:
                    if not u in po:
                        # Make sure we have the entry
                        po[u] = p[u]
                    if p[u]["selected"]:
                        # Mirror selection - only if True
                        po[u]["selected"] = True
                    if len(p[u]["items"]) > len(po[u]["items"]):
                        # Extra items in the new one - dump them
                        po[u]["items"] = p[u]["items"]
                    if p[u].get("name",None):
                        # Got a name - make sure it reflects
                        po[u]["name"] = p[u]["name"]
                    elif po[u].get("name",None):
                        # No name - make sure we don't have one
                        del po[u]["name"]
                p = po
            # Just write the output
            with open(self.plist, "wb") as f:
                plist.dump(p, f)
        elif menu.lower() == "r":
            if os.path.exists(self.plist):
                os.unlink(self.plist)
        elif menu.lower() == "t":
            try:
                os.remove("./{}/settings.json".format(self.scripts))
            except:
                pass
            self.load_settings()
        elif menu.lower() == "u":
            self.validate_power()
        elif menu.lower() == "p":
            self.edit_plist()
        elif menu.lower() == "e" and os.path.exists("Exclusion-Arg.txt"):
            with open("Exclusion-Arg.txt", "r") as f:
                ea = f.read().strip()
            if not len(ea):
                return
            self.u.head("Adding Exclusion-Arg.txt Contents")
            print("")
            args = self.get_non_uia_args()
            args.append(ea)
            print('sudo nvram boot-args="{}"'.format(" ".join(args)))
            self.r.run({"args":["nvram",'boot-args="{}"'.format(" ".join(args))],"sudo":True,"stream":True})
        elif menu.lower() == "c":
            self.u.head("Clearing UIA Related Args")
            print("")
            args = self.get_non_uia_args()
            if not len(args):
                print("sudo nvram -d boot-args")
                self.r.run({"args":["nvram","-d","boot-args"],"sudo":True,"stream":True})
            else:
                print('sudo nvram boot-args="{}"'.format(" ".join(args)))
                self.r.run({"args":["nvram",'boot-args="{}"'.format(" ".join(args))],"sudo":True,"stream":True})
        elif menu.lower() == "s":
            self.u.head("Excluding SSxx Ports")
            print("")
            args = self.get_non_uia_args()
            args.append("-uia_exclude_ss")
            print('sudo nvram boot-args="{}"'.format(" ".join(args)))
            self.r.run({"args":["nvram",'boot-args="{}"'.format(" ".join(args))],"sudo":True,"stream":True})
        elif menu.lower() == "h":
            keep = self.get_kb_ms()
            if keep == None:
                # Skip if we cancelled
                return
            # Got something to exclude - let's add the args
            self.u.head("Excluding HSxx Ports")
            print("")
            args = self.get_non_uia_args()
            args.append("-uia_exclude_hs")
            if keep:
                args.append("uia_include={}".format(",".join(keep)))
            print('sudo nvram boot-args="{}"'.format(" ".join(args)))
            self.r.run({"args":["nvram",'boot-args="{}"'.format(" ".join(args))],"sudo":True,"stream":True})
        return

u = USBMap()
while True:
    u.main()
