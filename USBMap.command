#!/usr/bin/python
import os, sys, re, pprint, binascii, plistlib, shutil
from Scripts import *

class USBMap:
    def __init__(self):
        self.u = utils.Utils("USBMap")
        self.r = run.Run()
        self.re = reveal.Reveal()
        self.scripts = "Scripts"
        self.usb_re = re.compile("(SS|SSP|HS|HP|PR|USR)[a-fA-F0-9]{1,2}@[a-fA-F0-9]{1,}")
        self.usb_dict = {}
        self.plist = "usb.plist"
        self.disc_wait = 5
        self.cs = u"\u001b[32;1m"
        self.ce = u"\u001b[0m"
        self.bs = u"\u001b[36;1m"
        # Following values from RehabMan's USBInjectAll.kext:
        # https://github.com/RehabMan/OS-X-USB-Inject-All/blob/master/USBInjectAll/USBInjectAll-Info.plist
        self.usb_plist = { 
            "XHC": {
                "IONameMatch" : "XHC",
                "IOProviderClass" : "AppleUSBXHCIPCI",
                "kConfigurationName" : "XHC",
                "kIsXHC" : True
            }, 
            "EH01": {
                "IONameMatch" : "EH01",
                "IOProviderClass" : "AppleUSBEHCIPCI",
                "kConfigurationName" : "EH01"
            },
            "EH02": {
                "IONameMatch" : "EH02",
                "IOProviderClass" : "AppleUSBEHCIPCI",
                "kConfigurationName" : "EH02"
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

        """
            Type Integer
            (BYTE)
            Specifies the host connector type. It is ignored by OSPM if the port is not user
            visible:
            0x00: Type A connector
            0x01: Mini-AB connector
            0x02: ExpressCard
            0x03: USB 3 Standard-A connector
            0x04: USB 3 Standard-B connector
            0x05: USB 3 Micro-B connector
            0x06: USB 3 Micro-AB connector
            0x07: USB 3 Power-B connector
            0x08: Type C connector - USB2-only
            0x09: Type C connector - USB2 and SS with Switch
            0x0A: Type C connector - USB2 and SS without Switch
            0x0B-0xFE: Reserved
            0xFF: Proprietary connector
        """

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

    def get_ports(self, ioreg_text = None):
        if os.path.exists("usb.txt"):
            with open ("usb.txt", "r") as f:
                ioreg_text = f.read()
        if not ioreg_text:
            ioreg_text = self.r.run({"args":["ioreg","-c","IOUSBDevice", "-w", "0"]})[0]
        matched = []
        for line in ioreg_text.split("\n"):
            match = self.usb_re.search(line)
            if match and "@1" in line and "USB" in line:
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
                items.extend(list(self.gen_dict_extract(m.split("@")[-1], x)))
            usb[name]["items"] = items
            if len(items):
                usb[name]["selected"] = True
        return usb

    def discover(self):
        # Let's enter discovery mode
        # Establish a baseline
        original = self.get_by_port()
        if not len(original):
            self.u.head("Something's Not Right")
            print("")
            print("Was unable to locate any valid ports.")
            print("Please ensure you have XHC/EH01/EH02 in your IOReg")
            print("")
            self.u.grab("Press [enter] to return...")
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
            self.u.head("Detecting Ports...")
            print("")
            # Get the current ports - and compare them to the original
            # Only enabling those that aren't selected
            new = self.get_by_port()
            count  = 0
            extras = 0
            pad    = 8
            for port in sorted(new):
                count += 1
                if new[port]["selected"] and not original[port]["selected"]:
                    original[port]["selected"] = True
                    original[port]["items"] = new[port]["items"]
                if len(new[port]["items"]) > len(last[port]["items"]):
                    # New item in this run
                    last_added = port
                # Print out the port
                s = original[port]["selected"]
                p = original[port]["port"]
                n = port
                t = original[port]["type"]
                ptext = "[{}] {}. {} - Port {} - Type {}".format("#" if s else " ", count, n, hex(p), t)
                if port == last_added:
                    ptext = self.cs + ptext + self.ce
                elif s:
                    ptext = self.bs + ptext + self.ce
                print(ptext)
                if len(new[port]["items"]):
                    extras += len(new[port]["items"])
                    print("\n".join(["     - {}".format(x) for x in new[port]["items"]]))
            h = count+extras+pad if count+extras+pad > 24 else 24
            self.u.resize(80, h)
            print("Press Q and [enter] to stop...")
            print("")
            out = self.u.grab("Waiting {} seconds:  ".format(self.disc_wait), timeout=self.disc_wait)
            if not out or not len(out):
                continue
            if out.lower() == "q":
                break
        return original

    def print_types(self):
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
        self.u.grab("Press [enter] to return...")
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
        # Builds the kext itself
        with open(self.plist, "rb") as f:
            p = plist.load(f)
        # Get the model number
        m = self.get_model()
        # Separate by types and build the proper setups
        ports = {}
        for u in p:
            # Skip if it's skipped
            if not p[u]["selected"]:
                continue
            # Figure out which controller each port is on
            # and map them in
            c = p[u]["controller"]
            if not m+"-"+c in ports:
                ports[m+"-"+c] = {}
                for x in self.usb_plist.get(c, []):
                    # Setup defaults
                    ports[m+"-"+c][x] = self.usb_plist[c][x]
                # Add the necessary info for all of them
                ports[m+"-"+c]["CFBundleIdentifier"] = "com.apple.driver.AppleUSBHostMergeProperties"
                ports[m+"-"+c]["IOClass"] = "AppleUSBHostMergeProperties"
                ports[m+"-"+c]["IOProviderMergeProperties"] = {
                    "port-count" : 0,
                    "ports" : {}
                }
            ports[m+"-"+c]["IOProviderMergeProperties"]["ports"][u] = {
                "UsbConnector" : p[u]["type"],
                "port" : p[u]["port"]
            }
        # At this point - we should have our whole thing mapped out - but our port counts
        # and ports are still ints
        for t in ports:
            top = 0
            for y in ports[t]["IOProviderMergeProperties"]["ports"]:
                test = ports[t]["IOProviderMergeProperties"]["ports"][y]["port"]
                if test > top:
                    top = test
                # Convert to hex, padd with 0's, reverse, and convert to
                # bytes
                ports[t]["IOProviderMergeProperties"]["ports"][y]["port"] = self.hex_to_data(test)
            # Set the top
            ports[t]["IOProviderMergeProperties"]["port-count"] = self.hex_to_data(top)

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
            "IOKitPersonalities" : ports
        }

        # Remove if exists
        if os.path.exists("USBMap.kext"):
            shutil.rmtree("USBMap.kext", ignore_errors=True)
        # Make folder structure
        os.makedirs("USBMap.kext/Contents")
        # Add the Info.plist
        with open("USBMap.kext/Contents/Info.plist", "wb") as f:
            plist.dump(final_dict, f)
        self.re.reveal("USBMap.kext")

    def edit_plist(self):
        self.u.head("Edit USB.plist")
        print("")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if not os.path.exists(self.plist):
            print("Missing {}!".format(self.plist))
            print("Use the discovery mode to create one.")
            print("")
            self.u.grab("Press [enter] to exit...")
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
            self.u.grab("Press [enter] to exit...")
            return
        # At this point, we have a working plist
        # let's serve up the options, and let the user adjust
        # as needed.
        while True:
            self.u.head("Edit USB.plist")
            print("")
            count  = 0
            pad    = 14
            extras = 0
            for u in sorted(p):
                count += 1
                # Print out the port
                s = p[u]["selected"]
                r = p[u]["port"]
                n = u
                t = p[u]["type"]
                print("[{}] {}. {} - Port {} - Type {}".format("#" if s else " ", count, n, hex(r), t))
                if len(p[u]["items"]):
                    extras += len(p[u]["items"])
                    print("\n".join(["     - {}".format(x) for x in p[u]["items"]]))
            h = count+extras+pad if count+extras+pad > 24 else 24
            self.u.resize(80, h)
            print("M. Main Menu")
            print("K. Build USBMap.kext")
            print("T. Show Types")
            print("Q. Quit")
            print("")
            print("Select ports to toggle with comma-delimited lists (eg. 1,2,3,4,5)")
            print("Change types using this formula T:1,2,3,4,5:t where t is the type")
            print("")
            menu = self.u.grab("Please make your selection:  ")
            if not len(menu):
                continue
            if menu.lower() == "q":
                self.u.custom_quit()
            elif menu.lower() == "m":
                return
            elif menu.lower() == "t":
                self.print_types()
            elif menu.lower() == "k":
                self.build_kext()
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
                        p[sorted(p)[x-1]]["type"] = t
                except:
                    # Didn't work - something didn't work - bail
                    pass
            else:
                # Maybe a list of numbers?
                try:
                    nums = [int(x) for x in menu.replace(" ","").split(",")]
                    for x in nums:
                        p[sorted(p)[x-1]]["selected"] ^= True
                except:
                    pass
            # Flush changes
            with open(self.plist, "wb") as f:
                plist.dump(p, f)

    def main(self):
        self.u.resize(80, 24)
        self.u.head("USBMap")
        print("")
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if os.path.exists(self.plist):
            print("Plist: {}".format(self.plist))
        else:
            print("Plist: None")
        print("")
        print("R. Remove Plist")
        print("P. Edit Plist/Build Kext")
        print("D. Discover Ports")
        print("Q. Quit")
        print("")
        menu = self.u.grab("Please select and option:  ")
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
                p = po
            # Just write the output
            with open(self.plist, "wb") as f:
                plist.dump(p, f)
        elif menu.lower() == "r":
            if os.path.exists(self.plist):
                os.unlink(self.plist)
        elif menu.lower() == "p":
            self.edit_plist()
        return

u = USBMap()
while True:
    u.main()