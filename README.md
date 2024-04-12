# USBMap
macOS has a limit on the number of USB ports it can recognize, which might cause some ports to function at lower speeds or not at all. USBMap is a python script which helps to create a custom kext to ensure all ports work correctly by mapping them within macOS's limits.

***

# Features

- [x] No dependency on USBInjectAll.kext
- [x] Supports mapping XHCI (chipset, third party, and AMD), EHCI, OHCI, and UHCI ports
- [x] Supports mapping USB 2 HUBs (requires the HUB's parent port to use type 255).
- [x] Performs matching based on class name, not port or controller name.
- [x] Allows users to set nicknames for the last-seen populated ports in the discovery process.
- [x] Aggregates connected devices via session id instead of the broken port addressing
- [x] Can use best-guess approaches to generate ACPI to rename controllers or reset RHUB devices as needed

***

## Installation

### With Git

To install using the latest version from Github, run the following commands one at a time in Terminal.app:

    git clone https://github.com/corpnewt/USBMap
    cd USBMap
    chmod +x USBMap.command
    
Then run with either `./USBMap.command` or by double-clicking *USBMap.command*

### Without Git

You can get the latest zip of this repo [here](https://github.com/corpnewt/USBMap/archive/master.zip).  Then run by double-clicking *USBMap.command*

***

## Quick Start

### Why

macOS supports up to 15 USB ports per controller. On a native Mac, these are directly mapped to the physical ports. However, other motherboards may have more ports than are actually in use, leading macOS to default to using the first 15 ports it detects. This often results in physical ports only achieving USB 2 speeds because USB 3 ports are numbered above 15. USBMap allows you to create a kext customized for your system, ensuring that non-existent ports are ignored and all physical ports are accounted for within the 15-port limit.

### Before You Begin

* Make sure to remove or disable *any* other USB mapping attempts (such as USBInjectAll.kext, USBToolBox.kext, USBPorts.kext, another USBMap.kext, etc) as they can interfere with this process
* It can be helpful to run `R. Reset All Detected Ports` from USBMap's main menu to clear out any prior mapping information and start fresh

### General Mapping Process

1. Make sure you've run `D. Discover Ports` *at least once* from USBMap's main menu so it knows what USB controllers you have
2. Choose `K. Create USBMapDummy.kext` via USBMap's main menu
3. Add the USBMapDummy.kext dummy injector to your `EFI/OC/Kexts` folder and config.plist -> Kernel -> Add
4. Reboot your machine to apply the dummy map, providing a foundation for mapping.
5. Go into USBMap's `D. Discover Ports` and plug both a USB 2 and a USB 3 device into **every** port - letting the script refresh between each plug. You can assign nicknames to ports for easier identification using the 'N' key.

    ◦ It is normal that not all port personalities will have devices populate under them at this step as macOS can only see the first 15 per controller here!

    ◦ You can verify the dummy map is applied if all ports use a `UKxx` naming scheme (eg. `UK01`, `UK02`, etc)


6. The USBMap script will save the discovered port information in a file, so you can quit it for now.
7. Open the `USBMapInjectorEdit.command` and drag the USBMapDummy.kext from your EFI into the Terminal window. Then toggle off all port personalities that you didn't encounter when using "Discover ports".

    ◦ Disable **any** of the first 15 port personalities that are not used for a keyboard or mouse - ***EVERYTHING ELSE*** in the first 15 can be disabled

    ◦ Disabling these is ***ONLY TEMPORARY*** and done *for the sake of mapping* - you can still choose which to include in the final map

    ◦ <ins>**DO NOT**</ins> disable port personalities 16 through 26, these need to stay enabled to continue mapping

    ◦ You will need to go through each IOKitPersonality that `USBMapInjectorEdit.command` lists for this
8. Reboot your machine to apply the updated dummy map
9. Go into USBMap's `D. Discover Ports` and plug a USB 2 and USB 3 device into every port - letting the script refresh between each plug

    ◦ As some port personalities were disabled in step 6, it is normal that not plugged in USB devices will populate under a port personality at this step!
10. Go into the `P. Edit & Create USBMap.kext` menu and change the types to match the **physical port types** (i.e. for standard USB 2 port use "0" and for USB 3 Type-A port use "3". You can find all codes by pressing T) and enable which port personalities (up to 15) you want to keep
11. Build the final USBMap.kext and replace the dummy injector in your `EFI/OC/Kexts` folder and config.plist -> Kernel -> Add

The dummy injector + USBMapInjectorEdit steps are to allow you to map using a "sliding window" of sorts.  Since macOS can only see 15 port personalities per controller at one time, you need to map what's visible, then disable some to make room for the next sweep - and map again

***

## FAQ

* **Intel Bluetooth Doesn't Show In Discovery**
  * Due to the way Intel Bluetooth populates, it does not show in ioreg the same way other USB devices do.  You can still find its address in System Information -> USB, then clicking on the bt device and taking note of its `Location ID`
  * This should be worked around as of [this commit](https://github.com/corpnewt/USBMap/commit/07beeeba6a1453ad5a38dcdd1c9d9e704f5fb662) which merges info from `system_profiler` with `ioreg` to more completely map.
