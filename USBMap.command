#!/usr/bin/env python
import os, sys, re, pprint, binascii, plistlib, shutil, tempfile, zipfile
from Scripts import *

class USBMap:
    def __init__(self):
        self.u = utils.Utils("USBMap")
        self.r = run.Run()
        self.d = downloader.Downloader()
        self.iasl_url = "https://bitbucket.org/RehabMan/acpica/downloads/iasl.zip"
        self.iasl = None
        self.re = reveal.Reveal()
        self.scripts = "Scripts"
        self.usb_re = re.compile("(SS|SSP|HS|HP|PR|USR)[a-fA-F0-9]{1,2}@[a-fA-F0-9]{1,}")
        self.usb_dict = {}
        self.xch_devid = self.get_xhc_devid()
        self.min_uia_v = "0.7.0"
        self.bdmesg = os.path.join(os.path.dirname(os.path.realpath(__file__)), self.scripts, "bdmesg")
        if not os.path.exists(self.bdmesg):
            self.bdmesg = None
        self.plist = "usb.plist"
        self.disc_wait = 5
        self.cs = u"\u001b[32;1m"
        self.ce = u"\u001b[0m"
        self.bs = u"\u001b[36;1m"
        self.rs = u"\u001b[31;1m"
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
                ptext = "{}. {} - Port {} - Type {} - Controller {}".format(count, n, hex(p), t, c)
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
        self.u.resize(80, 24)
        self.u.head("Creating USBMap.kext")
        print("")
        print("Loading plist...")
        # Builds the kext itself
        with open(self.plist, "rb") as f:
            p = plist.load(f)
        print("Generating Info.plist...")
        # Get the model number
        m = self.get_model()
        # Separate by types and build the proper setups
        ports = {}
        count = 0
        top = 0
        for u in self.sort(p):
            count += 1
            # Skip if it's skipped
            if not p[u]["selected"]:
                continue
            # Skip if HS15 - phantom port
            if u == "HS15":
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
                ports[m+"-"+c]["IOClass"] = "AppleUSBHostMergeProperties"
                ports[m+"-"+c]["IOClass"] = "USBInjectAll"
                ports[m+"-"+c]["IOProviderMergeProperties"] = {
                    "port-count" : 0,
                    "ports" : {}
                }
            top = count
            ports[m+"-"+c]["IOProviderMergeProperties"]["ports"][u] = {
                "UsbConnector" : p[u]["type"],
                "port" : self.hex_to_data(top)
            }
            ports[m+"-"+c]["IOProviderMergeProperties"]["port-count"] = self.hex_to_data(top)

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
        print("Writing to USBMap.kext...")
        # Remove if exists
        if os.path.exists("USBMap.kext"):
            shutil.rmtree("USBMap.kext", ignore_errors=True)
        # Make folder structure
        os.makedirs("USBMap.kext/Contents")
        # Add the Info.plist
        with open("USBMap.kext/Contents/Info.plist", "wb") as f:
            plist.dump(final_dict, f)
        print(" - Created USBMap.kext!")
        self.re.reveal("USBMap.kext")
        print("")
        self.u.grab("Press [enter] to return...")

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
        print("Downloading {}...".format(os.path.basename(url)))
        self.d.stream_to_file(url, os.path.join(ztemp,zfile), False)
        print(" - Extracting...")
        btemp = tempfile.mkdtemp(dir=temp)
        # Extract with built-in tools \o/
        with zipfile.ZipFile(os.path.join(ztemp,zfile)) as z:
            z.extractall(os.path.join(temp,btemp))
        script_dir = os.path.join(os.path.dirname(os.path.realpath(__file__)), self.scripts)
        for x in os.listdir(os.path.join(temp,btemp)):
            if "iasl" in x.lower():
                # Found one
                print(" - Found {}".format(x))
                print("   - Chmod +x...")
                self.r.run({"args":["chmod","+x",os.path.join(btemp,x)]})
                print("   - Copying to {} directory...".format(os.path.basename(script_dir)))
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

    def build_ssdt(self):
        # Builds an SSDT-UIAC.dsl with the supplied info
        # Structure should be fairly easy - just need to supply info
        # programmatically with some specifics
        self.u.resize(80, 24)
        self.u.head("Creating SSDT-UIAC")
        print("")
        print("Loading plist...")
        with open(self.plist, "rb") as f:
            p = plist.load(f)
        print("Generating SSDT-UIAC.dsl...")
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
    Device(UIAC)
    {
        Name(_HID, "UIA00000")
    
        Name(RMCF, Package()
        {
"""
        # Initialize and format the data
        ports = {}
        excluded = []
        count = 0
        top = 0
        for u in self.sort(p):
            count += 1
            # Gather a list of enabled ports
            # populates XHC, EH01, EH02, HUB1, and HUB2
            # Skip if it's skipped
            if not p[u]["selected"]:
                excluded.append(u)
                continue
            # Skip if HS15 - phantom port
            if u == "HS15":
                excluded.append(u)
                continue
            c = p[u]["controller"]
            if not c in ["XHC","EH01","EH02","HUB1","HUB2"]:
                # Not valid - skip
                continue
            if not c in ports:
                # Setup a default
                ports[c] = {
                    "ports": {}
                }
            top = count
            ports[c]["port-count"] = top
            # Add the port itself
            ports[c]["ports"][u] = {
                "UsbConnector": p[u]["type"],
                "port": top
            }
        # All ports should be mapped correctly - let's walk
        # the controllers and format accordingly
        for c in self.sort(ports):
            # Got a controller, let's add it
            d = c if not c == "XHC" else self.xch_devid
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
                if c in ["HUB1","HUB2"]:
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
        dsl = self.al(dsl, "}")
        dsl = self.al(dsl, "//EOF")
        # Save the output - then try to compile it
        print("Writitng SSDT-UIAC.dsl...")
        with open("SSDT-UIAC.dsl", "w") as f:
            f.write(dsl)
        print("Compiling SSDT-UIAC.dsl...")
        # Try to compile
        out = self.compile("SSDT-UIAC.dsl")
        if not out:
            print(" - Created SSDT-UIAC.dsl - but could not compile!")
            self.re.reveal("SSDT-UIAC.dsl")
        else:
            print(" - Created SSDT-UIAC.aml!")
            self.re.reveal(out)
        if len(excluded):
            # Create a text file with the boot arg
            print("Writing Exclusion-Arg.txt...")
            arg = "uia_exclude={}".format(",".join(excluded))
            with open("Exclusion-Arg.txt", "w") as f:
                f.write(arg)
            print(" - Created Exclusion-Arg.txt!")
            
        print("")
        self.u.grab("Press [enter] to return...")

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
            pad    = 19
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
                if len(p[u]["items"]):
                    extras += len(p[u]["items"])
                    print("\n".join(["     - {}".format(x) for x in p[u]["items"]]))
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
            print("")
            menu = self.u.grab("Please make your selection:  ")
            if not len(menu):
                continue
            if menu.lower() == "q":
                self.u.resize(80, 24)
                self.u.custom_quit()
            elif menu.lower() == "m":
                return
            elif menu.lower() == "t":
                self.print_types()
                continue
            elif menu.lower() == "k":
                self.build_kext()
                return
            elif menu.lower() == "s":
                self.build_ssdt()
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

    def get_kb_ms(self):
        p = self.get_by_port()
        if not len(p):
            self.u.head("Something's Not Right")
            print("")
            print("Was unable to locate any valid ports.")
            print("Please ensure you have XHC/EH01/EH02 in your IOReg")
            print("")
            self.u.grab("Press [enter] to return...")
            return
        # Auto select those that are populated
        for u in p:
            if len(p[u]["items"]):
                p[u]["selected"] = True
        while True:
            self.u.head("Select Keyboard And Mouse")
            print("")
            count  = 0
            pad    = 14
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
                    print("\n".join(["     - {}".format(x) for x in p[u]["items"]]))
            print("")
            if sel < 1 or sel > 2:
                ptext = "{}Selected: {}{}".format(self.rs, sel, self.ce)
            else:
                ptext = "{}Selected: {}{}".format(self.cs, sel, self.ce)
            print(ptext)
            h = count+extras+pad if count+extras+pad > 24 else 24
            self.u.resize(80, h)
            print("C. Confirm")
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
        return uia

    def sort(self, usblist):
        # Custom sorting based on prefixes
        #
        # Prefix order needed = HSxx, USRx, SSxx
        newlist = []
        hslist  = []
        usrlist = []
        sslist  = []
        rest    = []
        for x in usblist:
            if x.startswith("HS"):
                hslist.append(x)
            elif x.startswith("SS"):
                sslist.append(x)
            elif x.startswith("USR"):
                usrlist.append(x)
            else:
                rest.append(x)
        newlist.extend(sorted(hslist))
        newlist.extend(sorted(usrlist))
        newlist.extend(sorted(sslist))
        newlist.extend(sorted(rest))
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
        args = self.get_uia_args()
        if len(args):
            print("UIA Boot Args: {}".format(" ".join(args)))
        else:
            print("UIA Boot Args: None")
        print("")
        uia_version = self.check_uia()
        uia_text = "USBInjectAll "
        if not uia_version:
            # Not loaded
            uia_text += "Not Loaded - NVRAM boot-args WILL NOT WORK"
        else:
            # Loaded - check if v is enough
            v = self.u.compare_versions(uia_version, self.min_uia_v)
            if v:
                # Under minimum version
                uia_text += "v{} Loaded - HSxx/SSxx Exclude WILL NOT WORK (0.7.0 min)".format(uia_version)
            else:
                # Equal to, or higher than the min version
                uia_text += "v{} Loaded".format(uia_version)
        print(uia_text)
        print("")
        aptio_loaded = "Unknown"
        if self.bdmesg:
            aptio = self.r.run({"args":"{} | grep -i aptiomemoryfix".format(self.bdmesg),"shell":True})[0].strip("\n")
            aptio_loaded = "Loaded" if "success" in aptio.lower() else "Not Loaded"
        print("AptioMemoryFix {}{}".format(aptio_loaded, "" if aptio_loaded is "Loaded" else " - NVRAM boot-args MAY NOT WORK."))
        print("")
        print("NVRAM Arg Options:")
        if os.path.exists("Exclusion-Arg.txt"):
            print("  E. Apply Exclusion-Arg.txt")
        print("  H. Exclude HSxx Ports")
        print("  S. Exclude SSxx Ports")
        print("  C. Clear Exclusions")
        print("")
        print("R. Remove Plist")
        print("P. Edit Plist & Create SSDT/Kext")
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
