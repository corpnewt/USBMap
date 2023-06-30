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

### Before You Begin

* Make sure you're not using *any* other mapping attempts (USBInjectAll.kext, USBToolBox.kext, USBPorts.kext, another USBMap.kext, etc) - they can interfere with this process
* It can be helpful to run `R. Reset All Detected Ports` from USBMap's main menu to clear out any prior mapping information and start fresh

### General Mapping Process

1. Make sure you've run `D. Discover Ports` *at least once* from USBMap's main menu so it knows what USB controllers you have
2. Choose `K. Create USBMapDummy.kext` via USBMap's main menu
3. Add the USBMapDummy.kext dummy injector to your `EFI/OC/Kexts` folder and config.plist -> Kernel -> Add
4. Reboot your machine to apply the dummy map which gives us "scratch paper" to work with
5. Go into USBMap's `D. Discover Ports` and plug a USB 2 and USB 3 device into **every** port - letting the script refresh between each plug

    ◦ It is normal that not all port personalities will have devices populate under them at this step as macOS can only see the first 15 per controller here!

    ◦ You can verify the dummy map is applied if all ports use a `UKxx` naming scheme (eg. `UK01`, `UK02`, etc)
6. Use `USBMapInjectorEdit.command` with the USBMapDummy.kext from your EFI to toggle off all non-essential, seen port personalities

    ◦ Disable **any** of the first 15 port personalities that are not used for a keyboard or mouse - ***EVERYTHING ELSE*** in the first 15 can be disabled

    ◦ Disabling these is ***ONLY TEMPORARY*** and done *for the sake of mapping* - you can still choose which to include in the final map

    ◦ You will need to go through each IOKitPersonality that `USBMapInjectorEdit.command` lists for this
7. Reboot your machine to apply the updated dummy map
8. Go into USBMap's `D. Discover Ports` and plug a USB 2 and USB 3 device into every port - letting the script refresh between each plug

    ◦ As some port personalities were disabled in step 6, it is normal that not plugged in USB devices will populate under a port personality at this step!
9. Go into the `P. Edit & Create USBMap.kext` menu and change the types to match the **physical port types** (i.e. the USB 2 port personality of a USB 3 Type-A port will still be type 3) and enable which port personalities (up to 15) you want to keep
10. Build the final USBMap.kext and replace the dummy injector in your `EFI/OC/Kexts` folder and config.plist -> Kernel -> Add

The dummy injector + USBMapInjectorEdit steps are to allow you to map using a "sliding window" of sorts.  Since macOS can only see 15 port personalities per controller at one time, you need to map what's visible, then disable some to make room for the next sweep - and map again

***

## FAQ

* **Intel Bluetooth Doesn't Show In Discovery**
  * Due to the way Intel Bluetooth populates, it does not show in ioreg the same way other USB devices do.  You can still find its address in System Information -> USB, then clicking on the bt device and taking note of its `Location ID`
  * This should be worked around as of [this commit](https://github.com/corpnewt/USBMap/commit/07beeeba6a1453ad5a38dcdd1c9d9e704f5fb662) which merges info from `system_profiler` with `ioreg` to more completely map.
