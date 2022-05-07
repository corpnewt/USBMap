# USBMap

Python script for mapping USB ports in macOS and creating a custom injector kext.

***

# Features

- [x] No dependency on USBInjectAll
- [x] Can map XHCI (chipset, third party, and AMD), EHCI, OHCI, and UHCI ports
- [x] Can map USB 2 HUBs (requires the HUB's parent port uses type 255)
- [x] Matches based on class name, not port or controller name
- [x] Allows setting nicknames to the last-seen populated ports in discovery
- [x] Aggregates connected devices via session id instead of the broken port addressing
- [x] Can use best-guess approaches to generate ACPI to rename controllers or reset RHUB devices as needed

***

## Installation

### With Git

Run the following one line at a time in Terminal:

    git clone https://github.com/corpnewt/USBMap
    cd USBMap
    chmod +x USBMap.command
    
Then run with either `./USBMap.command` or by double-clicking *USBMap.command*

### Without Git

You can get the latest zip of this repo [here](https://github.com/corpnewt/USBMap/archive/master.zip).  Then run by double-clicking *USBMap.command*

***

## Quick Start

1. Make sure you've run `D. Discover Ports` at least once from the main menu of USBMap.command so it knows what USB controllers you have
2. Choose `K. Create Dummy USBMap.kext` via the main menu of USBMap.command
3. Add the USBMap.kext dummy injector to your OC -> Kexts folder and config.plist -> Kernel -> Add
4. Reboot
5. Go into USBMap's `D. Discover Ports` and plug a USB 2 and USB 3 device into every port - letting the script refresh between each plug
6. Use `USBMapInjectorEdit.command` to toggle off all non-essential seen ports (any of the first 15 that aren't a keyboard/mouse/etc which are needed for basic functionality)
7. Reboot
8. Go into USBMap's `D. Discover Ports` and plug a USB 2 and USB 3 device into every port - letting the script refresh between each plug
9. Go into the `P. Edit & Create USBMap.kext` menu and change the types to match the physical port types and toggle which ports (up to 15) you want to preserve
10. Build the final USBMap.kext and replace the dummy injector in your OC -> Kexts folder

The dummy injector + USBMapInjectorEdit steps are to allow you to map using a "sliding window" of sorts.  Since you can only see 15 port personalities at one time, you need to map what's visible, then omit them to make room for the next sweep - then map again

***

## FAQ

* **Intel Bluetooth Doesn't Show In Discovery**
  * Due to the way Intel Bluetooth populates, it does not show in ioreg the same way other USB devices do.  You can still find its address in System Information -> USB, then clicking on the bt device and taking note of its `Location ID`
