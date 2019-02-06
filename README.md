# USBMap
Py script for mapping out USB ports and creating a custom SSDT or injector kext (WIP).

***

# Installation

To install, do the following one line at a time in Terminal:

    git clone https://github.com/corpnewt/USBMap
    cd USBMap
    chmod +x USBMap.command
    
Then run with either `./USBMap.command` or by double-clicking *USBMap.command*

***

# PreRequisites

Controllers must be named as follows:

* _EHC1 -> EH01_
* _EHC2 -> EH02_
* _XHCI/XHC1 -> XHC\__

To begin port detection, you'll need to have _USBInjectAll.kext_ (and possibly the _XHCI_unsupported.kext_) and either use the Port Limit Increase patch for your OS version, or you'll need to detect ports in sweeps (first disable all _SSxx_ ports, then disable all _HSxx_ ports).  The latter is how this readme will be focused as it allows for mapping on OS versions where a port limit patch doesn't exist.

***

# Some Practices To Consider

Unless we use a port limit patch, each controller is limited to 15 USB ports.  As ports are detected as populated by the script, they will be counted based on their controller and that count displayed at the bottom of the window.  It's important to approach this pragmatically.  Some logical solutions include:

* If you have your keyboard and mouse plugged into USB 3.0 ports, they will likely only be using the USB 2.0 port associated with it - so you can omit the USB 3.0 variant of each port.
* Keep track of which types of devices you may plug into each port in the future - and only enable what you need.

On my Maximus X Code, I have HS01 -> HS14, USR1 -> USR2, and SS01 -> SS10 - which is 26 total ports.  I typically only have my mouse, keyboard, and DAC plugged into ports on the back of my machine, and then I do all my hot-swapping on the 4 ports at the front of my case.  For that reason, I disabled _all_ the USB 3.0 ports on the back of my mobo (as my kb, mouse, and DAC are all USB 2) and disabled all unpopulated USB 2.0 ports.  This kept my total at around 11 ports, which is well below the 15 port limit.

***

# Using The Script

The first step to port detection, after the above prerequisites have been met, is to disable the _SSxx_ ports to ensure that we're not over the 15 port limit per controller.  This script searches _EH01_, _EH02_, _HUB1_, _HUB2_, and _XHC_ for valid ports - and will attempt to map them accordingly.  This is all done by scraping/parsing ioreg and system_profiler and determining which ports are available and populated.  All of the discovered ports are appended to a usb.plist located in the same directory as the USBMap.command.  This allows us to make changes, reboot, make more changes, and reboot more without losing anything.

To disable the _SSxx ports_, we select `S. Exclude SSxx Ports` at the script's main menu, which will add `-uia_exclude_ss` to `boot-args` in nvram (this does not override any non-uia boot args in nvram, nor does it affect any in the config.plist).

After setting that arg, we reboot.  When you're at the desktop again, open the script, and select `D. Discover Ports` - this will start a 5 second detection loop.  With each iteration of the loop, the script will check all visible ports for new devices.  During this time, you'll want to take a USB 2.0 device and plug it into each USB port you plan to use with 2.0 ports - then wait for the next detection loop to reflect the changes, and continue.  When you've plugged into all the ports you intend to use, you'll have mapped out your USB 2.0 ports. Press `q` and then enter, as the script prompts to leave the discovery mode.

The next step is to disable the _HSxx_ ports and repeat the process with a USB 3.0 device.  We do this by selecting `H. Exclude HSxx Ports` from the main menu.  This will prompt us to include our mouse and keyboard, as those are typically USB 2.0 - and would be unusable if their ports were excluded.  After toggling ports so that only your kb and mouse are selected, you can select `C. Confirm` to remove any prior uia boot args in nvram, and add `-uia_exclude-hs uia_include=HSxx,HSxx` where the two _HSxx_ values correspond to the mouse and keyboard ports.

After setting that, we reboot again, and go through the discovery process as we did with the _HSxx_ ports above.  When you've mapped out all the ports you'll use, you can press `q` and enter to leave discovery.  We then want to choose `P. Edit Plist & Create SSDT/Kext` which takes us to a menu where we can enable/disable ports (based on our discovery above), and change port types.  The available port types are as follows:

```
0: Type A connector
1: Mini-AB connector
2: ExpressCard
3: USB 3 Standard-A connector
4: USB 3 Standard-B connector
5: USB 3 Micro-B connector
6: USB 3 Micro-AB connector
7: USB 3 Power-B connector
8: Type C connector - USB2-only
9: Type C connector - USB2 and SS with Switch
10: Type C connector - USB2 and SS without Switch
11 - 254: Reserved
255: Proprietary connector
```
With common types falling into 3 categories:
```
0: USB 2.0
3: USB 3.0
255: Internal Header
```

At the bottom of the list is a counter that will let you know if you're over the 15 port limit - this does not take multiple controllers as of now - so do consider that.

When you have the list setup the way you need, you can choose to either select `K. Build USBMap.kext` or `S. Build SSDT-UIAC`.  The former will attempt to build a _USBMap.kext_ injector (which does not require _USBInjectAll.kext_) - this will _only add ports_ that don't show up without _USBInjectAll.kext_, though - so if your system is like my Asus Maximus X Code (which already detects _HS01-HS14_ and _SS01-SS10_ without _USBInjectAll.kext_), you'll already be above the 15 port limit and adding more ports will do no good.  Creating an SSDT is typically what most users will want to do as it selects only the ports you want the system to see.  This means it both adds and removes ports as needed.  The SSDT _does_ require _USBInjectAll.kext_ to be present though.

The resulting kext can be copied to your _EFI/CLOVER/kexts/Other_ folder and a reboot should enable it (as long as you have InjectKexts enabled in your config.plist).

The resulting SSDT-UIAC.aml (_iasl_ is automatically downloaded and used to compile the .dsl if possible) can be placed in your _EFI/CLOVER/ACPI/patched_ folder.  If using _SortedOrder_, make sure of the following:

* _config.plist -> ACPI -> SortedOrder:_ dictionary must contain `<string>SSDT_UIAC.aml</string>`

Before rebooting again - make sure to go to the main menu of the script and select `C. Clear Exclusions` to remove any excluded/included ports.

After that point, you should be able to reboot and utilize all the ports you had mapped out.
